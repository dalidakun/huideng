/**
 * 模拟交易（纯记账，不碰真实资金）。
 *
 * 独立成文件是因为 index.js 已经 5000+ 行，交易这块自成一体：
 * 身份（网页注册/登录 → 会话 token）、账户、持仓、挂单、成交历史。
 *
 * 身份为什么不用 access token：
 *   resolveUid() 故意不认匿名身份（认了全站会串号），网页匿名调用拿不到 uid；
 *   而 CloudBase 自定义登录（ticket → access token）需要浏览器引入 JS SDK，
 *   还要处理 CORS。这里改用「自己的会话表」：登录成功发一个随机 token，
 *   后续请求带着它，服务端查表换回 uid。纯 fetch，零 SDK。
 *
 * 撮合为什么由客户端推动：
 *   云函数没有常驻定时器，限价单的触发只能靠客户端在价格更新时调 tradeSync。
 *   客户端上报的价格不可信，所以下面所有金额都在服务端重算，并对价格做限幅校验。
 *
 * 会计模型（1 倍逐仓，无杠杆）：
 *   开仓：冻结 margin = qty × entry → cash -= margin（模拟盘不收手续费，fee 恒为 0）
 *   平仓：cash += margin + pnl
 *     多头 pnl = (mark − entry) × qty
 *     空头 pnl = (entry − mark) × qty
 *   权益 equity = cash + Σ(margin + 浮动盈亏)，开平仓不改变权益，账自洽。
 *   空头亏损无上界，margin + pnl ≤ 0 即强平（返还 0），账户不会穿仓。
 */
const crypto = require("crypto");
const https = require("https");

/* 模拟交易，不收手续费：前端 trade.js 的 FEE 也是 0，两边必须一致。 */
const FEE_RATE = 0;
const PNL_MULT = 10; // 单子盈亏放大 10 倍（与 site/assets/js/trade.js 保持一致）
const INITIAL_CASH = 100000; // 初始虚拟资金 10 万 USDT
const MIN_NOTIONAL = 10; // 最小名义价值 10 USDT（对齐币安）
const MAX_QTY = 1000; // 单笔数量上限
const SESSION_TTL = 30 * 24 * 3600 * 1000; // 会话 30 天
const MAX_FILLS = 60; // 成交历史保留条数
const MAX_PRICE_DRIFT = 0.05; // 上报价与上次已知价的最大偏离
const RATE_WINDOW = 10 * 1000;
const RATE_MAX = 30;

const COLLECTIONS = [
  "tradeAccounts",
  "tradePositions",
  "tradeOrders",
  "tradeFills",
  "tradeSessions",
  "tradePhones",
  "tradePhoneCodes",
  "tradeDraw",
  "tradeNotes",
  "tradeProfiles",
  "userAccounts",
];

function round(n, digits) {
  const f = Math.pow(10, digits);
  return Math.round(n * f) / f;
}

function roundQty(qty) {
  return round(qty, 6);
}

function roundPrice(p) {
  return round(p, 2);
}

function num(v) {
  const n = typeof v === "number" ? v : parseFloat(v);
  return Number.isFinite(n) ? n : NaN;
}

// 简易限流：进程内按 key 记录最近调用时间。冷启动会重置，但配合云函数自身的
// 调用配额已经够用，不额外引入依赖。
const rateBuckets = new Map();

function rateLimited(key) {
  const now = Date.now();
  let list = rateBuckets.get(key);
  if (!list) {
    list = [];
    rateBuckets.set(key, list);
  }
  // list[0] 是最新一次，最老的在末尾
  while (list.length && now - list[list.length - 1] > RATE_WINDOW) list.pop();
  if (rateBuckets.size > 5000) rateBuckets.clear();
  if (list.length >= RATE_MAX) return true;
  list.unshift(now);
  return false;
}

// 集合只在冷启动时探测一次：云函数实例会复用，没必要每次调用都 createCollection。
let collectionsEnsured = false;

