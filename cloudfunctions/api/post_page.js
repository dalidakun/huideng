/**
 * 「菩提空间」帖子分享落地页 —— 服务端渲染（SSR）。
 *
 * 为什么不用纯前端页面：微信收到链接时会用抓取器请求一次该 URL，**不执行
 * JavaScript**，只读首字节 HTML 里的 og:title / og:description / og:image 来
 * 生成聊天里的链接卡片。纯前端页面（site/post.html）虽然自己能从云函数拉到
 * 正文，但抓取器拿不到内容，卡片只会是站点级的通用标题与封面。所以这里把
 * 正文与 og 标签都渲染进首字节 HTML。
 *
 * 线上形态：
 *   https://aibuilder.top/post/<id>.html   → HTTP 网关路由 `/post` → 云函数 api
 *   https://aibuilder.top/post.html?id=<id> → 同一条路由（前缀匹配），302 到上面
 * 路由里要打开「路径透传」，本模块才能从 event.path 里取到帖子 id。
 * 配置与部署步骤见 docs/帖子分享链接卡片方案.md。
 *
 * 样式与 site/post.html（旧的 ?id= 版纯前端页）保持一致：改这里的 CSS 时
 * 记得同步改那边，反之亦然。
 */

'use strict';

// 站点常量：与 site/site.config.json 保持一致（baseUrl / siteName / icpNumber），
// 由 test/post_share_test.dart 校验，防止两处漂移。
const SITE_NAME = '燃灯';
const BASE_URL = 'https://aibuilder.top';
const SITE_TAGLINE = '燃一盏灯，看见自己，照亮别人。';
const ICP_NUMBER = '豫ICP备2026050494号';
const SHARE_IMAGE = BASE_URL + '/assets/share-cover.png';
// 页面上「打开 App」与底部「打开燃灯，查看更多笔记」都进官网首页
// （首页自己带下载入口），不再直接跳到下载页那张单页。
const SITE_HOME = BASE_URL + '/';
const COMMUNITY_NAME = '菩提空间';

const HTML_HEADERS = {
  'Content-Type': 'text/html; charset=utf-8',
  'X-Content-Type-Options': 'nosniff',
};

// 正常页面走 CDN 短缓存：既能让改帖很快生效，也能挡住重复抓取。
// 404 / 503 一律不缓存，否则帖子恢复公开、函数恢复正常后还被缓存按着。
const PAGE_CACHE = 'public, max-age=60, s-maxage=300';

// ─────────────────────────────────────────────────────────────
// 小工具
// ─────────────────────────────────────────────────────────────

function esc(value) {
  return String(value === undefined || value === null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** 取前 max 个字符（按字形而非字节），超出补省略号。用于 og:description。 */
function excerpt(text, max) {
  const flat = String(text || '').replace(/\s+/g, ' ').trim();
  if (!flat) return '';
  const chars = Array.from(flat);
  if (chars.length <= max) return flat;
  return chars.slice(0, max).join('') + '…';
}

/** 按字形截断但保留换行（引用原帖这类多段文字用，配 pre-wrap 显示）。 */
function clip(text, max) {
  const t = String(text || '').trim();
  if (!t) return '';
  const chars = Array.from(t);
  if (chars.length <= max) return t;
  return chars.slice(0, max).join('').replace(/\s+$/, '') + '…';
}

function formatDate(ms) {
  const n = Number(ms);
  if (!isFinite(n) || n <= 0) return '';
  // 云函数默认时区是 UTC；分享页读者都在东八区，固定按 UTC+8 展示。
  const d = new Date(n + 8 * 3600 * 1000);
  if (isNaN(d.getTime())) return '';
  const pad = (v) => (v < 10 ? '0' + v : String(v));
  return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate());
}

function decodeBase64Utf8(b64) {
  try {
    return Buffer.from(String(b64 || '').replace(/\s+/g, ''), 'base64').toString('utf8');
  } catch (e) {
    return '';
  }
}

/**
 * 结构化分享帖（人天利益 / 为众祈福）的元数据：
 *   <正文>\n§§XX§§<base64(JSON)>\n[备注]
 * 与客户端 lib/benefit_share_post.dart、lib/blessing_service.dart 的编码方式一致。
 */
function takeMeta(text, prefix) {
  const idx = text.indexOf(prefix);
  if (idx < 0) return null;
  const rest = text.slice(idx + prefix.length);
  const nl = rest.indexOf('\n');
  const b64 = (nl >= 0 ? rest.slice(0, nl) : rest).trim();
  const remark = nl >= 0 ? rest.slice(nl + 1).trim() : '';
  const before = text.slice(0, idx).replace(/[ \t]+$/g, '').trim();
  try {
    const data = JSON.parse(decodeBase64Utf8(b64));
    if (!data || typeof data !== 'object') return null;
    return { data, remark, before };
  } catch (e) {
    return null;
  }
}

function paragraphsOf(text) {
  const t = String(text || '').replace(/\r\n?/g, '\n').trim();
  if (!t) return [];
  return t
    .split(/\n{2,}/)
    .map((block) => block.replace(/^[ \t]+|[ \t]+$/g, ''))
    .filter(Boolean);
}

function paragraphsHtml(text) {
  return paragraphsOf(text)
    .map((p) => '<p>' + esc(p) + '</p>')
    .join('');
}

// ─────────────────────────────────────────────────────────────
// 正文渲染（与 site/post.html 里的 renderPlain / renderBenefit /
// renderBlessing 逐条对齐，改一处要同步另一处）
// ─────────────────────────────────────────────────────────────

function renderPlainBody(raw) {
  let text = String(raw || '');
  // 旧式 [@经名](路径) / [@账号](user:id) 标记：统一退化成 @名字。
  text = text.replace(/\[@([^\]]+)\]\([^)]*\)/g, '@$1');
  // 只读笔记的元数据（§§TS§§ / §§SN§§ / §§HS§§ 等）：连内容一起去掉。
  text = text.replace(/§§[A-Za-z0-9]{1,4}§§[^\s]*/g, '');
  text = text.replace(/§§[^§\n]{0,8}§§[^\s]*/g, '');
  text = text.replace(/\r\n?/g, '\n');

  const lines = text.split('\n');
  while (lines.length && !lines[0].trim()) lines.shift();
  let sutra = '';
  if (lines.length && lines[0].trim().charAt(0) === '$') {
    sutra = lines[0].trim().slice(1).trim();
    lines.shift();
    while (lines.length && !lines[0].trim()) lines.shift();
  }

  const chip = sutra
    ? '<div class="chip-line"><span class="chip">经藏 · ' + esc(sutra) + '</span></div>'
    : '';
  const body = lines.join('\n');
  return {
    kind: '',
    html: chip + paragraphsHtml(body),
    summary: paragraphsOf(body).join(' '),
    meta: sutra ? '经藏 · ' + sutra : '',
  };
}

function renderBenefit(meta) {
  const data = meta.data || {};
  const paragraph = String(data.paragraph || meta.before || '')
    .replace(/^【人天利益】\s*/, '')
    .trim();
  const target = String(data.targetName || '').trim();
  const type = data.targetType === 'mantra' ? '神咒' : '佛号';

  let card = '<div class="share-card">';
  card += '<div class="share-card__head">';
  card += '<span class="share-card__label">人天利益</span>';
  card += '</div>';
  if (paragraph) card += '<div class="share-card__text">' + esc(paragraph) + '</div>';
  if (target) card += '<div class="share-card__sub">' + esc(type + ' · ' + target) + '</div>';
  card += '</div>';

  return {
    kind: '人天利益',
    html: paragraphsHtml(meta.remark) + card,
    summary: paragraphsOf(meta.remark).join(' ') || paragraph || target,
    meta: target ? type + ' · ' + target : '',
    ogTitle: target ? '人天利益 · ' + target : '人天利益',
  };
}