module.exports = function createTrade(deps) {
  const db = deps.db;
  const ok = deps.ok;
  const fail = deps.fail;
  // 云存储（上传笔记图片 / 换临时访问链接 / 删图）。index.js 里传的是同一个 app。
  const app = deps.app;
  const _ = db.command;

  const accounts = () => db.collection("tradeAccounts");
  const positions = () => db.collection("tradePositions");
  const orders = () => db.collection("tradeOrders");
  const fills = () => db.collection("tradeFills");
  const sessions = () => db.collection("tradeSessions");
  const draws = () => db.collection("tradeDraw");

  async function ensureCollections() {
    if (collectionsEnsured) return;
    for (const name of COLLECTIONS) {
      try {
        await db.createCollection(name);
      } catch (e) {
        // 已存在或无权限都继续，真出错会在下面的读写里暴露。
      }
    }
    collectionsEnsured = true;
  }

  // ---------------- 会话 ----------------

  async function createSession(uid) {
    const token = crypto.randomBytes(24).toString("hex");
    await sessions().add({
      _id: token,
      uid,
      createdAt: Date.now(),
      expiresAt: Date.now() + SESSION_TTL,
    });
    return token;
  }

  async function resolveSession(token) {
    if (!token || typeof token !== "string" || token.length < 20) return null;
    const { data } = await sessions().doc(token).get();
    const s = data && data[0];
    if (!s) return null;
    if (s.expiresAt < Date.now()) {
      try {
        await sessions().doc(token).remove();
      } catch (e) {}
      return null;
    }
    return s;
  }

  // ---------------- 交易笔记（网页端私有） ----------------
  //
  // 一张笔记一个文档，和 App 的 userNotes 分开存：App 同步 userNotes 时用 set()
  // 整篇覆盖，网页笔记如果混进去，图片字段会被 App 回传冲掉。
  // 图片只存云存储 fileID，列表/详情用时再换临时链接（bucket 不开公共读）。

  const NOTE_MAX_TITLE = 100;
  // 正文存富文本 HTML：比纯文字长，但仍限一个上限，防止单篇塞爆文档。
  const NOTE_MAX_CONTENT = 100000;
  const NOTE_QUOTA_BYTES = 300 * 1024 * 1024;
  const NOTE_IMAGE_MAX_BYTES = 1.5 * 1024 * 1024;
  const NOTE_PAGE_SIZE = 50;

  const tradeNoteColl = () => db.collection("tradeNotes");

  function noteImagePrefix(uid) {
    return "/tradeNotes/" + uid + "/";
  }

  /** 从字节头识别图片类型：只收 jpeg / png / webp，其余一律拒绝。 */
  function noteImageExt(buf) {
    if (!buf || buf.length < 12) return "";
    if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return "jpg";
    if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return "png";
    if (
      buf.toString("ascii", 0, 4) === "RIFF" &&
      buf.toString("ascii", 8, 12) === "WEBP"
    ) {
      return "webp";
    }
    return "";
  }

  /** 只接受当前用户目录下的 fileID；同一文件只留一次，数量不设上限。 */
  function noteNormalizeImages(uid, arr) {
    if (!Array.isArray(arr)) return [];
    const prefix = noteImagePrefix(uid);
    const seen = new Set();
    const out = [];
    for (let i = 0; i < arr.length; i += 1) {
      const raw = arr[i] || {};
      const fileId = String(raw.fileId || "").trim();
      if (!fileId || fileId.length > 512 || fileId.indexOf(prefix) < 0) continue;
      // fileID 必须是我们自己上传的 cloud:// 路径，且不能带 .. 跳出用户目录。
      if (fileId.indexOf("cloud://") !== 0 || fileId.indexOf("..") >= 0) continue;
      if (seen.has(fileId)) continue;
      seen.add(fileId);
      const size = Math.max(
        0,
        Math.min(NOTE_IMAGE_MAX_BYTES, Math.round(Number(raw.size) || 0))
      );
      out.push({ fileId, size });
    }
    return out;
  }

  function noteImageIdOk(uid, fileId) {
    return (
      typeof fileId === "string" &&
      fileId.indexOf("cloud://") === 0 &&
      fileId.indexOf(noteImagePrefix(uid)) > 0 &&
      fileId.indexOf("..") < 0 &&
      fileId.length <= 512
    );
  }

  /** 从正文 HTML 里按出现顺序取所有 <img data-file-id="...">。 */
  function noteExtractImageIds(html) {
    const ids = [];
    const seen = new Set();
    String(html || "").replace(
      /<img\b[^>]*\bdata-file-id\s*=\s*"([^"]+)"[^>]*>/gi,
      (m, id) => {
        const v = String(id || "").trim();
        if (v && !seen.has(v)) {
          seen.add(v);
          ids.push(v);
        }
        return m;
      }
    );
    return ids;
  }

  function noteEscapeAttr(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/"/g, "&quot;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  /** 只放行编辑器和工具栏用得到的几个样式，别的（position/expression 等）全丢。 */
  function noteSafeStyle(style) {
    const out = [];
    String(style || "")
      .split(";")
      .forEach((part) => {
        const i = part.indexOf(":");
        if (i < 0) return;
        const prop = part.slice(0, i).trim().toLowerCase();
        const val = part.slice(i + 1).trim();
        if (!val) return;
        if (prop === "color" || prop === "background-color") {
          if (
            /^#[0-9a-f]{3,8}$/i.test(val) ||
            /^rgba?\([\d\s.,%]+\)$/i.test(val) ||
            /^[a-z]{3,20}$/i.test(val)
          ) {
            out.push(prop + ":" + val);
          }
        } else if (prop === "font-size") {
          if (/^\d{1,2}px$/.test(val)) out.push("font-size:" + val);
        } else if (prop === "text-align") {
          if (/^(left|center|right|justify)$/i.test(val)) {
            out.push("text-align:" + val.toLowerCase());
          }
        } else if (prop === "line-height") {
          if (/^\d(\.\d+)?$/.test(val)) out.push("line-height:" + val);
        }
      });
    return out.join(";");
  }

  /** 富文本转纯文字，给列表预览/空笔记判断用。 */
  function noteHtmlToText(html) {
    return String(html == null ? "" : html)
      .replace(/<br\s*\/?>/gi, " ")
      .replace(/<\/(p|div|li|h1|h2|h3|blockquote)>/gi, " ")
      .replace(/<[^>]*>/g, " ")
      .replace(/&nbsp;/gi, " ")
      .replace(/&amp;/gi, "&")
      .replace(/&lt;/gi, "<")
      .replace(/&gt;/gi, ">")
      .replace(/&quot;/gi, '"')
      .replace(/&#39;/gi, "'")
      .replace(/\s+/g, " ")
      .trim();
  }

  /**
   * 笔记正文的 HTML 白名单清洗。
   *
   * contenteditable + execCommand 产出的标签有限，但粘贴/改 DOM 仍可能塞进
   * script/iframe/onerror。这里只留下段落、换行、列表、引用和几种内联样式；
   * a 只放行 http(s)，事件属性和 javascript: 一律不输出。
   */
  function sanitizeNoteHtml(input, uid) {
    let html = String(input == null ? "" : input).slice(0, NOTE_MAX_CONTENT * 2);
    html = html.replace(/<!--[\s\S]*?-->/g, "");
    html = html.replace(
      /<\s*(script|style|iframe|object|embed|link|meta|svg|math|form|input|button|textarea|select)[^>]*>[\s\S]*?<\s*\/\s*\1\s*>/gi,
      ""
    );
    html = html.replace(
      /<\s*(script|style|iframe|object|embed|link|meta|svg|math|form|input|button|textarea|select)[^>]*\/?>/gi,
      ""
    );

    const allowed = {
      p: 1, br: 1, div: 1, span: 1, b: 1, strong: 1, i: 1, em: 1, u: 1,
      s: 1, strike: 1, ul: 1, ol: 1, li: 1, blockquote: 1, h1: 1, h2: 1,
      h3: 1, a: 1, img: 1,
    };

    html = html.replace(
      /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)([^>]*)>/g,
      (m, close, tag, attrs) => {
        const t = String(tag || "").toLowerCase();
        if (!allowed[t]) return "";
        if (t === "img") {
          if (close) return "";
          const dm = /data-file-id\s*=\s*(?:"([^"]*)"|'([^']*)')/i.exec(attrs);
          const id = dm ? String(dm[1] || dm[2] || "").trim() : "";
          if (!noteImageIdOk(uid, id)) return "";
          return '<img data-file-id="' + noteEscapeAttr(id) + '" alt="">';
        }
        if (close) return "</" + t + ">";
        let extra = "";
        if (t === "a") {
          const hm = /href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(attrs);
          const href = hm ? String(hm[1] || hm[2] || hm[3] || "").trim() : "";
          if (/^https?:\/\//i.test(href)) {
            extra +=
              ' href="' +
              noteEscapeAttr(href) +
              '" target="_blank" rel="noopener noreferrer"';
          }
        }
        if (
          t === "span" ||
          t === "p" ||
          t === "div" ||
          t === "li" ||
          t === "h1" ||
          t === "h2" ||
          t === "h3" ||
          t === "blockquote"
        ) {
          const sm = /style\s*=\s*(?:"([^"]*)"|'([^']*)')/i.exec(attrs);
          const style = sm ? noteSafeStyle(sm[1] || sm[2] || "") : "";
          if (style) extra += ' style="' + noteEscapeAttr(style) + '"';
        }
        return "<" + t + extra + ">";
      }
    );
    return html.slice(0, NOTE_MAX_CONTENT);
  }

  /**
   * 当前用量：笔记条数（不设上限）+ 图片总字节。
   *
   * 条数用 count() 拿真实总数，不受分页影响；字节用聚合对每篇的 imageBytes
   * 求和，笔记再多也是一次查询。聚合不可用时退回逐页扫描（最多 5 万条），
   * 老数据没有 imageBytes 的就按 images[].size 现算。
   */
  async function noteUsage(uid) {
    let count = 0;
    try {
      const res = await tradeNoteColl()
        .where({ ownerUserId: uid, deletedAt: 0 })
        .count();
      count = Number(res && res.total) || 0;
    } catch (e) {
      console.error("[trade] noteUsage count error:", e && e.message ? e.message : e);
    }

    try {
      const $ = db.command.aggregate;
      const res = await tradeNoteColl()
        .aggregate()
        .match({ ownerUserId: uid })
        .group({
          _id: null,
          bytes: $.sum("$imageBytes"),
          images: $.sum("$imageCount"),
        })
        .end();
      const list = res && (res.list || res.data);
      if (Array.isArray(list)) {
        const row = list[0] || {};
        return {
          count,
          bytes: Math.max(0, Number(row.bytes) || 0),
          images: Math.max(0, Number(row.images) || 0),
        };
      }
    } catch (e) {
      console.error(
        "[trade] noteUsage aggregate error:",
        e && e.message ? e.message : e
      );
    }

    let bytes = 0;
    let images = 0;
    let skip = 0;
    for (let page = 0; page < 100; page += 1) {
      let rows = [];
      try {
        const { data } = await tradeNoteColl()
          .where({ ownerUserId: uid })
          .field({ images: true, imageBytes: true, imageCount: true })
          .skip(skip)
          .limit(500)
          .get();
        rows = data || [];
      } catch (e) {
        break;
      }
      for (const row of rows) {
        const stored = Number(row.imageBytes);
        if (Number.isFinite(stored)) {
          bytes += Math.max(0, stored);
        } else {
          for (const im of row.images || []) {
            bytes += Math.max(0, Number(im && im.size) || 0);
          }
        }
        images +=
          Number(row.imageCount) ||
          (Array.isArray(row.images) ? row.images.length : 0);
      }
      if (rows.length < 500) break;
      skip += 500;
    }
    return { count, bytes, images };
  }

  /** fileID 批量换临时链接（约 2 小时有效），顺序和入参一一对应。 */
  async function noteTempUrls(fileIds) {
    if (!fileIds.length) return [];
    if (!app) return fileIds.map(() => "");
    const map = {};
    for (let i = 0; i < fileIds.length; i += 50) {
      try {
        const res = await app.getTempFileURL({
          fileList: fileIds.slice(i, i + 50),
        });
        for (const f of (res && res.fileList) || []) {
          if (f && f.fileID && f.tempFileURL) map[f.fileID] = f.tempFileURL;
        }
      } catch (e) {
        console.error(
          "[trade] getTempFileURL error:",
          e && e.message ? e.message : e
        );
      }
    }
    return fileIds.map((id) => map[id] || "");
  }

  /** 把正文里 <img data-file-id> 换成带 2 小时临时链接的 img；顺序不变。 */
  async function noteResolveImages(html, uid) {
    const src = String(html == null ? "" : html);
    const ids = noteExtractImageIds(src).filter((id) => noteImageIdOk(uid, id));
    if (!ids.length) return src;
    const urls = await noteTempUrls(ids);
    const map = {};
    ids.forEach((id, i) => {
      map[id] = urls[i] || "";
    });
    return src.replace(/<img\b[^>]*>/gi, (tag) => {
      const dm = /data-file-id\s*=\s*"([^"]+)"/i.exec(tag);
      if (!dm) return "";
      const id = dm[1];
      if (!noteImageIdOk(uid, id)) return "";
      const url = map[id] || "";
      return (
        '<img data-file-id="' +
        noteEscapeAttr(id) +
        '"' +
        (url ? ' src="' + noteEscapeAttr(url) + '"' : "") +
        ' alt="">'
      );
    });
  }

  /** 尽力删云存储文件，失败只打日志，不影响笔记本身的增删。 */
  async function noteDeleteFiles(fileIds) {
    const list = (fileIds || []).filter(Boolean);
    if (!list.length || !app) return;
    for (let i = 0; i < list.length; i += 50) {
      try {
        await app.deleteFile({ fileList: list.slice(i, i + 50) });
      } catch (e) {
        console.error("[trade] deleteFile error:", e && e.message ? e.message : e);
      }
    }
  }

  // ---------------- 账户 ----------------

  async function getOrCreateAccount(uid) {
    const { data } = await accounts().doc(uid).get();
    if (data && data[0]) {
      const acc = data[0];
      const patch = {};
      // 老账户迁移：本金默认 10 万；累计单数用已有成交补上，之后只增不减
      if (!Number.isFinite(acc.baseCash) || acc.baseCash <= 0) patch.baseCash = INITIAL_CASH;
      if (!Number.isFinite(acc.totalTrades)) {
        let n = 0;
        try {
          const old = await fills().where({ uid }).get();
          n = (old.data || []).filter((f) => f.type === "close" || f.type === "liquidated").length;
        } catch (e) {}
        patch.totalTrades = n;
      }
      if (Object.keys(patch).length) {
        Object.assign(acc, patch);
        try {
          await accounts().doc(uid).update({ ...patch, updatedAt: Date.now() });
        } catch (e) {}
      }
      return acc;
    }
    // 约定：账户文档的 _id 就是 uid，读写都走 doc(uid)，避免 where 查询。
    const fresh = {
      uid,
      cash: INITIAL_CASH,
      baseCash: INITIAL_CASH,
      totalTrades: 0,
      lastPrice: 0,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    await accounts().doc(uid).set(fresh);
    return fresh;
  }

  async function snapshot(uid) {
    const [acc, pos, ord, fil] = await Promise.all([
      getOrCreateAccount(uid),
      positions().where({ uid }).limit(50).get(),
      orders().where({ uid }).limit(50).get(),
      fills().where({ uid }).orderBy("at", "desc").limit(MAX_FILLS).get(),
    ]);
    return {
      cash: round(acc.cash, 2),
      baseCash: round(acc.baseCash || INITIAL_CASH, 2),
      totalTrades: Number.isFinite(acc.totalTrades) ? acc.totalTrades : 0,
      lastPrice: acc.lastPrice || 0,
      positions: (pos.data || []).map((p) => ({
        id: p._id,
        side: p.side,
        qty: p.qty,
        entry: p.entry,
        margin: p.margin,
        openFee: p.openFee,
        openedAt: p.createdAt,
      })),
      orders: (ord.data || []).map((o) => ({
        id: o._id,
        side: o.side,
        price: o.price,
        qty: o.qty,
        createdAt: o.createdAt,
      })),
      history: (fil.data || []).map((f) => ({
        id: f._id,
        type: f.type,
        side: f.side,
        qty: f.qty,
        price: f.price,
        fee: f.fee,
        pnl: f.pnl || 0,
        posId: f.posId || "",
        at: f.at,
      })),
    };
  }

  /**
   * 校验客户端上报的价格：必须是正数、在合理区间内，且与该账户上一次
   * 看到的价格偏离不超过 5%（第一次调用没有上次价格，只做区间校验）。
   * 距上次上报超过 30 秒就放宽——长时间没调用（切后台、断网）之后，
   * 市场本来就可能跳空，这时再卡 5% 会把正常操作挡在外面。
   * 返回 null 表示可用，否则返回错误码。
   */
  async function checkPrice(uid, price) {
    if (!Number.isFinite(price) || price <= 0) return "bad_price";
    if (price < 1000 || price > 10000000) return "bad_price";
    const { data } = await accounts().doc(uid).get();
    const acc = data && data[0];
    const last = acc && acc.lastPrice;
    const at = (acc && acc.lastPriceAt) || 0;
    const stale = Date.now() - at > 30000;
    if (last > 0 && !stale && Math.abs(price - last) / last > MAX_PRICE_DRIFT) {
      return "price_deviation";
    }
    try {
      await accounts().doc(uid).update({ lastPrice: price, lastPriceAt: Date.now(), updatedAt: Date.now() });
    } catch (e) {}
    return null;
  }

  async function touchAccount(uid, patch) {
    try {
      await accounts().doc(uid).update({ ...patch, updatedAt: Date.now() });
    } catch (e) {}
  }

  async function addFill(uid, entry) {
    const doc = { uid, at: Date.now(), fee: round(entry.fee, 6), pnl: round(entry.pnl || 0, 6) };
    const { id } = await fills().add({
      ...doc,
      type: entry.type,
      side: entry.side,
      qty: entry.qty,
      price: entry.price,
      posId: entry.posId || "",
    });
    // 只保留最近 MAX_FILLS 条，超出的老记录直接删
    const { data } = await fills().where({ uid }).orderBy("at", "desc").limit(MAX_FILLS + 20).get();
    const all = data || [];
    for (let i = MAX_FILLS; i < all.length; i++) {
      try {
        await fills().doc(all[i]._id).remove();
      } catch (e) {}
    }
    return id;
  }

  /**
   * 开仓：kind='market' 直接用 price 成交；kind='limit' 挂单等 tradeSync 触发。
   */
  /**
   * 同方向还没平仓的持仓合并成一单：数量、保证金、手续费相加，
   * 开仓价按「总成本 / 总数量」算加权均价。返回持仓 id。
   */
  async function addOrMergePosition(uid, side, qty, price, margin, fee) {
    const { data } = await positions().where({ uid, side }).limit(1).get();
    const existing = data && data[0];
    if (existing) {
      const total = roundQty(existing.qty + qty);
      const entry = total > 0
        ? round((existing.entry * existing.qty + price * qty) / total, 8)
        : price;
      await positions().doc(existing._id).update({
        qty: total,
        entry,
        margin: round((existing.margin || 0) + margin, 6),
        openFee: round((existing.openFee || 0) + fee, 6),
      });
      return existing._id;
    }
    const { id } = await positions().add({
      uid,
      side,
      qty,
      entry: price,
      margin,
      openFee: fee,
      createdAt: Date.now(),
    });
    return id;
  }

  /**
   * 老数据迁移：同一方向曾经存成多笔的，合并成一笔。
   * 每个云函数实例对每个用户只跑一次，开销可忽略。
   */
  const consolidatedUsers = new Set();
  async function consolidatePositions(uid) {
    if (consolidatedUsers.has(uid)) return;
    consolidatedUsers.add(uid);
    const { data } = await positions().where({ uid }).limit(50).get();
    const groups = {};
    for (const p of data || []) {
      if (p.side !== "long" && p.side !== "short") continue;
      if (!groups[p.side]) groups[p.side] = [];
      groups[p.side].push(p);
    }
    for (const side of Object.keys(groups)) {
      const list = groups[side].sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));
      if (list.length < 2) continue;
      const keep = list[0];
      let qty = 0;
      let cost = 0;
      let margin = 0;
      let fee = 0;
      for (const p of list) {
        const q = +p.qty || 0;
        qty += q;
        cost += (+p.entry || 0) * q;
        margin += +p.margin || 0;
        fee += +p.openFee || 0;
      }
      qty = roundQty(qty);
      await positions().doc(keep._id).update({
        qty,
        entry: qty > 0 ? round(cost / qty, 8) : keep.entry,
        margin: round(margin, 6),
        openFee: round(fee, 6),
      });
      for (let i = 1; i < list.length; i++) {
        try {
          await positions().doc(list[i]._id).remove();
        } catch (e) {}
      }
    }
  }

  async function openPosition(uid, params, marketPrice) {
    const side = params.side === "short" ? "short" : "long";
    let qty = roundQty(num(params.qty));
    if (!Number.isFinite(qty) || qty <= 0 || qty > MAX_QTY) return fail("bad_qty");

    if (params.kind === "limit") {
      const price = roundPrice(num(params.price));
      if (!Number.isFinite(price) || price <= 0) return fail("bad_price");
      if (price * qty < MIN_NOTIONAL) return fail("min_notional");
      if (rateLimited("order:" + uid)) return fail("rate_limited");
      const { id } = await orders().add({ uid, side, price, qty, createdAt: Date.now() });
      return ok({ account: await snapshot(uid), pendingOrder: { id, side, price, qty } });
    }

    const price = roundPrice(num(params.price));
    if (!Number.isFinite(price) || price <= 0) return fail("bad_price");
    if (price * qty < MIN_NOTIONAL) return fail("min_notional");
    if (rateLimited("order:" + uid)) return fail("rate_limited");

    const acc = await getOrCreateAccount(uid);
    let fee = price * qty * FEE_RATE;
    let margin = price * qty;
    // 100% 时价格可能跳了一点：差额在 0.5% 内按可用余额截一下，直接成交
    if (acc.cash < margin + fee) {
      const affordable = Math.floor((acc.cash / (price * (1 + FEE_RATE))) * 1e6) / 1e6;
      if (affordable > 0 && qty <= affordable * 1.005 + 1e-6) {
        qty = affordable;
        fee = price * qty * FEE_RATE;
        margin = price * qty;
      }
    }
    if (price * qty < MIN_NOTIONAL) return fail("min_notional");
    if (acc.cash < margin + fee) return fail("insufficient_balance");

    await accounts().doc(uid).update({
      cash: round(acc.cash - margin - fee, 6),
      updatedAt: Date.now(),
    });
    const posId = await addOrMergePosition(uid, side, qty, price, margin, fee);
    await addFill(uid, { type: "open", side, qty, price, fee, pnl: 0, posId });
    return ok({ account: await snapshot(uid) });
  }

  /**
   * 平仓 / 强平。price 为 mark，liquidated=true 时不再扣手续费、返还 0。
   */
  async function closePosition(uid, pos, price, liquidated, pct) {
    const frac = pct == null || !(pct > 0) ? 1 : Math.min(1, pct);
    const qtyPart = roundQty(pos.qty * frac);
    if (!(qtyPart > 0)) return 0;
    const diff = pos.side === "short" ? pos.entry - price : price - pos.entry;
    const pnl = diff * qtyPart * PNL_MULT;
    const fee = liquidated ? 0 : price * qtyPart * FEE_RATE;
    const marginPart = pos.margin * frac;
    let proceeds = marginPart + pnl - fee;
    if (proceeds < 0) proceeds = 0; // 不穿仓
    const acc = await getOrCreateAccount(uid);

    if (frac >= 1 - 1e-9) {
      await positions().doc(pos._id).remove();
    } else {
      await positions().doc(pos._id).update({
        qty: roundQty(pos.qty - qtyPart),
        margin: round(pos.margin - marginPart, 6),
        openFee: round((pos.openFee || 0) * (1 - frac), 6),
      });
    }
    await accounts().doc(uid).update({
      cash: round(acc.cash + proceeds, 6),
      totalTrades: (Number.isFinite(acc.totalTrades) ? acc.totalTrades : 0) + 1,
      updatedAt: Date.now(),
    });
    await addFill(uid, {
      type: liquidated ? "liquidated" : "close",
      side: pos.side,
      qty: qtyPart,
      price,
      fee,
      pnl,
      posId: pos._id,
    });
    return proceeds;
  }

  /** 用当前价撮合该用户的挂单 + 检查是否触发强平。返回是否有变化。 */
  async function matchOrders(uid, price) {
    const [ordRes, posRes] = await Promise.all([
      orders().where({ uid }).limit(50).get(),
      positions().where({ uid }).limit(50).get(),
    ]);
    let changed = false;

    for (const o of ordRes.data || []) {
      const hit = o.side === "long" ? price <= o.price : price >= o.price;
      if (!hit) continue;
      // 成交价用市价（对挂单方更优），不要用挂单价假装成交。
      const fillPrice = roundPrice(price);
      const qty = o.qty;
      const fee = fillPrice * qty * FEE_RATE;
      const margin = fillPrice * qty;
      const acc = await getOrCreateAccount(uid);
      if (acc.cash < margin + fee) {
        // 资金不足：撤单而不是硬成交
        await orders().doc(o._id).remove();
        changed = true;
        continue;
      }
      await orders().doc(o._id).remove();
      await accounts().doc(uid).update({ cash: round(acc.cash - margin - fee, 6), updatedAt: Date.now() });
      const posId = await addOrMergePosition(uid, o.side, qty, fillPrice, margin, fee);
      await addFill(uid, { type: "open", side: o.side, qty, price: fillPrice, fee, pnl: 0, posId });
      changed = true;
    }

    const posNow = await positions().where({ uid }).limit(50).get();
    for (const p of posNow.data || []) {
      const pdiff = p.side === "short" ? p.entry - price : price - p.entry;
      const pnl = pdiff * p.qty * PNL_MULT;
      if (p.margin + pnl > 0) continue;
      await closePosition(uid, p, price, true);
      changed = true;
    }
    return changed;
  }

  // ---------------- 认证（账号 + 密码） ----------------

  async function findAccount(usernameKey) {
    const { data } = await db
      .collection("userAccounts")
      .where({ usernameKey })
      .limit(1)
      .get();
    return data && data[0] ? data[0] : null;
  }

  function checkPassword(acc, password) {
    if (!acc.passwordHash) return false;
    try {
      return deps.hashPassword(password, acc.salt) === acc.passwordHash;
    } catch (e) {
      return false;
    }
  }

  // ---------------- 手机号：绑定 / 找回密码 ----------------
  //
  // 短信复用云开发自带的验证码服务（App 端 signInWithOtp 就是这一套），
  // 服务端拿发布密钥直接调它的 REST 接口，只用来证明「手机在你手上」：
  //   POST /auth/v1/verification        发码 -> verification_id
  //   POST /auth/v1/verification/verify 校验 -> verification_token
  // 手机号↔账号的对应关系自己存（tradePhones，_id 就是手机号），
  // 不建 CloudBase 用户，也不影响 App 那边的手机验证码登录。

  const AUTH_ENV = process.env.TCB_ENV || "randeng-d8gs968w22a3d98e8";
  // 发布密钥是发给浏览器的公开值（每个页面里都带着），写在这里不算泄密。
  const AUTH_KEY = process.env.CLOUDBASE_PUBLISHABLE_KEY ||
    "eyJhbGciOiJSUzI1NiIsImtpZCI6IjlkMWRjMzFlLWI0ZDAtNDQ4Yi1hNzZmLWIwY2M2M2Q4MTQ5OCJ9" +
    ".eyJpc3MiOiJodHRwczovL3JhbmRlbmctZDhnczk2OHcyMmEzZDk4ZTguYXAtc2hhbmdoYWkudGNiLWFwaS50" +
    "ZW5jZW50Y2xvdWRhcGkuY29tIiwic3ViIjoiYW5vbiIsImF1ZCI6InJhbmRlbmctZDhnczk2OHcyMmEzZDk4" +
    "ZTgiLCJleHAiOjQwODkyNDU0MTEsImlhdCI6MTc4NTU2MjIxMSwibm9uY2UiOiJYTmpVYVlTclJONi1ZVkk3" +
    "bUlOUXF3IiwiYXRfaGFzaCI6IlhOalVhWVNyUk42LVlWSTdtSU5RcXciLCJuYW1lIjoiQW5vbnltb3VzIiwi" +
    "c2NvcGUiOiJhbm9ueW1vdXMiLCJwcm9qZWN0X2lkIjoicmFuZGVuZy1kOGdzOTY4dzIyYTNkOThlOCIsIm1l" +
    "dGEiOnsicGxhdGZvcm0iOiJQdWJsaXNoYWJsZUtleSJ9LCJ1c2VyX3R5cGUiOiIiLCJjbGllbnRfdHlwZSI6" +
    "ImNsaWVudF91c2VyIiwiaXNfc3lzdGVtX2FkbWluIjpmYWxzZX0.hCs04BM4hFTqIcdf0SS7vgnIP9-Um4vvw" +
    "WLNzHlSTaEQ8QzAcaFoW2foDJE7ReiiOPYgnOXw75TcsdHIr6HsRMNgalCNGNmjxRv2WSK3dpgIe6wr65tNOn" +
    "5eTxWM-M-96hgNLpVksUDw46Ejq58rINjGl674DPw-FxeGc8EbngInBkJSN-6-XWwTCglGDTRdygeR70CQGw" +
    "buYjw8MYvFxAo190ENtSJcWZf9ZphlgIj52mMoQXqE1FsefSQEfSDjFyuh1RHSRkNVEbecmO98J8ybQjbkkt0" +
    "p905DoQucKpz_W6MvMwkDTeH3jnIwYguBs8G_j_jcXQtAguPGZ6ed8w";

  const CODE_TTL = 5 * 60 * 1000; // 验证码 5 分钟有效
  const CODE_TRIES = 5; // 同一条验证码最多试 5 次
  const SEND_GAP = 60 * 1000; // 同一手机号 60 秒一条
  const SEND_DAILY = 8; // 同一手机号 24 小时最多 8 条

  const phones = () => db.collection("tradePhones");
  const phoneCodes = () => db.collection("tradePhoneCodes");

  function authPost(path, body) {
    return new Promise((resolve) => {
      const payload = JSON.stringify(body || {});
      const req = https.request(
        {
          hostname: AUTH_ENV + ".api.tcloudbasegateway.com",
          path: path + "?client_id=" + encodeURIComponent(AUTH_ENV),
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Content-Length": Buffer.byteLength(payload),
            Authorization: "Bearer " + AUTH_KEY,
            "x-device-id": "web",
          },
        },
        (res) => {
          let raw = "";
          res.setEncoding("utf8");
          res.on("data", (c) => { raw += c; });
          res.on("end", () => {
            let json = null;
            try { json = JSON.parse(raw); } catch (e) {}
            resolve({ status: res.statusCode, json, raw });
          });
        }
      );
      req.on("error", (e) => resolve({ status: 0, json: null, raw: String(e && e.message) }));
      req.setTimeout(8000, () => {
        try { req.destroy(new Error("timeout")); } catch (e) {}
      });
      req.write(payload);
      req.end();
    });
  }

  /** 中国大陆手机号归一化：接受 138…、+86138…、86-138…，返回 {local, display}。 */
  function normalizePhone(raw) {
    let d = String(raw || "").replace(/[\s()\-]/g, "");
    if (d.startsWith("+86")) d = d.slice(3);
    else if (d.startsWith("86") && d.length === 13) d = d.slice(2);
    if (!/^1[3-9]\d{9}$/.test(d)) return null;
    return { local: d, display: d.slice(0, 3) + "****" + d.slice(7) };
  }

  function todayKey() {
    // 按北京时间切天，和国内用户直觉一致
    return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
  }

  /** n 位随机小写字母：手机号注册自动建账号名时用，和 App 默认账号同一套规则。 */
  function randomLower(n) {
    const abc = "abcdefghijklmnopqrstuvwxyz";
    const buf = crypto.randomBytes(n);
    let s = "";
    for (let i = 0; i < n; i++) s += abc[buf[i] % 26];
    return s;
  }

  function authField(json, key) {
    if (!json) return "";
    return String(json[key] || (json.data && json.data[key]) || "");
  }

  function verifyFailCode(res) {
    const text = authField(res.json, "error_description") + " " +
      authField(res.json, "message") + " " + String(res.raw || "");
    if (/过期|expired/i.test(text)) return "code_expired";
    if (/错误|不正确|invalid.*code|mismatch/i.test(text)) return "code_wrong";
    return "verify_failed";
  }

  /** 发一条验证码，返回 {ok:true,...} 或失败对象。 */
  async function sendCode(phone) {
    const res = await authPost("/auth/v1/verification", { phone_number: "+86 " + phone.local });
    const vid = authField(res.json, "verification_id");
    if (res.status !== 200 || !vid) return { error: "sms_failed", detail: String(res.raw || "").slice(0, 200) };
    return { verificationId: vid };
  }

  /** 校验验证码，成功返回 verified=true。 */
  async function checkCode(verificationId, code) {
    const res = await authPost("/auth/v1/verification/verify", {
      verification_id: verificationId,
      verification_code: code,
    });
    const token = authField(res.json, "verification_token");
    if (res.status === 200 && token) return { verified: true };
    return { verified: false, error: verifyFailCode(res) };
  }

  async function phoneCode(event, sessionUid) {
    const scene = event.scene === "reset" ? "reset"
      : event.scene === "register" ? "register" : "bind";
    const phone = normalizePhone(event.phone);
    if (!phone) return fail("invalid_phone");

    if (scene === "bind") {
      if (!sessionUid) return fail("unauthorized");
      const { data } = await phones().doc(phone.local).get();
      const owner = data && data[0];
      if (owner && owner.uid && owner.uid !== sessionUid) return fail("phone_taken");
    }
    // 拿已经绑过账号的号来注册：先拦下，别白花一条短信
    if (scene === "register") {
      const { data } = await phones().doc(phone.local).get();
      const owner = data && data[0];
      if (owner && owner.uid) return fail("phone_taken");
    }

    const now = Date.now();
    const day = todayKey();
    const { data: prevData } = await phoneCodes().doc(phone.local).get();
    const prev = prevData && prevData[0];
    if (prev) {
      if (now - (prev.sentAt || 0) < SEND_GAP) return fail("too_frequent");
      if (prev.dayKey === day && (prev.dayCount || 0) >= SEND_DAILY) return fail("too_many");
    }

    const sent = await sendCode(phone);
    if (sent.error) {
      console.log("[trade] 发码失败", phone.display, sent.detail || "");
      return fail(sent.error);
    }

    await phoneCodes().doc(phone.local).set({
      phone: phone.local,
      scene,
      uid: scene === "bind" ? sessionUid : "",
      verificationId: sent.verificationId,
      sentAt: now,
      expiresAt: now + CODE_TTL,
      tries: 0,
      dayKey: day,
      dayCount: prev && prev.dayKey === day ? (prev.dayCount || 0) + 1 : 1,
      createdAt: (prev && prev.createdAt) || now,
    });

    return ok({ id: phone.local, display: phone.display, expiresIn: Math.round(CODE_TTL / 1000) });
  }

  async function phoneConfirm(event, sessionUid) {
    const scene = event.scene === "reset" ? "reset"
      : event.scene === "register" ? "register" : "bind";
    const id = String(event.id || "").trim();
    const code = String(event.code || "").trim();
    if (!/^1[3-9]\d{9}$/.test(id)) return fail("invalid_phone");
    if (!/^\d{4,8}$/.test(code)) return fail("code_wrong");

    const { data } = await phoneCodes().doc(id).get();
    const rec = data && data[0];
    if (!rec || rec.scene !== scene) return fail("code_expired");
    if ((rec.expiresAt || 0) < Date.now()) return fail("code_expired");
    if ((rec.tries || 0) >= CODE_TRIES) return fail("too_many");

    const checked = await checkCode(rec.verificationId, code);
    if (!checked.verified) {
      try {
        await phoneCodes().doc(id).update({ tries: (rec.tries || 0) + 1 });
      } catch (e) {}
      return fail(checked.error || "code_wrong");
    }

    if (scene === "bind") {
      if (!sessionUid) return fail("unauthorized");
      const { data: ownerData } = await phones().doc(id).get();
      const owner = ownerData && ownerData[0];
      if (owner && owner.uid && owner.uid !== sessionUid) return fail("phone_taken");

      const { data: accData } = await db
        .collection("userAccounts")
        .where({ uid: sessionUid })
        .limit(1)
        .get();
      const acc = accData && accData[0];

      // 换绑：先把旧号码的映射删掉，别让旧手机还能重置密码
      if (acc && acc.phone && acc.phone !== id) {
        try {
          await phones().doc(acc.phone).remove();
        } catch (e) {}
      }
      await phones().doc(id).set({ uid: sessionUid, phone: id, createdAt: Date.now() });
      if (acc) {
        try {
          await db.collection("userAccounts").doc(acc._id).update({
            phone: id,
            phoneBoundAt: Date.now(),
            updatedAt: Date.now(),
          });
        } catch (e) {}
      }
      try {
        await phoneCodes().doc(id).remove();
      } catch (e) {}
      return ok({ phone: id.slice(0, 3) + "****" + id.slice(7) });
    }

    // scene === register：手机号 + 验证码直接建号（账号名可留空自动生成），
    // 建完就把手机号绑上，之后忘了密码还能用同一个号找回。
    if (scene === "register") {
      const password = String(event.password || "");
      if (password.length < 6 || password.length > 64) return fail("invalid_password");

      const { data: boundData } = await phones().doc(id).get();
      const bound = boundData && boundData[0];
      if (bound && bound.uid) return fail("phone_taken");

      const wantName = String(event.username || "").trim();
      let username = "";
      if (wantName) {
        username = deps.normalizeUsername(wantName);
        if (!username) return fail("invalid_username");
        const exists = await findAccount(username.toLowerCase());
        if (exists) return fail("username_taken");
      } else {
        // 和 App「手机号登录自动建号」同一套规则：4 位随机小写 + 手机号后四位
        const tail = id.slice(7);
        for (let i = 0; i < 6 && !username; i++) {
          const cand = randomLower(4) + tail;
          const exists = await findAccount(cand.toLowerCase());
          if (!exists) username = cand;
        }
        if (!username) return fail("username_taken");
      }

      const newUid = "web_" + crypto.randomBytes(14).toString("hex");
      const salt = crypto.randomBytes(16).toString("hex");
      await db.collection("userAccounts").add({
        username,
        usernameKey: username.toLowerCase(),
        salt,
        passwordHash: deps.hashPassword(password, salt),
        hasPassword: true,
        uid: newUid,
        phone: id,
        phoneBoundAt: Date.now(),
        createdAt: Date.now(),
        updatedAt: Date.now(),
      });
      await phones().doc(id).set({ uid: newUid, phone: id, createdAt: Date.now() });
      await getOrCreateAccount(newUid);
      const token = await createSession(newUid);
      try {
        await phoneCodes().doc(id).remove();
      } catch (e) {}
      return ok({
        token,
        uid: newUid,
        username,
        phone: id.slice(0, 3) + "****" + id.slice(7),
        registered: true,
      });
    }

    // scene === reset
    const newPassword = String(event.newPassword || "");
    if (newPassword.length < 6 || newPassword.length > 64) return fail("invalid_password");

    const { data: bindData } = await phones().doc(id).get();
    const bind = bindData && bindData[0];
    if (!bind || !bind.uid) return fail("phone_not_bound");

    const { data: accData } = await db
      .collection("userAccounts")
      .where({ uid: bind.uid })
      .limit(1)
      .get();
    const acc = accData && accData[0];
    if (!acc) return fail("account_not_found");

    const salt = crypto.randomBytes(16).toString("hex");
    await db.collection("userAccounts").doc(acc._id).update({
      salt,
      passwordHash: deps.hashPassword(newPassword, salt),
      hasPassword: true,
      updatedAt: Date.now(),
    });
    // 旧会话全部作废：密码换了，老 token 不能继续用
    await removeWhere(sessions(), bind.uid);
    try {
      await phoneCodes().doc(id).remove();
    } catch (e) {}
    return ok({ username: acc.username || "", phone: id.slice(0, 3) + "****" + id.slice(7) });
  }

  /**
   * 网页注册：往 userAccounts 写一条带密码的记录，uid 由服务端生成。
   *
   * 这张表就是 App「账号密码登录」读的那张，所以网页注册的账号，
   * 在燃灯 App 里可以直接用 loginWithAccount 登录（那边会拿 acc.uid 签 ticket）。
   */
  async function register(event, uid) {
    const username = deps.normalizeUsername(event.username);
    if (!username) return fail("invalid_username");
    const password = String(event.password || "");
    if (password.length < 6 || password.length > 64) return fail("invalid_password");
    if (rateLimited("register")) return fail("rate_limited");

    const usernameKey = username.toLowerCase();
    const existing = await findAccount(usernameKey);
    if (existing) return fail("username_taken");

    // uid 必须过得了 CloudBase 自定义登录 createTicket 的校验：
    //   ^[a-zA-Z0-9_\-#@~=*(){}[\]:.,<>+]{4,32}$
    // 所以固定 32 位（web_ + 28 位十六进制）。写长了网页侧照样注册成功，
    // 只有在 App 里用这个账号登录时才报 Invalid uid —— 联调时踩过一次。
    const newUid = uid || "web_" + crypto.randomBytes(14).toString("hex");
    const salt = crypto.randomBytes(16).toString("hex");
    await db.collection("userAccounts").add({
      username,
      usernameKey,
      salt,
      passwordHash: deps.hashPassword(password, salt),
      hasPassword: true,
      uid: newUid,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });
    const token = await createSession(newUid);
    await getOrCreateAccount(newUid);
    return ok({ token, uid: newUid, username, registered: true });
  }

  async function login(event) {
    const username = String(event.username || "").trim().toLowerCase();
    const password = String(event.password || "");
    if (!username) return fail("bad_request");
    if (rateLimited("login")) return fail("rate_limited");
    const acc = await findAccount(username);
    if (!acc) return fail("account_not_found");
    if (!acc.passwordHash) return fail("no_password"); // 手机号登录建的默认账号，还没设密码
    if (!checkPassword(acc, password)) return fail("wrong_password");
    const token = await createSession(acc.uid);
    await getOrCreateAccount(acc.uid);
    return ok({ token, uid: acc.uid, username: acc.username || username });
  }

  // ---------------- 入口 ----------------

  async function removeWhere(coll, uid) {
    const { data } = await coll.where({ uid }).limit(100).get();
    for (const doc of data || []) {
      try {
        await coll.doc(doc._id).remove();
      } catch (e) {}
    }
  }

  /** 公开分享页：只凭 shareId 读一条未删除的笔记，不需要登录。 */
  async function publicNoteGet(event) {
    const shareId = String(event.shareId || "").trim();
    if (!shareId || shareId.length > 64) return fail("not_found");
    try {
      const { data } = await tradeNoteColl()
        .where({ shareId, deletedAt: 0 })
        .limit(1)
        .get();
      const n = data && data[0];
      if (!n) return fail("not_found");
      const content = await noteResolveImages(n.content, n.ownerUserId);
      return ok({
        note: {
          title: n.title || "",
          content,
          contentFormat: "html",
          lineHeight: Number(n.lineHeight) || 1.75,
          createdAt: n.createdAt || n.updatedAt || 0,
        },
      });
    } catch (e) {
      console.error("[trade] publicNoteGet error:", e && e.message ? e.message : e);
      return fail("not_found");
    }
  }

  /**
   * 返回 undefined 表示不是交易类 action，交给 index.js 原有的 switch。
   * 其余一律返回要直接 return 给调用方的对象。
   */
  return async function handle(action, event, uid) {
    if (typeof action !== "string" || !action.startsWith("trade")) return undefined;

    try {
      await ensureCollections();

      // 分享出去的笔记页是公开的：只认 shareId，先于会话校验。
      if (action === "tradeNotePublicGet") return await publicNoteGet(event);

      if (action === "tradeRegister") return await register(event, uid);
      if (action === "tradeLogin") return await login(event);

      // 找回密码时用户还没登录，所以手机号相关动作先于会话校验；
      // 只有「绑定手机」这一路需要登录态。
      if (action === "tradePhoneCode" || action === "tradePhoneConfirm") {
        // 找回密码 / 手机号注册都还没登录，只有「绑定手机」需要登录态
        const needLogin = event.scene !== "reset" && event.scene !== "register";
        const session = needLogin ? await resolveSession(event.token) : null;
        if (action === "tradePhoneCode") return await phoneCode(event, session && session.uid);
        return await phoneConfirm(event, session && session.uid);
      }

      const session = await resolveSession(event.token);
      if (!session) return fail("unauthorized");
      const me = session.uid;
      await getOrCreateAccount(me);

      if (action === "tradeState") {
        // 历史数据兼容：同方向的多笔持仓先并成一单，再返回给前端
        await consolidatePositions(me);
        const account = await snapshot(me);
        // 带上绑定手机（脱敏），前端据此显示「已绑定 138****0000」
        let boundPhone = "";
        try {
          const { data } = await db
            .collection("userAccounts")
            .where({ uid: me })
            .limit(1)
            .get();
          const rec = data && data[0];
          if (rec) {
            boundPhone = String(rec.phone || rec.mobilePhoneNumber || rec.mobile || "");
          }
          // 网页绑定过的号码也有一份 uid→手机号 的映射
          if (!boundPhone) {
            const { data: pd } = await phones().where({ uid: me }).limit(1).get();
            const p = pd && pd[0];
            if (p && p.phone) boundPhone = String(p.phone);
          }
        } catch (e) {}

        // App 手机号登录的账号，手机号在 CloudBase 身份里，不在 userAccounts；
        // 用 Admin 接口按 uid 读一次，自动同步到网页头像菜单，避免再绑一遍。
        if (!boundPhone && app && typeof app.auth === "function") {
          try {
            const auth = app.auth();
            if (auth && typeof auth.getEndUserInfo === "function") {
              const info = await auth.getEndUserInfo(me);
              const u = info && info.userInfo;
              if (u) {
                boundPhone = String(
                  u.phone || u.phoneNumber || u.phone_number ||
                  u.mobilePhoneNumber || u.mobile || ""
                );
              }
            }
          } catch (e) {}
        }

        if (boundPhone) {
          const digits = boundPhone.replace(/\D/g, "");
          const shown = digits.length >= 11 ? digits.slice(-11) : boundPhone;
          account.phone = shown.slice(0, 3) + "****" + shown.slice(-4);
        }
        return ok({ account });
      }

      // 画线（直线/自由画线）跨设备保存：按 uid 存一份 JSON
      if (action === "tradeDrawGet") {
        try {
          const { data } = await draws().doc(me).get();
          const rec = data && data[0];
          return ok({ drawings: rec && Array.isArray(rec.drawings) ? rec.drawings : [] });
        } catch (e) {
          return ok({ drawings: [] });
        }
      }

      if (action === "tradeDrawSet") {
        const list = Array.isArray(event.drawings) ? event.drawings : [];
        let size = 0;
        try { size = JSON.stringify(list).length; } catch (e) { return fail("bad_request"); }
        if (size > 200000) return fail("too_large");
        await ensureCollections();
        await draws().doc(me).set({
          uid: me,
          drawings: list,
          size,
          updatedAt: Date.now(),
        });
        return ok({ saved: true, size });
      }

      // ==================== 交易笔记（网页端私有） ====================

      if (action === "tradeNoteList") {
        const pageSize = Math.min(
          Math.max(Number(event.pageSize) || NOTE_PAGE_SIZE, 1),
          100
        );
        const offset = Math.max(0, Math.floor(Number(event.offset) || 0));
        const { data } = await tradeNoteColl()
          .where({ ownerUserId: me, deletedAt: 0 })
          .orderBy("createdAt", "desc")
          .orderBy("_id", "desc")
          .skip(offset)
          .limit(pageSize)
          .get();
        const rows = data || [];
        const list = rows.map((n) => ({
          noteId: n._id,
          title: n.title || "",
          preview:
            n.preview != null && n.preview !== ""
              ? n.preview
              : noteHtmlToText(n.content).slice(0, 120),
          imageCount:
            Number(n.imageCount) ||
            (Array.isArray(n.images) ? n.images.length : 0),
          createdAt: n.createdAt || n.updatedAt || 0,
          updatedAt: n.updatedAt || 0,
        }));
        const usage = await noteUsage(me);
        return ok({
          notes: list,
          // 条数不设上限，前端按 offset 一页页取；取满一页就还有下一页。
          nextOffset: rows.length === pageSize ? offset + rows.length : null,
          usage: {
            count: usage.count,
            bytes: usage.bytes,
            images: usage.images,
            limitBytes: NOTE_QUOTA_BYTES,
          },
        });
      }

      if (action === "tradeNoteGet") {
        const id = String(event.noteId || "");
        if (!id) return fail("bad_request");
        const { data } = await tradeNoteColl().doc(id).get();
        const n = data && data[0];
        if (!n || n.ownerUserId !== me || n.deletedAt) return fail("not_found");
        const images = noteNormalizeImages(me, n.images);
        const html =
          n.contentFormat === "html"
            ? await noteResolveImages(n.content, me)
            : n.content || "";
        return ok({
          note: {
            noteId: n._id,
            title: n.title || "",
            content: html,
            // 老笔记没有 contentFormat，按纯文字渲染；新笔记统一存清洗后的 HTML。
            contentFormat: n.contentFormat === "html" ? "html" : "text",
            lineHeight: Number(n.lineHeight) || 1.75,
            images: images.map((im) => ({
              fileId: im.fileId,
              size: im.size,
            })),
            createdAt: n.createdAt || 0,
            updatedAt: n.updatedAt || 0,
          },
        });
      }

      if (action === "tradeNoteSave") {
        if (rateLimited("note-save:" + me)) return fail("rate_limited");
        const title = String(event.title == null ? "" : event.title)
          .trim()
          .slice(0, NOTE_MAX_TITLE);
        // 正文是 contenteditable 的 HTML；先清洗再存，图片按正文里的
        // <img data-file-id> 顺序提取，不再用单独的图片数组决定数量/顺序。
        const content = sanitizeNoteHtml(
          String(event.content == null ? "" : event.content),
          me
        );
        const contentText = noteHtmlToText(content);
        const lineHeight = Math.min(
          3,
          Math.max(1, Math.round((Number(event.lineHeight) || 1.75) * 100) / 100)
        );
        const meta = noteNormalizeImages(me, event.images);
        const sizeMap = {};
        meta.forEach((im) => {
          sizeMap[im.fileId] = im.size;
        });
        const images = noteExtractImageIds(content)
          .filter((id) => noteImageIdOk(me, id))
          .map((id) => ({ fileId: id, size: sizeMap[id] || 0 }));
        if (!title && !contentText && images.length === 0) {
          return fail("empty_note");
        }
        const nowMs = Date.now();
        const imageBytes = images.reduce(
          (sum, im) => sum + Math.max(0, Number(im && im.size) || 0),
          0
        );
        const imageCount = images.length;
        const preview = contentText.slice(0, 120);
        const id = String(event.noteId || "");
        if (id) {
          const { data } = await tradeNoteColl().doc(id).get();
          const old = data && data[0];
          if (!old || old.ownerUserId !== me || old.deletedAt) {
            return fail("not_found");
          }
          const keep = new Set(images.map((im) => im.fileId));
          const removed = (Array.isArray(old.images) ? old.images : [])
            .map((im) => String((im && im.fileId) || ""))
            .filter((f) => f && !keep.has(f));
          await tradeNoteColl().doc(id).update({
            title,
            content,
            contentFormat: "html",
            lineHeight,
            preview,
            images,
            imageBytes,
            imageCount,
            updatedAt: nowMs,
          });
          if (removed.length) await noteDeleteFiles(removed);
          return ok({
            noteId: id,
            title,
            preview,
            imageCount,
            createdAt: old.createdAt || 0,
            updatedAt: nowMs,
            usage: await noteUsage(me),
          });
        }
        const res = await tradeNoteColl().add({
          ownerUserId: me,
          title,
          content,
          contentFormat: "html",
          lineHeight,
          preview,
          images,
          imageBytes,
          imageCount,
          createdAt: nowMs,
          updatedAt: nowMs,
          deletedAt: 0,
        });
        return ok({
          noteId: (res && (res.id || res._id)) || "",
          title,
          preview,
          imageCount,
          createdAt: nowMs,
          updatedAt: nowMs,
          usage: await noteUsage(me),
        });
      }

      if (action === "tradeNoteDelete") {
        const id = String(event.noteId || "");
        if (!id) return fail("bad_request");
        const { data } = await tradeNoteColl().doc(id).get();
        const n = data && data[0];
        if (!n || n.ownerUserId !== me) return fail("not_found");
        // 软删除：进回收站，图片先留着，彻底删除时才删云存储。
        await tradeNoteColl().doc(id).update({ deletedAt: Date.now() });
        return ok({ deleted: true, trashed: true, usage: await noteUsage(me) });
      }

      if (action === "tradeNoteRestore") {
        const id = String(event.noteId || "");
        if (!id) return fail("bad_request");
        const { data } = await tradeNoteColl().doc(id).get();
        const n = data && data[0];
        if (!n || n.ownerUserId !== me || !n.deletedAt) return fail("not_found");
        await tradeNoteColl().doc(id).update({
          deletedAt: 0,
          updatedAt: Date.now(),
        });
        return ok({ restored: true, usage: await noteUsage(me) });
      }

      if (action === "tradeNotePurge") {
        const id = String(event.noteId || "");
        if (!id) return fail("bad_request");
        const { data } = await tradeNoteColl().doc(id).get();
        const n = data && data[0];
        if (!n || n.ownerUserId !== me) return fail("not_found");
        await tradeNoteColl().doc(id).remove();
        const ids = (n.images || []).map((im) => im && im.fileId);
        await noteDeleteFiles(ids.concat(noteExtractImageIds(n.content)));
        return ok({ purged: true, usage: await noteUsage(me) });
      }

      if (action === "tradeNoteTrashList") {
        const pageSize = Math.min(
          Math.max(Number(event.pageSize) || NOTE_PAGE_SIZE, 1),
          100
        );
        const offset = Math.max(0, Math.floor(Number(event.offset) || 0));
        const { data } = await tradeNoteColl()
          .where({ ownerUserId: me, deletedAt: _.gt(0) })
          .orderBy("deletedAt", "desc")
          .orderBy("_id", "desc")
          .skip(offset)
          .limit(pageSize)
          .get();
        const rows = data || [];
        return ok({
          notes: rows.map((n) => ({
            noteId: n._id,
            title: n.title || "",
            createdAt: n.createdAt || n.updatedAt || 0,
            deletedAt: n.deletedAt || 0,
            imageCount:
              Number(n.imageCount) ||
              (Array.isArray(n.images) ? n.images.length : 0),
          })),
          nextOffset: rows.length === pageSize ? offset + rows.length : null,
          usage: await noteUsage(me),
        });
      }

      if (action === "tradeNoteShare") {
        const id = String(event.noteId || "");
        if (!id) return fail("bad_request");
        const { data } = await tradeNoteColl().doc(id).get();
        const n = data && data[0];
        if (!n || n.ownerUserId !== me || n.deletedAt) {
          return fail("not_found");
        }
        let shareId = String(n.shareId || "");
        if (!shareId) {
          shareId = crypto.randomBytes(12).toString("hex");
          await tradeNoteColl().doc(id).update({
            shareId,
            sharedAt: Date.now(),
          });
        }
        return ok({
          shareId,
          url: "https://aibuilder.top/note.html?s=" + shareId,
        });
      }

      if (action === "tradeAvatarGet") {
        try {
          const { data } = await db.collection("tradeProfiles").doc(me).get();
          const rec = data && data[0];
          return ok({ avatar: rec && rec.avatar ? String(rec.avatar) : "" });
        } catch (e) {
          return ok({ avatar: "" });
        }
      }

      if (action === "tradeAvatarSet") {
        const raw = String(event.avatar || "");
        if (!/^data:image\/(jpeg|png|webp);base64,/i.test(raw)) {
          return fail("bad_image");
        }
        if (raw.length > 60000) return fail("too_large");
        await db.collection("tradeProfiles").doc(me).set({
          avatar: raw,
          updatedAt: Date.now(),
        });
        return ok({ saved: true });
      }

      if (action === "tradeNoteUpload") {
        if (!app) return fail("storage_unavailable");
        if (rateLimited("note-up:" + me)) return fail("rate_limited");
        const raw = String(event.data || "");
        if (!raw) return fail("empty_image");
        // base64 会膨胀 4/3；先按字符串长度挡掉超大包，别等 Buffer 分配完才发现。
        if (raw.length > Math.ceil((NOTE_IMAGE_MAX_BYTES * 4) / 3) + 16) {
          return fail("image_too_large");
        }
        let buf;
        try {
          buf = Buffer.from(raw, "base64");
        } catch (e) {
          return fail("bad_image");
        }
        if (!buf || !buf.length) return fail("empty_image");
        if (buf.length > NOTE_IMAGE_MAX_BYTES) return fail("image_too_large");
        const ext = noteImageExt(buf);
        if (!ext) return fail("bad_image");
        const usage = await noteUsage(me);
        if (usage.bytes + buf.length > NOTE_QUOTA_BYTES) {
          return fail("storage_quota");
        }
        const stamp = Date.now();
        const cloudPath =
          "tradeNotes/" +
          me +
          "/" +
          stamp +
          "_" +
          crypto.randomBytes(6).toString("hex") +
          "." +
          ext;
        const up = await app.uploadFile({ cloudPath, fileContent: buf });
        const fileId = (up && up.fileID) || "";
        if (!fileId) return fail("upload_failed");
        return ok({ fileId, size: buf.length });
      }

      if (action === "tradeReset") {
        if (rateLimited("reset:" + me)) return fail("rate_limited");
        // 金额可自定义，默认仍是 10 万；成交记录、累计单数和胜率保留
        let amount = round(num(event.amount), 2);
        if (!Number.isFinite(amount) || amount < 100 || amount > 100000000) {
          amount = INITIAL_CASH;
        }
        await removeWhere(positions(), me);
        await removeWhere(orders(), me);
        await touchAccount(me, { cash: amount, baseCash: amount, lastPrice: 0 });
        return ok({ account: await snapshot(me) });
      }

      if (action === "tradeCancel") {
        const id = String(event.orderId || "");
        if (!id) return fail("bad_request");
        const { data } = await orders().doc(id).get();
        const o = data && data[0];
        if (!o || o.uid !== me) return fail("not_found");
        await orders().doc(id).remove();
        return ok({ account: await snapshot(me) });
      }

      if (action === "tradeClose") {
        const price = roundPrice(num(event.price));
        const bad = await checkPrice(me, price);
        if (bad) return fail(bad);
        const id = String(event.positionId || "");
        if (!id) return fail("bad_request");
        const { data } = await positions().doc(id).get();
        const p = data && data[0];
        if (!p || p.uid !== me) return fail("not_found");
        if (rateLimited("close:" + me)) return fail("rate_limited");
        const pct = Math.min(1, Math.max(0.01, num(event.pct) || 1));
        await closePosition(me, p, price, false, pct);
        return ok({ account: await snapshot(me) });
      }

      if (action === "tradeSync") {
        const price = num(event.price);
        const bad = await checkPrice(me, price);
        if (bad) return fail(bad);
        const changed = await matchOrders(me, price);
        return ok({ account: await snapshot(me), matched: changed });
      }

      if (action === "tradePlace") {
        const price = num(event.price);
        if (event.kind === "market") {
          const bad = await checkPrice(me, price);
          if (bad) return fail(bad);
        }
        return await openPosition(me, event, price);
      }

      return fail(`unknown action: ${action}`);
    } catch (e) {
      console.error("[trade] error:", e && e.stack ? e.stack : e);
      return fail(e && e.message ? e.message : "trade_error");
    }
  };
};