function renderBlessing(meta) {
  const data = meta.data || {};
  const title = String(data.title || '').trim();
  const target = String(data.target || '').trim();
  const days = Number(data.totalDays) || 0;
  const joiners = Number(data.joinerCount) || 0;
  const methods = Array.isArray(data.methods)
    ? data.methods.map((m) => String(m || '').trim()).filter(Boolean).slice(0, 3)
    : [];

  let head = '<div class="share-card__head">';
  head += '<span class="share-card__label">为众祈福</span>';
  if (data.status === 'closed') head += '<span class="share-card__state">已圆满</span>';
  if (joiners > 0) head += '<span class="share-card__count">' + joiners + ' 人祈福</span>';
  head += '</div>';

  let card = '<div class="share-card">' + head;
  if (title) card += '<div class="share-card__title">' + esc(title) + '</div>';
  if (target) card += '<div class="share-card__sub">' + esc('回向：' + target) + '</div>';
  const chips = [];
  if (days > 0) chips.push('共修 ' + days + ' 天');
  for (const m of methods) chips.push(m);
  if (chips.length) {
    card +=
      '<div class="share-card__chips">' +
      chips.map((c) => '<span class="chip">' + esc(c) + '</span>').join('') +
      '</div>';
  }
  card += '</div>';

  const metaParts = [];
  if (target) metaParts.push('回向：' + target);
  if (days > 0) metaParts.push('共修 ' + days + ' 天');
  if (joiners > 0) metaParts.push(joiners + ' 人祈福');

  // 这类帖的 data.title 里放的是「经文原文」，天生很长，不能拿来做卡片标题；
  // 卡片标题用回向对象（「为我的父母及家人祈福」），摘要用回向文。
  const dedication = String(data.dedication || '').trim();

  return {
    kind: '为众祈福',
    html: paragraphsHtml(meta.remark) + card,
    summary: dedication || paragraphsOf(meta.remark).join(' ') || target || title,
    meta: metaParts.join(' · '),
    ogTitle: target ? '为' + target + '祈福' : '为众祈福',
  };
}

function renderNoteBody(note) {
  const raw = String(note.content || '');
  const benefit = takeMeta(raw, '§§BT§§');
  if (benefit) return renderBenefit(benefit);
  const blessing = takeMeta(raw, '§§BL§§');
  if (blessing) return renderBlessing(blessing);
  return renderPlainBody(raw);
}

/**
 * 回复/引用帖在库里是「回复正文 + quoteOfContent（被引用的原帖）」。
 * 分享页如果只显示「赞同」「帖子a」这类一句话回复，读者看不到在说什么，
 * 所以把被引用的原帖也带上（截断到一屏内），分享才有意义。
 */
function cleanQuote(text) {
  let t = String(text || '');
  t = t.replace(/\[@([^\]]+)\]\([^)]*\)/g, '@$1');
  t = t.replace(/§§[A-Za-z0-9]{1,4}§§[^\s]*/g, '');
  t = t.replace(/§§[^§\n]{0,8}§§[^\s]*/g, '');
  t = t.replace(/§§[^§\n]{0,8}§§/g, '');
  return t.replace(/\r\n?/g, '\n').trim();
}

// ─────────────────────────────────────────────────────────────
// 页面
// ─────────────────────────────────────────────────────────────

const PAGE_CSS = `
:root {
  --bg: #F7F3EC;
  --paper: #FFFDF9;
  --text: #24211D;
  --text-soft: #4A453E;
  --muted: #8B8378;
  --line: #E7DFD2;
  --accent: #8A6A3B;
  --accent-soft: #F1E6D4;
  --green: #556B5E;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; color-scheme: light; }
body {
  min-height: 100vh;
  background: var(--bg);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue",
    "Microsoft YaHei", "Noto Sans CJK SC", sans-serif;
  -webkit-font-smoothing: antialiased;
}
a { color: inherit; }
.topbar {
  position: sticky;
  top: 0;
  z-index: 10;
  background: rgba(247, 243, 236, 0.92);
  -webkit-backdrop-filter: blur(10px);
  backdrop-filter: blur(10px);
  border-bottom: 1px solid var(--line);
}
.topbar__inner {
  max-width: 680px;
  margin: 0 auto;
  height: 48px;
  padding: 0 20px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.brand { font-size: 13.5px; letter-spacing: 1px; color: var(--muted); }
.brand b { color: var(--text); font-weight: 600; }
.topbar__open {
  font-size: 12.5px;
  color: var(--accent);
  text-decoration: none;
  border: 1px solid var(--line);
  border-radius: 999px;
  padding: 4px 11px;
  background: var(--paper);
}
main {
  max-width: 680px;
  margin: 0 auto;
  padding: 22px 20px calc(32px + env(safe-area-inset-bottom));
}
.eyebrow {
  display: inline-block;
  font-size: 12px;
  line-height: 1.4;
  color: var(--accent);
  background: var(--accent-soft);
  border-radius: 999px;
  padding: 3px 10px;
  letter-spacing: 0.5px;
}
h1.title {
  margin: 12px 0 4px;
  font-size: 22px;
  line-height: 1.45;
  font-weight: 700;
  letter-spacing: 0.2px;
  word-break: break-word;
}
.author { display: flex; align-items: center; gap: 10px; margin: 18px 0 22px; }
.avatar {
  flex: none;
  width: 40px;
  height: 40px;
  border-radius: 50%;
  background: #E8DECC;
  color: #7A5A2E;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 16px;
  font-weight: 600;
  user-select: none;
}
.author__name { display: flex; align-items: center; gap: 4px; font-size: 14.5px; font-weight: 600; }
.verified { width: 14px; height: 14px; flex: none; fill: var(--green); }
.author__sub { margin-top: 3px; font-size: 12px; color: var(--muted); }
.body {
  font-size: 17px;
  line-height: 1.95;
  letter-spacing: 0.3px;
  color: var(--text-soft);
  word-break: break-word;
}
.body p { margin: 0 0 1.05em; white-space: pre-wrap; }
.body p:last-child { margin-bottom: 0; }
.chip-line { margin: 0 0 14px; }
.chip {
  display: inline-block;
  font-size: 12px;
  color: var(--accent);
  background: var(--accent-soft);
  border-radius: 6px;
  padding: 3px 8px;
  margin-right: 6px;
}
.share-card {
  margin: 16px 0 4px;
  padding: 14px 15px;
  background: #FFF9EF;
  border: 1px solid #EADFCB;
  border-radius: 12px;
}
.share-card__head {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 6px;
  margin-bottom: 9px;
}
.share-card__label {
  font-size: 11.5px;
  font-weight: 600;
  color: var(--accent);
  background: #F3E9D8;
  border-radius: 5px;
  padding: 2px 7px;
}
.share-card__state {
  font-size: 10.5px;
  color: var(--accent);
  background: #F1E6D4;
  border-radius: 4px;
  padding: 2px 6px;
}
.share-card__count { margin-left: auto; font-size: 11.5px; color: var(--muted); }
.share-card__title { font-size: 15px; font-weight: 600; line-height: 1.5; color: var(--text); }
.share-card__text {
  font-size: 15px;
  line-height: 1.85;
  color: var(--text-soft);
  white-space: pre-wrap;
}
.share-card__sub { margin-top: 6px; font-size: 12.5px; line-height: 1.6; color: var(--muted); }
.share-card__chips { margin-top: 9px; display: flex; flex-wrap: wrap; gap: 6px; }
.stats {
  display: flex;
  flex-wrap: wrap;
  gap: 16px;
  margin-top: 28px;
  padding-top: 18px;
  border-top: 1px solid var(--line);
  font-size: 12.5px;
  color: var(--muted);
}
.cta {
  display: block;
  margin-top: 26px;
  height: 48px;
  line-height: 48px;
  border-radius: 999px;
  background: var(--green);
  color: #fff;
  text-align: center;
  text-decoration: none;
  font-size: 16px;
  font-weight: 600;
  letter-spacing: 1px;
}
.cta:active { opacity: 0.86; }
.foot { margin-top: 14px; text-align: center; font-size: 12px; color: #A79E90; }
.foot a { color: #8B8378; text-decoration: none; }
.beian { margin-top: 6px; }
.error { padding: 72px 0; text-align: center; color: var(--muted); font-size: 14px; line-height: 1.9; }
.error__title { font-size: 16px; color: var(--text); margin-bottom: 8px; }
.error__retry {
  display: inline-block;
  margin-top: 16px;
  padding: 7px 18px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: var(--paper);
  color: var(--accent);
  font-size: 13px;
  text-decoration: none;
}
`;

const VERIFIED_SVG =
  '<svg class="verified" viewBox="0 0 24 24" aria-label="已认证">' +
  '<path d="M12 2l2.4 2.1 3.2-.3 1 3.1 2.8 1.6-1.2 3 1.2 3-2.8 1.6-1 3.1-3.2-.3L12 22l-2.4-2.1-3.2.3-1-3.1L2.6 15.5l1.2-3-1.2-3 2.8-1.6 1-3.1 3.2.3L12 2zm-1.2 13.6l5-5-1.4-1.4-3.6 3.6-1.6-1.6-1.4 1.4 3 3z"/>' +
  '</svg>';

const BEIAN_HTML =
  '<a href="https://beian.miit.gov.cn/" target="_blank" rel="noopener noreferrer">' +
  ICP_NUMBER +
  '</a>';

function shell(opts) {
  const canonical = opts.canonical || '';
  const meta = [];
  meta.push('<meta charset="UTF-8">');
  meta.push('<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">');
  meta.push('<meta name="format-detection" content="telephone=no">');
  meta.push('<title>' + esc(opts.docTitle) + '</title>');
  meta.push('<meta name="description" content="' + esc(opts.description) + '">');
  meta.push('<meta property="og:type" content="' + (opts.ogType || 'article') + '">');
  meta.push('<meta property="og:site_name" content="' + esc(SITE_NAME) + '">');
  meta.push('<meta property="og:title" content="' + esc(opts.ogTitle) + '">');
  meta.push('<meta property="og:description" content="' + esc(opts.ogDescription) + '">');
  meta.push('<meta property="og:image" content="' + esc(SHARE_IMAGE) + '">');
  meta.push('<meta property="og:image:width" content="640">');
  meta.push('<meta property="og:image:height" content="640">');
  if (canonical) meta.push('<meta property="og:url" content="' + esc(canonical) + '">');
  meta.push('<meta name="twitter:card" content="summary">');
  meta.push('<meta name="theme-color" content="#F7F3EC">');
  if (canonical) meta.push('<link rel="canonical" href="' + esc(canonical) + '">');
  meta.push('<link rel="icon" type="image/png" href="' + BASE_URL + '/assets/icon.png">');
  meta.push('<link rel="apple-touch-icon" href="' + BASE_URL + '/assets/icon.png">');

  return (
    '<!DOCTYPE html>\n' +
    '<html lang="zh-CN">\n' +
    '<head>\n' +
    meta.join('\n') +
    '\n<style>' +
    PAGE_CSS +
    '</style>\n</head>\n<body>\n' +
    '<header class="topbar"><div class="topbar__inner">' +
    '<span class="brand"><b>' + esc(SITE_NAME) + '</b> · ' + COMMUNITY_NAME + '</span>' +
    '<a class="topbar__open" href="' + SITE_HOME + '">打开 App</a>' +
    '</div></header>\n' +
    '<main>\n' +
    opts.main +
    '\n</main>\n' +
    (opts.script ? '<script>' + opts.script + '<\/script>\n' : '') +
    '</body>\n</html>\n'
  );
}

function footerHtml() {
  return (
    '<p class="foot">燃一盏灯，看见自己，照亮别人</p>' +
    '<p class="foot beian">' + BEIAN_HTML + '</p>'
  );
}

function notePageHtml(note, id) {
  const body = renderNoteBody(note);
  const quote = cleanQuote(note.quoteOfContent);

  let rawTitle = String(note.title || '').trim();
  if (rawTitle === '无标题') rawTitle = '';
  // 标题与类型标签重复时（很多结构化帖的 title 就是「人天利益」）不再重复展示。
  const title = rawTitle === body.kind ? '' : rawTitle;

  const authorName = String(note.authorName || '同修').trim() || '同修';
  const views = Number(note.viewCount) || 0;
  const likes = Number(note.likeCount) || 0;
  const comments = Number(note.commentCount) || 0;
  const date = formatDate(note.createdAt);

  const summaryRaw = (() => {
    const own = body.summary || '';
    if (!own) return quote;
    // 一句话回复（「赞同」「南无阿弥陀佛」）配上原帖，卡片摘要才说得清在聊什么。
    if (Array.from(own).length < 12 && quote) return own + ' ' + quote;
    return own;
  })();
  const summary = excerpt(summaryRaw || '', 88) || SITE_TAGLINE;
  const docTitle = (title || body.kind || COMMUNITY_NAME) + ' · ' + SITE_NAME;
  // 卡片标题优先用帖子标题；无标题帖用正文开头几个字顶上——微信卡片里
  // 「菩提空间 · 燃灯」这种站点名对读者毫无信息量。
  const derived = excerpt(summaryRaw || '', 20);
  const ogTitle = title
    ? title + ' · ' + COMMUNITY_NAME
    : body.ogTitle || derived || COMMUNITY_NAME + ' · ' + SITE_NAME;
  const canonical = BASE_URL + '/post/' + encodeURIComponent(id) + '.html';
  // 无标题帖的卡片标题就是摘要开头，摘要再重复一遍一模一样的内容没意义，
  // 这种短帖的卡片描述改为站点一句话。
  var ogDescription = summary;
  if (!title && Array.from(summary).length <= 22) {
    ogDescription = body.meta || SITE_TAGLINE;
  }

  const subParts = [];
  if (date) subParts.push(date);
  if (views > 0) subParts.push('阅读 ' + views);

  let main = '';
  main += '<span class="eyebrow">' + esc(body.kind || COMMUNITY_NAME) + '</span>';
  if (title) main += '<h1 class="title">' + esc(title) + '</h1>';

  main += '<div class="author">';
  main += '<div class="avatar">' + esc(Array.from(authorName)[0] || '同') + '</div>';
  main += '<div>';
  main +=
    '<div class="author__name">' +
    esc(authorName) +
    (note.authorVerified ? VERIFIED_SVG : '') +
    '</div>';
  main += '<div class="author__sub">' + esc(subParts.join(' · ')) + '</div>';
  main += '</div></div>';

  let bodyHtml = body.html || '<p>这条笔记没有正文，打开 App 查看完整内容。</p>';
  if (quote) {
    bodyHtml +=
      '<div class="share-card">' +
      '<div class="share-card__head"><span class="share-card__label">引用</span></div>' +
      '<div class="share-card__text">' +
      esc(clip(quote, 320)) +
      '</div></div>';
  }
  main += '<div class="body">' + bodyHtml + '</div>';

  let stats = '<span>' + '阅读 ' + views + '</span>';
  if (likes > 0) stats += '<span>点赞 ' + likes + '</span>';
  if (comments > 0) stats += '<span>评论 ' + comments + '</span>';
  main += '<div class="stats">' + stats + '</div>';

  main +=
    '<a class="cta" href="' + SITE_HOME + '">打开' +
    esc(SITE_NAME) + '，查看更多笔记</a>';
  main += footerHtml();

  // 真实浏览（浏览器/微信内置浏览器）打开时才 +1 阅读；抓取器不执行 JS，不会计数。
  // 同源请求打到本函数自己的 /post/ 路由，不需要任何密钥。
  const script =
    '(function(){try{var id=' + JSON.stringify(id) + ';' +
    'fetch("' + BASE_URL + '/post/"+encodeURIComponent(id)+".html?view=1",' +
    '{cache:"no-store",credentials:"omit"}).catch(function(){});}catch(e){}})();';

  return shell({
    docTitle: docTitle,
    description: summary,
    ogTitle: ogTitle,
    ogDescription: ogDescription,
    canonical: canonical,
    main: main,
    script: script,
  });
}

/**
 * 祈福（共修）项目页：/post/<祈福项目id>.html。
 *
 * 「为众祈福」有两种可分享的东西：
 *   1. 帖子（快照）—— 被人「分享到菩提空间」后生成的那条笔记，走 notePageHtml；
 *   2. 项目本身 —— 祈福详情页右上角分享出去的就是这种，id 是 blessingProjects 的 _id。
 * 两者共用 /post/<id>.html，这里按 id 查不到帖子时再查项目，链接永远只有一个形态。
 */
function blessingPageHtml(project, id) {
  const target = String(project.target || '').trim();
  const dedication = String(project.dedication || '').trim();
  const templateKey = String(project.templateKey || '').trim();
  const days = Number(project.totalDays) || 0;
  const joiners = Number(project.joinerCount) || 0;
  const closed = project.status === 'closed';

  // 事由标题：优先模板名（「为父母及家人祈福」），没有就用回向对象拼。
  const title = templateKey || (target ? '为' + target + '祈福' : '为众祈福');

  const methods = [];
  if (Array.isArray(project.methods)) {
    for (const m of project.methods.slice(0, 4)) {
      if (!m || typeof m !== 'object') continue;
      const base = String(m.name || m.category || '').trim();
      if (!base) continue;
      const count = String(m.count || '').trim();
      const unit = String(m.unit || '').trim();
      methods.push(count ? base + ' × ' + count + unit : base);
    }
  }

  const dateRange =
    project.startDate && project.endDate
      ? String(project.startDate) + ' ~ ' + String(project.endDate)
      : String(project.startDate || project.endDate || '');

  let card = '<div class="share-card">';
  card += '<div class="share-card__head">';
  card += '<span class="share-card__label">为众祈福</span>';
  if (closed) card += '<span class="share-card__state">已圆满</span>';
  if (joiners > 0) {
    card += '<span class="share-card__count">' + joiners + ' 人祈福</span>';
  }
  card += '</div>';
  if (dedication) card += '<div class="share-card__text">' + esc(dedication) + '</div>';
  if (target) card += '<div class="share-card__sub">' + esc('回向：' + target) + '</div>';

  const chips = [];
  if (days > 0) chips.push('共修 ' + days + ' 天');
  for (const m of methods) chips.push(m);
  if (chips.length) {
    card +=
      '<div class="share-card__chips">' +
      chips.map((c) => '<span class="chip">' + esc(c) + '</span>').join('') +
      '</div>';
  }
  card += '</div>';

  const owner = String(project.ownerName || '').trim() || '同修';
  // 账号名多是英文（randeng），首字母当头像像乱码，非中文一律用「祈」。
  const initial = /[\u4e00-\u9fa5]/.test(owner) ? Array.from(owner)[0] : '祈';
  const subParts = [];
  if (dateRange) subParts.push(dateRange);
  if (days > 0) subParts.push('共修 ' + days + ' 天');

  let main = '';
  main += '<span class="eyebrow">为众祈福</span>';
  main += '<h1 class="title">' + esc(title) + '</h1>';
  main += '<div class="author">';
  main += '<div class="avatar">' + esc(initial) + '</div>';
  main += '<div>';
  main += '<div class="author__name">' + esc(owner) + '</div>';
  main += '<div class="author__sub">' + esc(subParts.join(' · ')) + '</div>';
  main += '</div></div>';
  main += '<div class="body">' + card + '</div>';

  let stats = '';
  if (joiners > 0) stats += '<span>' + joiners + ' 人参与</span>';
  if (days > 0) stats += '<span>共修 ' + days + ' 天</span>';
  if (closed) stats += '<span>已圆满</span>';
  if (stats) main += '<div class="stats">' + stats + '</div>';

  main +=
    '<a class="cta" href="' + SITE_HOME + '">打开' +
    esc(SITE_NAME) + '，一起祈福</a>';
  main += footerHtml();

  const canonical = BASE_URL + '/post/' + encodeURIComponent(id) + '.html';
  const summary = excerpt(dedication || (target ? '回向：' + target : ''), 88) || SITE_TAGLINE;

  return shell({
    docTitle: title + ' · ' + SITE_NAME,
    description: summary,
    ogTitle: title,
    ogDescription: summary,
    canonical: canonical,
    main: main,
  });
}

function errorPageHtml(title, hint, retryHref, retryLabel) {
  let main = '<div class="error">';
  main += '<div class="error__title">' + esc(title) + '</div>';
  if (hint) main += '<div>' + esc(hint) + '</div>';
  if (retryHref) {
    main +=
      '<a class="error__retry" href="' + esc(retryHref) + '">' +
      esc(retryLabel || '重新加载') +
      '</a>';
  }
  main += '</div>';
  main += footerHtml();
  return shell({
    docTitle: title + ' · ' + SITE_NAME,
    description: SITE_TAGLINE,
    ogTitle: COMMUNITY_NAME + ' · ' + SITE_NAME,
    ogDescription: SITE_TAGLINE,
    ogType: 'website',
    main: main,
  });
}

// ─────────────────────────────────────────────────────────────
// 数据
// ─────────────────────────────────────────────────────────────

async function loadPublicNote(app, id) {
  const db = app.database();
  const { data } = await db.collection('notes').doc(id).get();
  const note = (data && data[0]) || null;
  if (!note) return null;
  // 与 getNoteById 同一套可见性规则：隐藏帖、非公开帖一律当作不存在，
  // 分享链接不能成为绕过可见性的后门。
  if (note.status === 'hidden') return null;
  if (note.visibility !== 'public') return null;
  try {
    const owners = note.ownerUserId ? [note.ownerUserId] : [];
    if (owners.length) {
      const v = await db.collection('userVerifications').where({ uid: owners[0] }).limit(1).get();
      note.authorVerified = !!(v && v.data && v.data.length);
    }
  } catch (e) {
    // 认证标记查不到不影响页面本身。
  }
  return note;
}

async function loadPublicBlessing(app, id) {
  const db = app.database();
  const { data } = await db.collection('blessingProjects').doc(id).get();
  const project = (data && data[0]) || null;
  if (!project) return null;
  // 与 getBlessingById 一致：非公开的共修不出页面，分享链接不能绕过可见性。
  if (project.visibility !== 'public') return null;
  if (project.status === 'deleted') return null;
  try {
    if (project.ownerUserId) {
      const u = await db
        .collection('userAccounts')
        .where({ uid: project.ownerUserId })
        .limit(1)
        .get();
      const row = u && u.data && u.data[0];
      project.ownerName = (row && row.username) || '';
    }
  } catch (e) {
    // 作者名查不到就显示「同修」。
  }
  return project;
}

async function bumpView(app, id) {
  try {
    const db = app.database();
    const { data } = await db.collection('notes').doc(id).get();
    const note = (data && data[0]) || null;
    if (!note || note.visibility !== 'public') return;
    const prev = Math.floor(Number(note.viewCount) || 0);
    const viewCount = Number.isFinite(prev) ? prev + 1 : 1;
    await db.collection('notes').doc(id).update({ viewCount: viewCount });
  } catch (e) {
    console.log('[post_page] incView failed:', e && e.message);
  }
}

// ─────────────────────────────────────────────────────────────
// HTTP 入口
// ─────────────────────────────────────────────────────────────

function htmlResponse(statusCode, body) {
  const headers = Object.assign({}, HTML_HEADERS, {
    'Cache-Control': statusCode === 200 ? PAGE_CACHE : 'no-store',
  });
  return {
    statusCode: statusCode,
    headers: headers,
    isBase64Encoded: false,
    body: body,
  };
}

function redirectResponse(location) {
  return {
    statusCode: 302,
    headers: {
      Location: location,
      'Cache-Control': 'public, max-age=300',
    },
    isBase64Encoded: false,
    body: '',
  };
}

/**
 * 处理 /post/<id>.html 的 HTTP 请求。
 *
 * 返回响应对象表示已处理（云函数直接返回它）；返回 null 表示这条请求不是
 * 分享页（例如 App 的 {action: ...} JSON 调用），交给原来的 action 分支。
 */
async function handleHttp(event, app) {
  if (!event) return null;
  const rawPath = String(
    event.path || (event.requestContext && event.requestContext.path) || ''
  );
  if (!rawPath) return null;
  // 只接管 /post、/post.html、/post/<id>(.html)，别的一律按原协议走。
  if (!/^\/post(\.html)?(\/|$)/.test(rawPath)) return null;

  let path = rawPath;
  const qMark = path.indexOf('?');
  if (qMark >= 0) path = path.slice(0, qMark);

  const query = event.queryStringParameters || {};
  let id = String(query.id || '').trim();
  let legacy = false;

  if (/^\/post(\.html)?\/?$/.test(path)) {
    // 旧链接 /post.html?id=xxx：拿到 id 后 302 到新地址，老分享链接不会失效。
    legacy = true;
  } else {
    const m = /^\/post\/(.+)$/.exec(path);
    let seg = (m && m[1]) || '';
    seg = seg.replace(/\/+$/, '');
    if (seg.slice(-5) === '.html') seg = seg.slice(0, -5);
    try {
      seg = decodeURIComponent(seg);
    } catch (e) {
      // 编码坏了就按原样用，后面查不到自然会走「笔记不存在」。
    }
    if (!seg || seg.indexOf('/') >= 0) {
      return htmlResponse(
        404,
        errorPageHtml('链接不完整', '缺少帖子编号，无法打开这条笔记。', SITE_HOME, '打开燃灯官网')
      );
    }
    id = seg;
  }

  if (!id || id.length > 128) {
    return htmlResponse(
      404,
      errorPageHtml('链接不完整', '缺少帖子编号，无法打开这条笔记。', SITE_HOME, '打开燃灯官网')
    );
  }

  if (legacy) {
    return redirectResponse(BASE_URL + '/post/' + encodeURIComponent(id) + '.html');
  }

  // 计数器信标：只有执行 JS 的真实浏览器会打这个请求。
  if (String(query.view || '') === '1') {
    await bumpView(app, id);
    return { statusCode: 204, headers: { 'Cache-Control': 'no-store' }, body: '' };
  }

  let note = null;
  let project = null;
  try {
    note = await loadPublicNote(app, id);
    // 帖子查不到时再按祈福项目 id 查一次：祈福详情页分享出去的就是项目 id。
    if (!note) project = await loadPublicBlessing(app, id);
  } catch (e) {
    console.log('[post_page] load failed:', e && e.message);
    return htmlResponse(
      503,
      errorPageHtml(
        '加载失败',
        '网络开小差了，请稍后重试。',
        BASE_URL + '/post/' + encodeURIComponent(id) + '.html',
        '重新加载'
      )
    );
  }

  if (note) return htmlResponse(200, notePageHtml(note, id));
  if (project) return htmlResponse(200, blessingPageHtml(project, id));

  return htmlResponse(
    404,
    errorPageHtml('笔记不存在', '该内容可能已被删除，或仅作者本人可见。', SITE_HOME, '打开燃灯官网')
  );
}

module.exports = {
  handleHttp,
  notePageHtml,
  blessingPageHtml,
  errorPageHtml,
  // 供本地自测/单元测试直接调用
  renderNoteBody,
  takeMeta,
  excerpt,
};
