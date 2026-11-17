/* =============================================================================
 * BTC 行情 · 模拟交易（纯前端）
 *
 * 数据源：Binance 公开行情接口，不需要 API Key。
 *   REST：data-api.binance.vision 优先，api.binance.com / api1~4 作备份。
 *   WS  ：data-stream.binance.vision 优先，stream.binance.com 的两个端口作备份。
 *         （实测国内网络 api.binance.com、stream.binance.com 握手直接超时，
 *           .vision 这两个域正常，所以顺序别改回去。）
 *
 * 断线策略（本文件最容易被改坏的部分，动之前先看 docs/BTC行情页稳定性优化.md）：
 *   1. 握手 5 秒没成、或连着但 12 秒没收到任何帧（假死），都立刻踢掉重连；
 *   2. 重连退避 0.8s→8s 带抖动，不再出现「等 60 秒」的黑屏；
 *   3. WS 不通就降级成轻量轮询（行情 4 秒一次，K 线只取最新 3 根）；
 *   4. 重连、回到前台、发现断档时，用 REST 把最近的 K 线补回来，图上不留洞。
 * 撤源、重连、补数据都在这里闭环，页面只关心「有没有价」。
 *
 * 图表：Lightweight Charts（本地打包，见 assets/js/lightweight-charts.*）
 *
 * 账户：
 *   未登录 → localStorage 本机账户；
 *   登录后 → 云函数 trade* 系列动作，跨设备同步（见 cloudfunctions/api/trade.js）。
 *   两边共用同一套会计模型，所以 UI 逻辑完全一样。
 * ========================================================================== */
(function (global) {
  'use strict';

  // ---------------------------------------------------------------- 常量
  var SYMBOL = 'BTCUSDT';
  var LIMIT = 5000;
  var PAGE = 1000;
  var TF = ['1m', '3m', '5m', '15m', '30m', '1h', '2h', '4h', '6h', '8h', '10h', '12h', '1d', '3d', '5d', '1w', '1M'];
  var TF_LABEL = {
    '1m': '1 分钟', '3m': '3 分钟', '5m': '5 分钟', '15m': '15 分钟', '30m': '30 分钟',
    '1h': '1 小时', '2h': '2 小时', '4h': '4 小时', '6h': '6 小时', '8h': '8 小时',
    '10h': '10 小时', '12h': '12 小时', '1d': '1 天', '3d': '3 天', '5d': '5 天',
    '1w': '1 周', '1M': '1 月'
  };
  // 1M 用 28 天，只给「断档补齐」当阈值用，避免月末 31 天被误判成断档
  var TF_MS = {
    '1m': 60000, '3m': 180000, '5m': 300000, '15m': 900000, '30m': 1800000,
    '1h': 3600000, '2h': 7200000, '4h': 14400000, '6h': 21600000,
    '8h': 28800000, '10h': 36000000, '12h': 43200000,
    '1d': 86400000, '3d': 259200000, '5d': 432000000,
    '1w': 604800000, '1M': 2419200000
  };
  // 交易所没有 10h / 5d 这两个 interval，用 base 周期的 group 根合成：
  // 10h = 5 x 2h，5d = 5 x 1d（6h、3d Binance 原生就有）。
  var TF_SYNTH = {
    '10h': { iv: '2h', group: 5 },
    '5d': { iv: '1d', group: 5 }
  };
  // 图表右侧留白（根）。换周期还原视口时也按它算最右能到哪。
  var RIGHT_OFFSET = 6;

  var REST_HOSTS = [
    'https://data-api.binance.vision',
    'https://api.binance.com',
    'https://api1.binance.com',
    'https://api2.binance.com',
    'https://api3.binance.com',
    'https://api4.binance.com'
  ];
  var WS_HOSTS = [
    'wss://data-stream.binance.vision',
    'wss://stream.binance.com:9443',
    'wss://stream.binance.com:443'
  ];

  // 模拟盘不收手续费：费率为 0，开平仓、可用余额、最大可开量都不再扣费。
  var FEE = 0;
  // 单子盈亏统一放大 10 倍（保证金/名义价值不变）
  var PNL_MULT = 10;
  var INITIAL_CASH = 100000;
  var MIN_NOTIONAL = 10;
  var MAX_QTY = 1000;
  var MAX_HISTORY = 60;
  var POLL_MS = 4000;          // 降级轮询：行情条
  var KLINE_POLL_MS = 5000;    // 降级轮询：K 线（只取最新几根）
  // 对账间隔：没有限价单、强平只是兜底，5 秒一次纯属浪费云端调用。
  // 半天对一次账，成本约 12 点/月；想更省可改成 24 小时。
  var SYNC_MS = 12 * 60 * 60 * 1000;
  var RENDER_MS = 1000;        // 表格/盈亏重绘节流

  // 连接调优参数
  var REQ_MS = 8000;           // 单个 REST 请求超时
  var REQ_DEADLINE_MS = 15000; // 一次 restGet 的总时限
  var HEDGE_MS = 1400;         // 主源这么久没回就并行开下一个源
  var HOST_COOLDOWN_MS = 60000; // 刚失败的源先晾一分钟
  var WS_OPEN_MS = 5000;       // 单源握手超时
  var WS_STALL_MS = 12000;     // 这么久没收到任何帧 = 假死
  var WS_RETRY_MIN = 800;
  var WS_RETRY_MAX = 8000;
  // 握手就失败的源（境内被墙的 stream.binance.com）晾一分钟再试：
  // 以前每次断线都按顺序轮换，三次里两次撞墙，每次白等 WS_OPEN_MS，
  // 状态条就长时间停在「轮询模式 / 行情源不可用」。
  // 只晾一分钟：网络切好（开代理）后能很快回到可用源。
  var WS_COOLDOWN_MS = 60 * 1000;
  var HEAL_MIN_MS = 3000;      // 两次补数据的最小间隔

  var UP = '#7E1319';
  var DOWN = '#305C38';
  var UP_SOFT = 'rgba(126, 19, 25, 0.55)';
  var DOWN_SOFT = 'rgba(48, 92, 56, 0.55)';

  var LS = {
    token: 'huideng.trade.token',
    user: 'huideng.trade.user',
    guest: 'huideng.trade.guest',
    host: 'huideng.trade.host',
    ws: 'huideng.trade.ws'
  };

  var MSG = {
    unauthorized: '登录已过期，请重新登录',
    insufficient_balance: '可用余额不足',
    min_notional: '名义价值需 ≥ 10 USDT',
    bad_qty: '数量不合法',
    bad_price: '价格不合法',
    bad_amount: '重置金额不合法',
    price_deviation: '价格偏离过大，请稍后重试',
    rate_limited: '操作太频繁，请稍后再试',
    username_taken: '用户名已被占用',
    account_not_found: '账号不存在',
    wrong_password: '密码错误',
    no_password: '该账号还没设置密码，请先在燃灯 App 里设置',
    invalid_username: '账号需为 2-20 位中文、字母、数字或下划线',
    invalid_password: '密码需为 6-64 位',
    not_found: '记录不存在',
    bad_request: '请求参数不完整',
    network: '网络异常，请稍后重试',
    // 手机号相关
    invalid_phone: '手机号格式不对，请填 11 位大陆手机号',
    phone_taken: '这个手机号已经绑定到别的账号了',
    too_frequent: '刚发过，请 60 秒后再试',
    too_many: '今天发得太多了，明天再试',
    sms_failed: '短信发送失败，请稍后再试',
    code_expired: '验证码过期了，请重新获取',
    code_wrong: '验证码不对，请核对后重填',
    verify_failed: '验证码校验失败，请重新获取',
    phone_not_bound: '这个手机号还没绑定账号',
    bad_image: '图片格式不支持，请换 JPG / PNG',
    too_large: '图片太大，换一张再试'
  };

  var cfg = { api: '', key: '', rel: '' };
  var state = {
    iv: '1m', price: 0, ticker: null, bars: [], firstLoad: true, seq: 0,
    lastTick: 0, olderTimer: 0,
    // 换周期时暂存切换前的视口（时间区间），新周期数据到了再还原
    view: null,
    // 走势图当前看的币种（默认 BTC）；模拟交易只做 SYMBOL
    symbol: SYMBOL,
    // 走势图这一根/这一天的涨跌，用来给价格浮标上色（BTC 用行情 ticker，其他币单独拉）
    chartPct: 0,
    // 自选标的（本地保存）与折叠状态
    watch: null,
    watchOpen: true,
    // 各标的 24h 涨跌幅缓存：symbol -> { pct, t }
    pct: {}
  };
  var Account = { mode: 'guest', token: '', username: '', data: null };
  var avatarLoaded = false;
  // 未登录点头像菜单里的「交易笔记」：先弹登录，登录成功后直接跳过去。
  var pendingNotes = false;
  // 从交易页右下角「交易笔记」按钮进入：未登录先弹登录，登录后滑出子页面。
  var pendingNotesSlide = false;

  // ---------------------------------------------------------------- 工具
  function $(id) { return document.getElementById(id); }

  function pad(n) { return n < 10 ? '0' + n : '' + n; }

  function group(n, digits) {
    var neg = n < 0;
    var s = Math.abs(n).toFixed(digits);
    var parts = s.split('.');
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return (neg ? '-' : '') + parts.join('.');
  }

  function fmtPrice(n) { return Number.isFinite(+n) ? group(+n, 2) : '--'; }
  /**
   * 走势图价格的小数位：按当前价量级自动加，PEPE 这类低价币不会显示成 0.00。
   * 账户/下单相关的金额仍用 fmtPrice（BTC 两位小数）。
   */
  function chartDigits() {
    var b = state.bars[state.bars.length - 1];
    var a = Math.abs(b ? b.close : state.price);
    if (!Number.isFinite(a) || a <= 0) return 2;
    if (a >= 1000) return 2;
    if (a >= 1) return 4;
    if (a >= 0.1) return 5;
    if (a >= 0.01) return 6;
    if (a >= 0.0001) return 7;
    return 8;
  }
  function fmtAxis(n) { return Number.isFinite(+n) ? group(+n, chartDigits()) : '--'; }
  function fmtQty(n) {
    if (!Number.isFinite(+n)) return '--';
    var v = +n;
    if (v !== 0 && Math.abs(v) < 0.000001) return v.toExponential(2);
    return group(v, 6);
  }
  function fmtPct(n) {
    if (!Number.isFinite(+n)) return '--';
    return (+n > 0 ? '+' : '') + (+n).toFixed(2) + '%';
  }
  function fmtBig(n) {
    n = +n || 0;
    if (n >= 1e8) return (n / 1e8).toFixed(2) + ' 亿';
    if (n >= 1e4) return (n / 1e4).toFixed(2) + ' 万';
    return group(n, 0);
  }
  function fmtClock(ts) {
    var d = new Date(ts || Date.now());
    return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }
  function fmtDateTime(ts) {
    var d = new Date(ts || Date.now());
    return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }
  function round(n, d) { var f = Math.pow(10, d); return Math.round(n * f) / f; }
  function round6(n) { return round(n, 6); }
  function round2(n) { return round(n, 2); }

  function uid() {
    return 'x' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }

  function err(code) { var e = new Error(code); e.code = code; return e; }

  function msgOf(code) {
    if (!code) return '操作失败，请重试';
    return MSG[code] || (String(code).indexOf('HTTP') === 0 ? '服务暂时不可用（' + code + '）' : code);
  }

  function readLS(key) {
    try { return localStorage.getItem(key); } catch (e) { return null; }
  }
  function writeLS(key, val) {
    try { localStorage.setItem(key, val); } catch (e) {}
  }
  function dropLS(key) {
    try { localStorage.removeItem(key); } catch (e) {}
  }

  var toastTimer = null;
  function toast(text) {
    var t = $('toast');
    if (!t) return;
    t.textContent = text;
    t.classList.add('is-on');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.classList.remove('is-on'); }, 2600);
  }

  // ---------------------------------------------------------------- 网络
  // 以前是「一次把 6 个源全打出去」，被墙的源每个要挂 9 秒才超时，
  // 手机上一次轮询就挂着十几个死连接，越刷越卡、越卡越像掉线。
  // 现在只先打上次成功的源，1.4 秒不回才并开下一个，成功即 abort 其余。
  var hostDown = {};

  function fetchJSON(url, ms, ctl) {
    if (!ctl && typeof AbortController !== 'undefined') ctl = new AbortController();
    var timer = setTimeout(function () { if (ctl) { try { ctl.abort(); } catch (e) {} } }, ms || REQ_MS);
    return fetch(url, ctl ? { signal: ctl.signal } : undefined).then(function (res) {
      clearTimeout(timer);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.json();
    }, function (e) {
      clearTimeout(timer);
      throw e;
    });
  }

  function cachedHost() {
    try {
      var v = readLS(LS.host);
      return v && REST_HOSTS.indexOf(v) >= 0 ? v : '';
    } catch (e) { return ''; }
  }

  /** 可用源顺序：上次成功的排第一，刚失败的进冷却，全部冷却时重置。 */
  function hostOrder() {
    var good = cachedHost();
    var now = Date.now();
    var out = [];
    REST_HOSTS.forEach(function (h) {
      if (h === good) return;
      if (hostDown[h] && hostDown[h] > now) return;
      out.push(h);
    });
    if (good && !(hostDown[good] && hostDown[good] > now)) out.unshift(good);
    if (!out.length) out = REST_HOSTS.slice();
    return out;
  }

  /** GET <path>：顺序尝试 + 延迟并行（hedging），拿到第一个成功就收工。 */
  function restGet(path) {
    var hosts = hostOrder();
    return new Promise(function (resolve, reject) {
      var settled = false;
      var inflight = [];
      var hedge = null;
      var deadline = null;
      var i = 0;

      function cleanup() {
        if (hedge) { clearTimeout(hedge); hedge = null; }
        if (deadline) { clearTimeout(deadline); deadline = null; }
        inflight.forEach(function (rec) {
          if (rec.ctl) { try { rec.ctl.abort(); } catch (e) {} }
        });
        inflight = [];
      }

      function fail(e) {
        if (settled) return;
        settled = true;
        cleanup();
        reject(e || new Error('all hosts failed'));
      }

      function win(host, data) {
        if (settled) return;
        settled = true;
        cleanup();
        hostDown[host] = 0;
        if (readLS(LS.host) !== host) writeLS(LS.host, host);
        resolve(data);
      }

      function next() {
        if (settled) return;
        if (hedge) { clearTimeout(hedge); hedge = null; }
        if (i >= hosts.length) {
          if (!inflight.length) fail();
          return;
        }

        var host = hosts[i++];
        var ctl = typeof AbortController !== 'undefined' ? new AbortController() : null;
        var rec = { host: host, ctl: ctl };
        inflight.push(rec);

        fetchJSON(host + path, REQ_MS, ctl).then(function (data) {
          inflight = inflight.filter(function (x) { return x !== rec; });
          win(host, data);
        }, function (e) {
          inflight = inflight.filter(function (x) { return x !== rec; });
          if (settled) return;
          hostDown[host] = Date.now() + HOST_COOLDOWN_MS;
          // 这个源挂了就立刻换下一个，别干等 hedge 定时器
          if (i >= hosts.length && !inflight.length) fail(e);
          else next();
        });

        if (i < hosts.length) hedge = setTimeout(next, HEDGE_MS);
      }

      deadline = setTimeout(function () { fail(new Error('timeout')); }, REQ_DEADLINE_MS);
      next();
    });
  }

  function klinePath(iv, limit, endTime) {
    var path = '/api/v3/klines?symbol=' + state.symbol + '&interval=' + iv + '&limit=' + (limit || LIMIT);
    if (endTime) path += '&endTime=' + Math.round(endTime);
    return path;
  }
  function tickerPath() {
    return '/api/v3/ticker/24hr?symbol=' + SYMBOL;
  }

  /** 合成周期的历史深度小一些：一次 1000 根要拉 group 倍的 base K 线。 */
  function limitOf(iv) {
    return TF_SYNTH[iv] ? 2000 : LIMIT;
  }

  /**
   * 把 base 周期的原始 K 线压成 bucketSec 一根（10h / 5d 这类交易所没有的周期）。
   * 时间取 bucket 起点；最早那根如果缺了 bucket 前半段就丢掉，等更早的一页
   * 从 bucket 起点往回拉，避免留一根开高低收都不对的历史 K 线。
   */
  function aggregateKlines(rows, bucketSec) {
    var list = (rows || []).slice().sort(function (a, b) { return +a[0] - +b[0]; });
    var out = [];
    var cur = null;
    var firstT = null;
    var prevT = null;
    for (var i = 0; i < list.length; i += 1) {
      var r = list[i];
      var tSec = Math.floor(+r[0] / 1000);
      // 分页边界可能带回重复的一根，跳过，否则成交量会重复累加
      if (tSec === prevT) continue;
      var t = Math.floor(tSec / bucketSec) * bucketSec;
      var close = +r[4];
      if (!Number.isFinite(t) || !Number.isFinite(close)) continue;
      prevT = tSec;
      if (firstT == null) firstT = tSec;
      if (!cur || cur[0] !== t * 1000) {
        cur = [t * 1000, r[1], r[2], r[3], r[4], r[5]];
        out.push(cur);
      } else {
        cur[2] = Math.max(+cur[2], +r[2]);
        cur[3] = Math.min(+cur[3], +r[3]);
        cur[4] = r[4];
        cur[5] = String(+cur[5] + +r[5]);
      }
    }
    if (out.length && firstT != null && firstT > out[0][0] / 1000) out.shift();
    return out;
  }

  /**
   * 统一的 K 线取数：原生周期直接拉；合成周期先拉一页，再按这页最早一根的时间
   * 并行拉前面的页，合并成目标周期。endTime 是毫秒，和 klinePath 一致。
   */
  function fetchKlines(iv, limit, endTime) {
    var spec = TF_SYNTH[iv];
    if (!spec) return restGet(klinePath(iv, limit, endTime));
    var baseStep = TF_MS[spec.iv] || 60000;
    var want = limit * spec.group;
    var firstLimit = Math.min(1000, want);
    return restGet(klinePath(spec.iv, firstLimit, endTime)).then(function (first) {
      first = first || [];
      var pages = [first];
      var rest = want - firstLimit;
      if (rest <= 0 || !first.length) return pages;
      var oldest = +first[0][0];
      var more = [];
      for (var k = 0; k * 1000 < rest; k += 1) {
        var take = Math.min(1000, rest - k * 1000);
        var end = oldest - 1 - k * 1000 * baseStep;
        more.push(restGet(klinePath(spec.iv, take, end)));
      }
      return Promise.all(more).then(function (extra) {
        return pages.concat(extra);
      });
    }).then(function (pages) {
      var rows = [];
      pages.forEach(function (page) { rows = rows.concat(page || []); });
      return aggregateKlines(rows, (TF_MS[iv] || 60000) / 1000);
    });
  }

  function mapKlines(rows) {
    return (rows || []).map(function (k) {
      return {
        time: Math.floor(k[0] / 1000),
        open: +k[1],
        high: +k[2],
        low: +k[3],
        close: +k[4],
        volume: +k[5]
      };
    }).filter(function (b) { return Number.isFinite(b.time) && Number.isFinite(b.close); });
  }

  // ---------------------------------------------------------------- 行情状态
  // 右下角那个小悬浮条只放一行：状态点 + 短状态词（+ 旁边的 24h 成交额）。
  // 完整说法（含数据源主机）挂在 title 上，鼠标悬停能看，不占版面。
  function setSource(kind, text) {
    var dot = $('srcDot');
    var el = $('srcText');
    if (!dot || !el) return;
    dot.className = 'tick__dot' + (kind === 'live' ? ' is-live' : kind === 'lag' ? ' is-lag' : ' is-down');
    var short = String(text == null ? '' : text).split(' · ')[0];
    el.textContent = short;
    el.title = text;
  }

  function hostLabel(host) {
    try { return host.replace(/^wss?:\/\//, '').split('/')[0]; } catch (e) { return host; }
  }

  /** 行情状态文案，跟着 WS / 轮询状态走（右下角悬浮条只显示前段短词）。 */
  function sourceText() {
    if (!state.lastTick) return;
    if (WS.opened) setSource('live', '实时 · ' + hostLabel(WS.host || WS_HOSTS[0]));
    else if (pollTimer) setSource('lag', '轮询模式 · 每 ' + (POLL_MS / 1000) + ' 秒刷新');
    else setSource('lag', '重连中');
  }

  function applyTicker(o) {
    var price = +(o.lastPrice != null ? o.lastPrice : o.c);
    var pct = +(o.priceChangePercent != null ? o.priceChangePercent : o.P);
    var high = +(o.highPrice != null ? o.highPrice : o.h);
    var low = +(o.lowPrice != null ? o.lowPrice : o.l);
    var vol = +(o.quoteVolume != null ? o.quoteVolume : o.q);
    if (!Number.isFinite(price) || price <= 0) return;

    state.price = price;
    state.lastTick = Date.now();
    state.ticker = { price: price, pct: pct, high: high, low: low, vol: vol };
    // BTC 的涨跌也用在 BTC 走势图的浮标上；看别的币时浮标用那个币自己的涨跌
    if (state.symbol === SYMBOL) state.chartPct = pct;

    var eP = $('lastPrice');
    var eC = $('chg24');
    if (eP) eP.textContent = fmtPrice(price);
    if (eC) {
      eC.textContent = fmtPct(pct);
      eC.className = 'tick__chg ' + (pct >= 0 ? 'is-up' : 'is-down');
    }
    if ($('high24')) $('high24').textContent = fmtPrice(high);
    if ($('low24')) $('low24').textContent = fmtPrice(low);
    if ($('vol24')) $('vol24').textContent = fmtBig(vol) + ' USDT';
    if ($('updatedAt')) $('updatedAt').textContent = '更新于 ' + fmtClock(state.lastTick);

    maybeSync(price);
    scheduleRender();
    updatePriceTag();
    sourceText(); // 首帧到达时把「正在连接」换成实时/轮询，别等下一次重连
  }

  // 行情推送比界面重绘快（WS 每秒一跳），表格又是整段重建，
  // 直接跟着画会闪。这里收拢成 1 秒一次。
  var renderTimer = 0;
  function scheduleRender() {
    if (renderTimer) return;
    renderTimer = setTimeout(function () {
      renderTimer = 0;
      if (document.hidden) return;
      renderAcct();
      renderTables();
      renderSummary();
      renderEst();
      renderPosCalc();
    }, RENDER_MS);
  }

  /** 每秒刷新「更新于 / X 秒前」，行情停了要一眼看得出来。 */
  var clockTick = 0;
  function startClock() {
    setInterval(function () {
      clockTick += 1;
      // 自选开着时：价格文字每秒对一次（BTC 走实时 ticker），
      // 其余币种每 12 秒强制拉一次最新价和 24h 涨跌。
      if (state.watchOpen && state.watch.length) {
        refreshWatchPrices();
        if (clockTick % 12 === 0) loadPct(state.watch, true);
      }
      var el = $('updatedAt');
      if (!state.lastTick) {
        if (el) el.textContent = '等待行情…';
        return;
      }
      var ago = Math.floor((Date.now() - state.lastTick) / 1000);
      if (el) {
        el.textContent = ago < 3
          ? '更新于 ' + fmtClock(state.lastTick)
          : '更新于 ' + fmtClock(state.lastTick) + ' · 延迟 ' + ago + ' 秒';
      }
      var p = $('lastPrice');
      if (p) {
        if (ago >= 8) p.classList.add('is-stale');
        else p.classList.remove('is-stale');
      }
      if (ago >= WS_STALL_MS / 1000 && WS.opened) {
        // 看门狗最多 4 秒后就会踢掉重连，这里先把状态标出来，别让人以为还在实时
        setSource('lag', '行情延迟，正在重连…');
      }
    }, 1000);
  }

  function byTime(a, b) { return a.time - b.time; }

  /**
   * rows 可能是「整段历史」（replace=true 或首次加载），
   * 也可能是最新的一两根（WS 推送 / 降级轮询）。
   * 单根走 update 快路径，多根才合并重排，避免每秒重建 1000 根数组。
   */
  function applyKlines(rows, replace) {
    var bars = mapKlines(rows);
    if (!bars.length) return;
    bars.sort(byTime);

    if (replace || !state.bars.length) {
      state.bars = bars.slice(-limitOf(state.iv));
      chartSet(state.bars);
      // 首次加载铺满全图；换周期则回到切换前的视口（见 settleView）
      settleView();
      hideMsg();
      refreshLegend();
      return;
    }

    var step = (TF_MS[state.iv] || 60000) / 1000;
    var last = state.bars[state.bars.length - 1];
    var fresh = bars.filter(function (b) { return b.time >= last.time; });
    if (!fresh.length) return; // 换周期瞬间旧流的尾巴，直接丢

    // 断档：掉线期间漏掉的 K 线 WS 不会补，用 REST 补一段回来
    if (fresh[0].time - last.time > step) healBars(true);

    if (fresh.length === 1) {
      updateTail(fresh[0]);
      hideMsg();
      refreshLegend();
      return;
    }

    mergeBars(fresh);
    hideMsg();
    refreshLegend();
  }

  function updateTail(b) {
    var tail = state.bars[state.bars.length - 1];
    if (b.time === tail.time) {
      state.bars[state.bars.length - 1] = b;
      chartUpdate(b);
    } else if (b.time > tail.time) {
      state.bars.push(b);
      if (state.bars.length > limitOf(state.iv)) state.bars.shift();
      chartUpdate(b);
    }
  }

  /** 把一批（可能和现有数据重叠的）K 线并进来；能顺接就只 update，不然整段重画。 */
  function mergeBars(fresh) {
    if (!fresh.length) return;
    var step = (TF_MS[state.iv] || 60000) / 1000;
    var last = state.bars[state.bars.length - 1];
    var contiguous = fresh[0].time >= last.time && fresh[0].time - last.time <= step;
    var i;
    for (i = 1; contiguous && i < fresh.length; i++) {
      if (fresh[i].time - fresh[i - 1].time > step) contiguous = false;
    }
    if (contiguous) {
      fresh.forEach(updateTail);
      return;
    }

    var map = {};
    state.bars.forEach(function (b) { map[b.time] = b; });
    fresh.forEach(function (b) { map[b.time] = b; });
    state.bars = Object.keys(map).map(function (k) { return map[k]; }).sort(byTime).slice(-limitOf(state.iv));
    chartSet(state.bars);
    settleView();
  }

  // 补数据：掉线重连 / 回到前台 / 发现断档时调用。
  // 只取最近一段（普通 60 根、断档 300 根），比整段 1000 根轻得多。
  var heal = { timer: 0, at: 0, busy: false, full: false };

  function healBars(full) {
    if (full) heal.full = true;
    if (heal.busy) return;
    if (heal.timer) {
      if (!heal.full) return;
      clearTimeout(heal.timer);
      heal.timer = 0;
    }
    heal.timer = setTimeout(runHeal, Math.max(0, HEAL_MIN_MS - (Date.now() - heal.at)));
  }

  function runHeal() {
    heal.timer = 0;
    heal.busy = true;
    heal.at = Date.now();
    var full = heal.full;
    heal.full = false;
    var iv = state.iv;
    fetchKlines(iv, full ? 300 : 60).then(function (rows) {
      if (iv !== state.iv) return;
      var bars = mapKlines(rows);
      if (!bars.length) return;
      if (!state.bars.length) {
        applyKlines(rows, true);
        return;
      }
      mergeBars(bars.sort(byTime));
      hideMsg();
      refreshLegend();
    }).catch(function () {}).then(function () { heal.busy = false; });
  }

  /** 拉最近一页历史（首次加载、切周期），seq 变了就丢弃结果。 */
  function loadBars(iv, seq) {
    if (state.olderTimer) {
      clearTimeout(state.olderTimer);
      state.olderTimer = 0;
    }
    return fetchKlines(iv, PAGE).then(function (rows) {
      if (iv !== state.iv || seq !== state.seq) return;
      var bars = mapKlines(rows);
      if (!bars.length) return;
      state.bars = bars.sort(byTime).slice(-limitOf(iv));
      chartSet(state.bars);
      hideMsg();
      refreshLegend();
      // 换周期后回到切换前的视口；首次加载才铺满全图
      settleView();
      // 先把最近 1000 根显示出来，再在后台一页页补更早的历史；
      // 补数据时保持当前视口不动，图上不会突然跳。
      if (state.bars.length >= PAGE && state.bars.length < limitOf(iv)) {
        state.olderTimer = setTimeout(function () {
          state.olderTimer = 0;
          loadOlderBars(iv, seq);
        }, 700);
      }
    });
  }

  /** 继续往左补更早的 K 线，直到 limitOf 根或交易所没有更早数据。 */
  function loadOlderBars(iv, seq) {
    if (iv !== state.iv || seq !== state.seq) return;
    if (!state.bars.length || state.bars.length >= limitOf(iv)) return;
    var oldest = state.bars[0].time;
    fetchKlines(iv, PAGE, oldest * 1000 - 1).then(function (rows) {
      if (iv !== state.iv || seq !== state.seq) return;
      var older = mapKlines(rows).filter(function (b) { return b.time < oldest; });
      if (!older.length) return;
      var oldLen = state.bars.length;
      var map = {};
      older.concat(state.bars).forEach(function (b) { map[b.time] = b; });
      state.bars = Object.keys(map).map(function (k) { return map[k]; }).sort(byTime).slice(-limitOf(iv));
      var shift = state.bars.length - oldLen;
      var range = Chart.chart && Chart.chart.timeScale
        ? Chart.chart.timeScale().getVisibleLogicalRange()
        : null;
      chartSet(state.bars);
      if (range && shift > 0 && Chart.chart) {
        try {
          Chart.chart.timeScale().setVisibleLogicalRange({
            from: range.from + shift,
            to: range.to + shift
          });
        } catch (e) {}
      }
      hideMsg();
      refreshLegend();
      if (state.bars.length < limitOf(iv)) {
        state.olderTimer = setTimeout(function () {
          state.olderTimer = 0;
          loadOlderBars(iv, seq);
        }, 250);
      }
    }).catch(function () {
      // 更早的历史拉不到不影响当前行情
    });
  }

  // ---------------------------------------------------------------- WebSocket
  var WS = {
    sock: null, host: '', fails: 0, opened: false,
    retry: null, guard: null, ping: null, lastMsg: 0
  };
  // 握手阶段就失败的源 → 冷却到期时间（见 wsFail）
  var wsDown = {};

  function wsHost() {
    var now = Date.now();
    var last = '';
    try { last = readLS(LS.ws) || ''; } catch (e) {}
    // 上次连通的源优先；它刚失败过就跳过，按顺序取第一个没进冷却的。
    if (last && WS_HOSTS.indexOf(last) >= 0 && !(wsDown[last] > now)) return last;
    for (var i = 0; i < WS_HOSTS.length; i += 1) {
      if (!(wsDown[WS_HOSTS[i]] > now)) return WS_HOSTS[i];
    }
    return WS_HOSTS[0];
  }

  function wsUrl(iv) {
    var s = state.symbol.toLowerCase();
    // ticker 始终订阅 BTC（模拟盘按 BTC 结算），K 线流跟着走势图币种走；
    // 合成周期（10h / 5d）没有对应的 kline 流，只订阅 ticker，K 线走 REST 轮询
    var streams = 'btcusdt@ticker';
    if (!TF_SYNTH[iv]) streams += '/' + s + '@kline_' + iv;
    return wsHost() + '/stream?streams=' + streams;
  }

  function wsConnect() {
    if (document.hidden) return; // 后台不连，回前台由 visibilitychange 拉起
    if (WS.retry) { clearTimeout(WS.retry); WS.retry = null; }
    wsAbort();

    var url;
    try { url = wsUrl(state.iv); } catch (e) { wsFail(false); return; }
    var ws;
    try { ws = new WebSocket(url); } catch (e) { wsFail(false); return; }

    WS.sock = ws;
    WS.opened = false;
    WS.host = wsHost();
    WS.lastMsg = Date.now();

    // 握手超时：被墙的源经常既不通也不报错，只能自己掐掉换下一个
    WS.guard = setTimeout(function () {
      if (WS.sock !== ws || WS.opened) return;
      wsAbort();
      wsFail(false);
    }, WS_OPEN_MS);

    ws.onopen = function () {
      if (WS.sock !== ws) return;
      WS.opened = true;
      WS.fails = 0;
      WS.lastMsg = Date.now();
      if (WS.guard) { clearTimeout(WS.guard); WS.guard = null; }
      writeLS(LS.ws, WS.host);
      stopPoll();
      startSynthPoll();
      sourceText();
      startPing();
      healBars(); // 断线期间漏的 K 线补回来，图上不留洞
    };

    ws.onmessage = function (e) {
      WS.lastMsg = Date.now();
      var msg;
      try { msg = JSON.parse(e.data); } catch (err) { return; }
      if (msg && msg.result !== undefined) return; // pong
      var data = msg && msg.data ? msg.data : msg;
      if (!data) return;
      if (data.e === '24hrTicker') {
        applyTicker(data);
      } else if (data.e === 'kline' && data.k) {
        var k = data.k;
        if (k.i !== state.iv) return;
        applyKlines([[k.t, k.o, k.h, k.l, k.c, k.v]], false);
      }
    };

    ws.onerror = function () {};

    ws.onclose = function () {
      if (WS.sock !== ws) return;
      var wasOpen = WS.opened;
      WS.sock = null;
      WS.opened = false;
      if (WS.guard) { clearTimeout(WS.guard); WS.guard = null; }
      stopPing();
      wsFail(wasOpen);
    };
  }

  function wsAbort() {
    var ws = WS.sock;
    WS.sock = null;
    WS.opened = false;
    if (WS.guard) { clearTimeout(WS.guard); WS.guard = null; }
    if (ws) {
      ws.onopen = null;
      ws.onmessage = null;
      ws.onclose = null;
      ws.onerror = null;
      try { ws.close(); } catch (e) {}
    }
    stopPing();
  }

  /** 失败后换源重连：0.8s→8s 退避 + 抖动，期间轻量轮询保着行情。
   *  wasOpen=false 表示这次根本没握手成功（多半是被墙/域名不可达），
   *  把该源晾 WS_COOLDOWN_MS，下次直接跳过，不再每次都白等握手超时。 */
  function wsFail(wasOpen) {
    WS.fails += 1;
    WS.opened = false;
    if (!wasOpen && WS.host) wsDown[WS.host] = Date.now() + WS_COOLDOWN_MS;
    startPoll();
    sourceText();
    var wait = Math.min(WS_RETRY_MAX, WS_RETRY_MIN * Math.pow(2, Math.min(WS.fails - 1, 4)));
    wait = Math.round(wait * (0.75 + Math.random() * 0.5));
    if (WS.retry) clearTimeout(WS.retry);
    WS.retry = setTimeout(function () { WS.retry = null; wsConnect(); }, wait);
  }

  function startPing() {
    stopPing();
    WS.ping = setInterval(function () {
      var ws = WS.sock;
      if (ws && ws.readyState === 1) {
        try { ws.send(JSON.stringify({ method: 'PING', id: 1 })); } catch (e) {}
      }
    }, 45000);
  }

  function stopPing() {
    if (WS.ping) { clearInterval(WS.ping); WS.ping = null; }
  }

  // 假死检测：被路由器 / 运营商中间设备掐断的半开连接不会触发 onclose，
  // 只会「连着但再也不来数据」。以前页面就这么一直显示实时价，其实早就停了。
  function startWatchdog() {
    setInterval(function () {
      var ws = WS.sock;
      if (!ws || ws.readyState !== 1) return;
      if (Date.now() - WS.lastMsg < WS_STALL_MS) return;
      wsAbort();
      wsFail(true); // 是「连着但不来数据」，不是源不可达，不进冷却
    }, 4000);
  }

  // ---------------------------------------------------------------- 降级轮询
  // WS 不通时保底：行情条 4 秒、K 线 5 秒。
  // K 线只取最新 3 根（约 1 KB）；以前每次拉 1000 根（150 KB+）、4 秒一次，
  // 移动网络会被页面自己打满，越刷越卡，看着就像行情断了。
  var pollTimer = null;
  var klinePollTimer = null;

  function startPoll() {
    if (document.hidden) return;
    if (!pollTimer) {
      pollTimer = setInterval(pollTicker, POLL_MS);
      pollTicker();
    }
    if (!klinePollTimer) {
      klinePollTimer = setInterval(pollKlines, KLINE_POLL_MS);
      pollKlines();
    }
    stopSynthPoll(); // 降级轮询已经包含合成周期的 K 线，别重复跑
    sourceText();
  }

  function stopPoll() {
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    if (klinePollTimer) { clearInterval(klinePollTimer); klinePollTimer = null; }
  }

  function pollTicker() {
    restGet(tickerPath()).then(applyTicker).catch(function () {
      if (!state.lastTick || Date.now() - state.lastTick > WS_STALL_MS) {
        setSource('down', '行情源不可用，正在重试…');
      }
    });
  }

  function pollKlines() {
    var iv = state.iv;
    fetchKlines(iv, state.bars.length ? 3 : PAGE).then(function (rows) {
      if (iv !== state.iv) return;
      applyKlines(rows, !state.bars.length);
    }).catch(function () {});
  }

  // 合成周期（10h / 5d）没有 kline 流：WS 正常时也每 5 秒拉一小段 base K 线回来
  // 合并，最后一根蜡烛跟得上；WS 断了走 startPoll 里的 pollKlines，不重复跑。
  var synthTimer = null;

  function startSynthPoll() {
    stopSynthPoll();
    if (document.hidden || !TF_SYNTH[state.iv]) return;
    synthTimer = setInterval(function () {
      var iv = state.iv;
      var seq = state.seq;
      if (document.hidden || !TF_SYNTH[iv]) return;
      fetchKlines(iv, 3).then(function (rows) {
        if (iv !== state.iv || seq !== state.seq) return;
        applyKlines(rows, !state.bars.length);
      }).catch(function () {});
    }, KLINE_POLL_MS);
  }

  function stopSynthPoll() {
    if (synthTimer) { clearInterval(synthTimer); synthTimer = null; }
  }

  // ---------------------------------------------------------------- 币种搜索 / 切换
  // 走势图可以看任意币安现货 USDT 交易对的 K 线；模拟盘仍然只做 BTCUSDT。
  // 切到别的币时价格浮标、OHLC 图例、均线/MACD 都跟着换，账户与下单仍是 BTC。
  var HOT_SYMBOLS = [
    'BTCUSDT', 'ETHUSDT', 'BNBUSDT', 'SOLUSDT', 'XRPUSDT', 'DOGEUSDT', 'ADAUSDT',
    'AVAXUSDT', 'LINKUSDT', 'LTCUSDT', 'TRXUSDT', 'DOTUSDT', 'NEARUSDT', 'SUIUSDT',
    'APTUSDT', 'ARBUSDT', 'OPUSDT', 'PEPEUSDT', 'SHIBUSDT', 'TONUSDT'
  ];
  // 常见币的中文名，方便搜「以太坊」「狗狗币」
  var SYM_NAMES = {
    BTC: '比特币', ETH: '以太坊', BNB: '币安币', SOL: 'Solana', XRP: '瑞波',
    DOGE: '狗狗币', ADA: '艾达币', AVAX: '雪崩', LINK: 'Chainlink', LTC: '莱特币',
    TRX: '波场', DOT: '波卡', NEAR: 'Near', SUI: 'Sui', APT: 'Aptos',
    ARB: 'Arbitrum', OP: 'Optimism', PEPE: 'Pepe', SHIB: '柴犬', TON: 'Toncoin',
    BCH: '比特现金', ETC: '以太经典', FIL: 'Filecoin', ATOM: 'Cosmos', UNI: 'Uniswap',
    POL: 'Polygon', MATIC: 'Polygon', AAVE: 'Aave', INJ: 'Injective', TIA: 'Celestia'
  };
  // 常见币的英文别名，方便搜 ethereum / dogecoin 这种全名
  var SYM_ALIAS = {
    BTC: 'bitcoin', ETH: 'ethereum', BNB: 'bnb', SOL: 'solana', XRP: 'ripple',
    DOGE: 'dogecoin', ADA: 'cardano', AVAX: 'avalanche', LINK: 'chainlink', LTC: 'litecoin',
    TRX: 'tron', DOT: 'polkadot', NEAR: 'near', SUI: 'sui', APT: 'aptos',
    ARB: 'arbitrum', OP: 'optimism', PEPE: 'pepe', SHIB: 'shiba inu', TON: 'toncoin',
    BCH: 'bitcoin cash', ETC: 'ethereum classic', FIL: 'filecoin', ATOM: 'cosmos',
    UNI: 'uniswap', POL: 'polygon', MATIC: 'polygon', AAVE: 'aave', INJ: 'injective'
  };
  var LS_SYM = 'huideng.trade.syms';
  var symState = { list: null, loading: false, open: false };

  function isTradingSymbol() { return state.symbol === SYMBOL; }

  function cachedSymbols() {
    try {
      var o = JSON.parse(readLS(LS_SYM) || 'null');
      if (o && o.list && o.list.length && o.list.indexOf('BTCUSDT') >= 0 &&
        o.t && Date.now() - o.t < 24 * 3600 * 1000) return o.list;
    } catch (e) {}
    return null;
  }

  /** 拉一次全量交易对（约 160 KB），只留 USDT 现货；本地缓存 24 小时。 */
  function loadSymbols(done) {
    if (symState.list) { done(); return; }
    var cached = cachedSymbols();
    if (cached) { symState.list = cached; done(); return; }
    if (symState.loading) return;
    symState.loading = true;
    restGet('/api/v3/ticker/price').then(function (rows) {
      var list = (rows || []).filter(function (r) {
        // base 只要 2 位以上：BTC/ETH 这种三位代码不能漏（之前写成 4 位，BTC 自己搜不到）
        return r && typeof r.symbol === 'string' && /^[A-Z0-9]{2,}USDT$/.test(r.symbol);
      }).map(function (r) { return r.symbol; }).sort();
      if (list.length) {
        symState.list = list;
        writeLS(LS_SYM, JSON.stringify({ t: Date.now(), list: list }));
      }
    }).catch(function () {}).then(function () {
      symState.loading = false;
      done();
    });
  }

  /** 搜索：精确代码 > 前缀 > 中文名 / 包含。 */
  function matchSymbols(list, q) {
    q = String(q || '').trim().toUpperCase();
    if (!q) {
      var hot = HOT_SYMBOLS.filter(function (s) { return list === HOT_SYMBOLS || list.indexOf(s) >= 0; });
      return hot.slice(0, 12);
    }
    var seen = {};
    var exact = [];
    var starts = [];
    var other = [];
    function push(arr, sym) {
      if (seen[sym]) return;
      seen[sym] = 1;
      arr.push(sym);
    }
    list.forEach(function (sym) {
      var base = sym.slice(0, -4);
      var name = (SYM_NAMES[base] || '') + ' ' + (SYM_ALIAS[base] || '');
      if (base === q || sym === q) push(exact, sym);
      else if (base.indexOf(q) === 0) push(starts, sym);
      else if (name.toUpperCase().indexOf(q) >= 0 || sym.indexOf(q) >= 0) push(other, sym);
    });
    return exact.concat(starts, other).slice(0, 20);
  }

  /** 走势图换币种后的界面：图例币种、价格浮标、自选高亮；非 BTC 时开仓 / 平仓按钮置灰。 */
  function setSymbolUI() {
    var cs = $('chartSym');
    if (cs) cs.textContent = state.symbol;
    updateOrderUI();
    updatePriceTag();
    renderWatch();
    drawSchedule();
  }

  /** 图例旁边的「重置」：回到 BTCUSDT 的 1 分钟走势。 */
  /** 图例旁边的「重置」：当前周期的走势恢复默认（撤销右侧压扁/拉伸，视图铺满）。 */
  function resetChart() {
    if (!Chart.ready || !Chart.chart) return;
    // 价格轴恢复自动缩放：右侧上下拖拽造成的压扁/拉伸回到默认
    try {
      if (Chart.candle && Chart.candle.priceScale) {
        Chart.candle.priceScale().applyOptions({ autoScale: true });
      }
      if (Chart.chart.priceScale) {
        Chart.chart.priceScale('right').applyOptions({ autoScale: true });
      }
    } catch (e) {}
    // 副图的压扁也一起恢复
    try {
      if (Chart.hist && Chart.hist.priceScale) {
        Chart.hist.priceScale().applyOptions({ autoScale: true });
      }
      if (Chart.macd && Chart.macd.priceScale) {
        Chart.macd.priceScale('right').applyOptions({ autoScale: true });
      }
    } catch (e) {}
    // 时间轴保持当前视图，只把价格轴恢复到自动缩放
    state.view = null;
    state.firstLoad = false;
    // 右边缘长按压扁 / 拉伸过的，也一并回到默认比例
    Scale.squash = 0;
    applyChartMargins();
    drawSchedule();
    toast('已重置当前周期走势');
  }

  /** 换币种先把旧图清掉，别让上一只币的 K 线停在下面。 */
  function chartClear() {
    if (!Chart.ready) return;
    Chart.clearing = true;
    try {
      Chart.candle.setData([]);
      Chart.vol.setData([]);
      Object.keys(Chart.ma).forEach(function (k) { Chart.ma[k].setData([]); });
      if (Chart.dif) {
        Chart.dif.setData([]);
        Chart.dea.setData([]);
        Chart.hist.setData([]);
      }
    } catch (e) {}
    Ind.data = null;
    Ind.times = [];
    // 顶部图例只留「涨跌 / 量」，开高低收不显示
    ['lgChg', 'lgV'].forEach(function (id) {
      var e = $(id);
      if (e) { e.textContent = '--'; e.className = ''; }
    });
    Object.keys(Legend.ma).forEach(function (k) {
      if (Legend.ma[k] && Legend.ma[k].b) Legend.ma[k].b.textContent = '--';
    });
    Draw.measure = null; // 换标的后测距的涨跌幅不再成立
    Draw.pending = null;
    Draw.hover = null;
    paintChartBg();
    updatePriceTag();
    drawSchedule();
  }

  /** 非 BTC 的走势图也要给价格浮标上色，单独拉一次它的 24h 涨跌。 */
  function loadChartPct(sym) {
    restGet('/api/v3/ticker/24hr?symbol=' + sym).then(function (o) {
      if (state.symbol !== sym) return;
      state.chartPct = +(o && o.priceChangePercent) || 0;
      updatePriceTag();
    }).catch(function () {});
  }

  function switchSymbol(sym) {
    sym = String(sym || '').trim().toUpperCase();
    if (!/^[A-Z0-9]{5,20}$/.test(sym) || sym === state.symbol) return;
    if (state.olderTimer) {
      clearTimeout(state.olderTimer);
      state.olderTimer = 0;
    }
    state.symbol = sym;
    state.seq += 1;
    state.firstLoad = true;
    state.chartPct = 0;
    state.bars = [];
    state.view = null;
    chartClear();
    setSymbolUI();
    showMsg('正在加载 ' + sym + ' K 线…');
    loadBars(state.iv, state.seq).catch(function () {
      if (state.symbol !== sym) return;
      showMsg('K 线加载失败，请重新选择币种');
    });
    if (sym !== SYMBOL) loadChartPct(sym);
    else if (state.ticker) state.chartPct = state.ticker.pct;
    wsConnect(); // kline 流换成新币种，ticker 仍订阅 BTC
  }

  // 自选标的：本地保存，搜索结果点 ☆ 加入，点自选行直接看走势
  var LS_WATCH = 'huideng.trade.watch';

  function watchValid(sym) {
    return typeof sym === 'string' && /^[A-Z0-9]{5,20}$/.test(sym);
  }

  function loadWatch() {
    try {
      var arr = JSON.parse(readLS(LS_WATCH) || 'null');
      if (arr && arr.length) {
        var out = arr.filter(watchValid);
        if (out.length) return out;
      }
    } catch (e) {}
    return ['BTCUSDT'];
  }

  function saveWatch() { writeLS(LS_WATCH, JSON.stringify(state.watch)); }

  function inWatch(sym) { return state.watch.indexOf(sym) >= 0; }

  // 各标的 24h 涨跌幅：自选/搜索结果里显示，批量拉、缓存 60 秒
  var PCT_TTL = 60 * 1000;
  var pctWant = [];
  var pctForce = false;
  var pctTimer = 0;

  function pctOf(sym) {
    // BTC 有 WebSocket 实时 ticker，直接用它的 24h 涨跌，比 60 秒缓存的新
    if (sym === SYMBOL && state.ticker && Number.isFinite(+state.ticker.pct)) return +state.ticker.pct;
    var e = state.pct[sym];
    return e && Number.isFinite(e.pct) ? e.pct : null;
  }

  function pctText(sym) {
    var p = pctOf(sym);
    return p == null ? '--' : fmtPct(p);
  }

  function pctClass(sym) {
    var p = pctOf(sym);
    if (p == null) return '';
    return p > 0 ? 'is-up' : p < 0 ? 'is-down' : '';
  }

  /** 价格小数位：按这个币自己的价位决定，和走势图当前看的币无关。 */
  function priceDigits(v) {
    var a = Math.abs(+v);
    if (!Number.isFinite(a) || a <= 0) return 2;
    if (a >= 10) return 2;
    if (a >= 1) return 4;
    if (a >= 0.1) return 5;
    if (a >= 0.01) return 6;
    if (a >= 0.0001) return 7;
    return 8;
  }

  /** 自选里的最新价：BTC 走实时 ticker，其余用批量 24h ticker 的 lastPrice。 */
  function priceOf(sym) {
    if (sym === SYMBOL && state.ticker && state.ticker.price) return +state.ticker.price;
    var e = state.pct[sym];
    return e && Number.isFinite(e.last) ? e.last : null;
  }

  function priceText(sym) {
    var v = priceOf(sym);
    if (!Number.isFinite(v)) return '--';
    return group(v, priceDigits(v));
  }

  /** 批量补 24h 涨跌幅 + 最新价（一次最多 100 个），拿不到就保持 --。 */
  function ensurePct(symbols, done, force) {
    var now = Date.now();
    var need = [];
    symbols.forEach(function (s) {
      if (!s) return;
      var e = state.pct[s];
      if (force || !e || now - e.t > PCT_TTL) {
        if (need.indexOf(s) < 0) need.push(s);
      }
    });
    if (!need.length) { if (done) done(false); return; }
    var url = '/api/v3/ticker/24hr?symbols=' + encodeURIComponent(JSON.stringify(need.slice(0, 100)));
    restGet(url).then(function (rows) {
      var list = Object.prototype.toString.call(rows) === '[object Array]' ? rows : [rows];
      var hit = false;
      list.forEach(function (o) {
        if (!o || !o.symbol) return;
        var p = parseFloat(o.priceChangePercent);
        if (!Number.isFinite(p)) return;
        var last = parseFloat(o.lastPrice);
        state.pct[o.symbol] = { pct: p, last: Number.isFinite(last) ? last : null, t: Date.now() };
        hit = true;
      });
      if (done) done(hit);
    }).catch(function () { if (done) done(false); });
  }

  /** 防抖合并请求，回来重画自选 / 搜索结果。force = 跳过 60 秒缓存。 */
  function loadPct(symbols, force) {
    pctWant = pctWant.concat(symbols || []);
    if (force) pctForce = true;
    if (pctTimer) return;
    pctTimer = setTimeout(function () {
      pctTimer = 0;
      var want = pctWant;
      var forced = pctForce;
      pctWant = [];
      pctForce = false;
      ensurePct(want, function (changed) {
        if (!changed) return;
        renderWatch();
        if (symState.open) renderSymResults();
      }, forced);
    }, 260);
  }

  /** 自选开着时每秒把价格文字对一遍：BTC 是秒级实时，其它币种等 12 秒一次的批量刷新。 */
  function refreshWatchPrices() {
    var listEl = $('watchList');
    if (!listEl || !state.watchOpen || !listEl.querySelectorAll) return;
    Array.prototype.forEach.call(listEl.querySelectorAll('[data-price]'), function (el) {
      var sym = el.getAttribute('data-price');
      var txt = priceText(sym);
      if (el.textContent !== txt) el.textContent = txt;
    });
  }

  function toggleWatch(sym) {
    var i = state.watch.indexOf(sym);
    if (i >= 0) state.watch.splice(i, 1);
    else state.watch.push(sym);
    saveWatch();
    renderWatch();
    if (symState.open) renderSymResults();
  }

  /** DOGEUSDT → DOGE / USDT；认不出计价币就整串当名字。 */
  var SYM_QUOTES = ['USDT', 'USDC', 'FDUSD', 'TUSD', 'BUSD', 'BTC', 'ETH', 'BNB', 'EUR', 'TRY', 'BRL'];
  function splitSymbol(sym) {
    var s = String(sym || '');
    for (var i = 0; i < SYM_QUOTES.length; i += 1) {
      var q = SYM_QUOTES[i];
      if (s.length > q.length && s.slice(-q.length) === q) {
        return { base: s.slice(0, -q.length), quote: q };
      }
    }
    return { base: s, quote: '' };
  }

  function renderWatch() {
    var listEl = $('watchList');
    var box = $('watchBox');
    var empty = $('watchEmpty');
    var toggle = $('watchToggle');
    if (box) box.hidden = !state.watchOpen;
    if (toggle) toggle.setAttribute('aria-expanded', state.watchOpen ? 'true' : 'false');
    if (empty) empty.hidden = state.watch.length > 0;
    if (!listEl) return;
    listEl.innerHTML = '';
    state.watch.forEach(function (sym) {
      var sp = splitSymbol(sym);
      var row = document.createElement('div');
      row.className = 'watch-row';
      var pick = document.createElement('button');
      pick.type = 'button';
      pick.className = 'watch-row__sym' + (sym === state.symbol ? ' is-on' : '');
      pick.setAttribute('data-sym', sym);
      // 名称写成 DOGE/USDT（计价币淡一点），后面是实时价和 24h 涨跌
      pick.innerHTML = '<b>' + sp.base +
        (sp.quote ? '<span class="watch-row__quote">/' + sp.quote + '</span>' : '') + '</b>' +
        '<em class="watch-row__price" data-price="' + sym + '">' + priceText(sym) + '</em>' +
        '<em class="sym-chg ' + pctClass(sym) + '">' + pctText(sym) + '</em>';
      var del = document.createElement('button');
      del.type = 'button';
      del.className = 'watch-row__del';
      del.setAttribute('data-del', sym);
      del.setAttribute('aria-label', '移出自选');
      del.textContent = '★';
      row.appendChild(pick);
      row.appendChild(del);
      listEl.appendChild(row);
    });
    loadPct(state.watch);
  }

  /** 搜索结果：点行看走势，点 ☆ 加入 / 移出自选。 */
  function renderSymResults() {
    var input = $('symInput');
    var listEl = $('symList');
    if (!input || !listEl) return;
    var search = $('watchSearch');
    if (search && search.hidden) {
      // 搜索框已经收起，晚到的币种列表别再弹出来
      listEl.hidden = true;
      symState.open = false;
      return;
    }
    var list = symState.list || HOT_SYMBOLS;
    var matches = matchSymbols(list, input.value);
    listEl.innerHTML = '';
    if (!matches.length) {
      var empty = document.createElement('div');
      empty.className = 'symsearch__empty';
      empty.textContent = symState.loading ? '币种列表加载中…' : '没找到，换个关键词试试';
      listEl.appendChild(empty);
    } else {
      matches.forEach(function (sym) {
        var base = sym.slice(0, -4);
        var row = document.createElement('div');
        row.className = 'sym-row';
        var pick = document.createElement('button');
        pick.type = 'button';
        pick.className = 'sym-row__pick';
        pick.setAttribute('data-sym', sym);
        pick.innerHTML = '<b>' + base + '</b><span>' + sym + '</span>' +
          '<em class="sym-chg ' + pctClass(sym) + '">' + pctText(sym) + '</em>';
        var star = document.createElement('button');
        star.type = 'button';
        star.className = 'sym-row__star' + (inWatch(sym) ? ' is-on' : '');
        star.setAttribute('data-star', sym);
        star.setAttribute('aria-label', inWatch(sym) ? '移出自选' : '加入自选');
        star.textContent = inWatch(sym) ? '★' : '☆';
        row.appendChild(pick);
        row.appendChild(star);
        listEl.appendChild(row);
      });
    }
    listEl.hidden = false;
    loadPct(matches);
    symState.open = true;
  }

  function closeSymResults() {
    var listEl = $('symList');
    if (listEl) listEl.hidden = true;
    symState.open = false;
  }

  /** 点自选条右侧的搜索图标：自选条变成搜索框。 */
  function openSymbolSearch() {
    var box = $('watchSearch');
    var input = $('symInput');
    var listEl = $('symList');
    var head = $('watchHead');
    var aside = $('deskSide');
    if (!box || !input) return;
    box.hidden = false;
    // 结果向上展开，最多铺到右侧面板顶部（总资产那一块）
    if (listEl && head && aside && typeof head.getBoundingClientRect === 'function') {
      var room = head.getBoundingClientRect().top - aside.getBoundingClientRect().top - 6;
      listEl.style.maxHeight = Math.max(180, Math.min(560, room)) + 'px';
    }
    loadSymbols(renderSymResults);
    renderSymResults();
    try { input.focus(); } catch (e) {}
  }

  function closeSymbolSearch() {
    var box = $('watchSearch');
    var input = $('symInput');
    if (box) box.hidden = true;
    if (input) input.value = '';
    closeSymResults();
  }

  function pickSymbol(sym) {
    closeSymbolSearch();
    switchSymbol(sym);
  }

  function bindSymbolSearch() {
    var input = $('symInput');
    var listEl = $('symList');
    var watchList = $('watchList');
    var toggle = $('watchToggle');
    var searchBtn = $('watchSearchBtn');
    var closeBtn = $('symClose');
    var head = $('watchHead');
    if (!input || !listEl) return;

    function load() {
      if (symState.list || symState.loading) return;
      loadSymbols(renderSymResults);
    }
    if (searchBtn) searchBtn.addEventListener('click', openSymbolSearch);
    if (closeBtn) closeBtn.addEventListener('click', closeSymbolSearch);
    input.addEventListener('focus', function () { load(); renderSymResults(); });
    input.addEventListener('input', function () { load(); renderSymResults(); });
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeSymbolSearch();
      else if (e.key === 'Enter') {
        e.preventDefault();
        var first = listEl.querySelector('.sym-row__pick');
        if (first) pickSymbol(first.getAttribute('data-sym'));
      }
    });
    listEl.addEventListener('click', function (e) {
      var star = e.target && e.target.closest ? e.target.closest('button[data-star]') : null;
      if (star) { toggleWatch(star.getAttribute('data-star')); return; }
      var b = e.target && e.target.closest ? e.target.closest('button[data-sym]') : null;
      if (b) pickSymbol(b.getAttribute('data-sym'));
    });
    if (watchList) {
      watchList.addEventListener('click', function (e) {
        var del = e.target && e.target.closest ? e.target.closest('button[data-del]') : null;
        if (del) { toggleWatch(del.getAttribute('data-del')); return; }
        var b = e.target && e.target.closest ? e.target.closest('button[data-sym]') : null;
        if (b) switchSymbol(b.getAttribute('data-sym'));
      });
    }
    if (toggle) {
      toggle.addEventListener('click', function () {
        if (!$('watchSearch').hidden) closeSymbolSearch();
        state.watchOpen = !state.watchOpen;
        renderWatch();
      });
    }
    document.addEventListener('click', function (e) {
      if (!symState.open) return;
      if (head && e.target && head.contains && head.contains(e.target)) return;
      closeSymbolSearch();
    });
    renderWatch();
    var box = $('watchSearch');
    if (box) box.hidden = true;
    closeSymResults();
  }


  // ---------------------------------------------------------------- 技术指标
  // 均线可改周期、可增删（右键 K 线上的均线也能删），MACD / 成交量副图可开关。
  // 指标全部在本地算，不额外请求行情接口。
  var MA_PRESETS = [5, 10, 20, 30, 60, 120];
  var MA_PALETTE = ['#B5651D', '#2F6F8F', '#8E5A9E', '#6B7A4F', '#B08A2E', '#8C5A6B'];
  var MA_MAX = 6;
  var MA_MIN_P = 2;
  var MA_MAX_P = 250;
  var MACD = { fast: 12, slow: 26, signal: 9 };
  var LS_IND = 'huideng.trade.ind';
  var DIF_COLOR = '#B5651D';
  var DEA_COLOR = '#2F6F8F';

  function defaultMa() {
    return [
      { p: 5, c: MA_PALETTE[0], hidden: false },
      { p: 10, c: MA_PALETTE[1], hidden: false },
      { p: 20, c: MA_PALETTE[2], hidden: false }
    ];
  }

  var Ind = {
    ma: defaultMa(),
    macd: true,
    vol: true,
    times: [],
    data: null,
    syncing: false,
    editing: 0
  };

  // 图内数值浮层的 DOM 引用，建一次，之后只改文字。
  var Legend = { ma: {}, dif: null, dea: null, hist: null, histCell: null };

  function normPeriod(v) {
    v = Math.round(+v);
    if (!Number.isFinite(v)) return 0;
    if (v < MA_MIN_P || v > MA_MAX_P) return 0;
    return v;
  }

  function maLabel(p) { return 'MA' + p; }

  // 选颜色时给的色板：白/黄/红/蓝放在最前面，后面是原来那组耐看的深色
  var MA_SWATCHES = [
    '#FFFFFF', '#F2C53D', '#D64545', '#3B82D6',
    '#B5651D', '#2F6F8F', '#8E5A9E', '#6B7A4F',
    '#B08A2E', '#8C5A6B', '#2C7A7B', '#5B6B8C'
  ];

  function normColor(c) {
    c = String(c || '').trim();
    return /^#[0-9a-f]{6}$/i.test(c) ? c.toLowerCase() : '';
  }

  function maByPeriod(p) {
    for (var i = 0; i < Ind.ma.length; i += 1) {
      if (Ind.ma[i].p === +p) return Ind.ma[i];
    }
    return null;
  }

  function nextMaColor() {
    var used = {};
    Ind.ma.forEach(function (m) { used[m.c] = 1; });
    for (var i = 0; i < MA_PALETTE.length; i += 1) {
      if (!used[MA_PALETTE[i]]) return MA_PALETTE[i];
    }
    return MA_PALETTE[Ind.ma.length % MA_PALETTE.length];
  }

  function smaOf(values, n) {
    var out = new Array(values.length);
    var sum = 0;
    for (var i = 0; i < values.length; i += 1) {
      sum += values[i];
      if (i >= n) sum -= values[i - n];
      out[i] = i >= n - 1 ? sum / n : null;
    }
    return out;
  }

  /** EMA 用首值做种子，和常见看盘软件一致；前几根会抖，属正常。 */
  function emaOf(values, n) {
    var out = new Array(values.length);
    if (!values.length) return out;
    var k = 2 / (n + 1);
    out[0] = values[0];
    for (var i = 1; i < values.length; i += 1) {
      out[i] = values[i] * k + out[i - 1] * (1 - k);
    }
    return out;
  }

  /**
   * 返回与 bars 等长的数组：
   *   ma[p]  —— 当前打开的周期，前 p-1 根为 null；
   *   dif / dea / hist —— MACD 三件套，长度与 bars 相同。
   */
  function computeIndicators(bars) {
    var closes = [];
    var i;
    for (i = 0; i < bars.length; i += 1) closes.push(bars[i].close);

    var res = { ma: {}, dif: [], dea: [], hist: [] };
    Ind.ma.forEach(function (m) { res.ma[m.p] = smaOf(closes, m.p); });

    var fast = emaOf(closes, MACD.fast);
    var slow = emaOf(closes, MACD.slow);
    for (i = 0; i < closes.length; i += 1) res.dif[i] = fast[i] - slow[i];
    res.dea = emaOf(res.dif, MACD.signal);
    for (i = 0; i < closes.length; i += 1) res.hist[i] = (res.dif[i] - res.dea[i]) * 2;
    return res;
  }

  function pointsOf(bars, values) {
    var out = [];
    for (var i = 0; i < bars.length; i += 1) {
      var v = values[i];
      if (v != null && Number.isFinite(v)) out.push({ time: bars[i].time, value: v });
    }
    return out;
  }

  function histPointsOf(bars, values) {
    var out = [];
    for (var i = 0; i < bars.length; i += 1) {
      var v = values[i];
      if (v == null || !Number.isFinite(v)) continue;
      out.push({ time: bars[i].time, value: v, color: v >= 0 ? UP_SOFT : DOWN_SOFT });
    }
    return out;
  }

  function fmtInd(v) {
    if (!Number.isFinite(+v)) return '--';
    return (+v > 0 ? '+' : '') + group(+v, chartDigits());
  }

  function indexOfTime(t) {
    var arr = Ind.times;
    var lo = 0;
    var hi = arr.length - 1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (arr[mid] === t) return mid;
      if (arr[mid] < t) lo = mid + 1;
      else hi = mid - 1;
    }
    return -1;
  }

  function barAt(t) {
    var i = indexOfTime(t);
    return i >= 0 ? state.bars[i] : null;
  }

  /**
   * 图例只画一个时间点：鼠标悬停时停在悬停那根，没悬停时跟最后一根。
   * 每秒的行情推送不能把悬停读数冲掉，否则鼠标一停数字就乱跳。
   */
  function refreshLegend() {
    var b = Chart.hover && Chart.hover.time != null ? barAt(Chart.hover.time) : null;
    if (!b) b = state.bars[state.bars.length - 1];
    if (b) showLegend(b);
  }

  function showInd(i) {
    var ind = Ind.data;
    if (!ind || !Ind.times.length) return;
    if (i == null || i < 0 || i >= Ind.times.length) i = Ind.times.length - 1;

    Ind.ma.forEach(function (m) {
      var cell = Legend.ma[m.p];
      if (!cell) return;
      var v = ind.ma[m.p] ? ind.ma[m.p][i] : null;
      cell.b.textContent = v == null || !Number.isFinite(v) ? '--' : fmtAxis(v);
    });

    if (Legend.dif) Legend.dif.textContent = fmtInd(ind.dif[i]);
    if (Legend.dea) Legend.dea.textContent = fmtInd(ind.dea[i]);
    if (Legend.hist) Legend.hist.textContent = fmtInd(ind.hist[i]);
    if (Legend.histCell) Legend.histCell.className = ind.hist[i] >= 0 ? 'is-up' : 'is-down';
  }

  function loadIndPrefs() {
    var raw = readLS(LS_IND);
    if (!raw) return;
    try {
      var p = JSON.parse(raw);
      if (p && p.ma && p.ma.length != null) {
        var list = [];
        p.ma.forEach(function (x) {
          var period = normPeriod(typeof x === 'number' ? x : x && x.p);
          if (!period) return;
          for (var k = 0; k < list.length; k += 1) if (list[k].p === period) return;
          list.push({
            p: period,
            c: normColor(x && x.c) || MA_PALETTE[list.length % MA_PALETTE.length],
            hidden: !!(x && x.hidden)
          });
        });
        // 空数组也认：用户把均线全删了，刷新后就别再塞回来
        Ind.ma = list.slice(0, MA_MAX);
      }
      if (p && typeof p.macd === 'boolean') Ind.macd = p.macd;
      if (p && typeof p.vol === 'boolean') Ind.vol = p.vol;
    } catch (e) {
      // 存坏了就用默认值，不影响图表
    }
  }

  function saveIndPrefs() {
    var ma = Ind.ma.map(function (m) { return { p: m.p, c: m.c, hidden: !!m.hidden }; });
    writeLS(LS_IND, JSON.stringify({ ma: ma, macd: !!Ind.macd, vol: !!Ind.vol }));
  }

  function mkCell(box, label, color) {
    var sp = document.createElement('span');
    var i = document.createElement('i');
    i.textContent = label;
    if (color) i.style.color = color;
    var b = document.createElement('b');
    b.textContent = '--';
    sp.appendChild(i);
    sp.appendChild(b);
    box.appendChild(sp);
    return { span: sp, i: i, b: b };
  }

  /** 图例里的均线读数：一直显示（隐藏的也是，按 is-off 变淡），点一下改周期 / 颜色 / 隐藏 / 删除。 */
  function buildMaLegend() {
    var box = $('maLegend');
    if (!box) return;
    box.innerHTML = '';
    Legend.ma = {};
    Ind.ma.forEach(function (m) {
      var chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'ma-chip' + (m.hidden ? ' is-off' : '');
      chip.setAttribute('data-ma', String(m.p));
      chip.title = (m.hidden ? '已隐藏 · ' : '') + '点击设置 ' + maLabel(m.p);
      var i = document.createElement('i');
      i.textContent = maLabel(m.p);
      i.style.color = m.c;
      var b = document.createElement('b');
      b.textContent = '--';
      chip.appendChild(i);
      chip.appendChild(b);
      chip.onclick = function (e) {
        // 别让 document 上的「点空白处关浮层」立刻把它关上
        if (e && e.stopPropagation) e.stopPropagation();
        openMaPop(m.p, chip);
      };
      chip.oncontextmenu = function (e) {
        e.preventDefault();
        e.stopPropagation();
        // 手机上长按图例不再弹编辑页：点一下数值就能打开
        if (DRAW_DEV === 'm') return;
        openMaPop(m.p, chip);
      };
      box.appendChild(chip);
      Legend.ma[m.p] = { span: chip, i: i, b: b };
    });
  }

  function setMaHidden(period, on) {
    var m = maByPeriod(period);
    if (!m) return;
    m.hidden = !!on;
    var s = Chart.ma[m.p];
    if (s) {
      try { s.applyOptions({ visible: !m.hidden }); } catch (e) {}
    }
    var row = Legend.ma[m.p];
    if (row) {
      row.span.classList.toggle('is-off', !!m.hidden);
      row.span.title = (m.hidden ? '已隐藏 · ' : '') + '点击设置 ' + maLabel(m.p);
    }
    syncMaHideBtn();
    saveIndPrefs();
    refreshLegend();
  }

  function syncMaHideBtn() {
    var btn = $('maHide');
    if (!btn) return;
    var m = Ind.editing ? maByPeriod(Ind.editing) : null;
    btn.hidden = !m;
    if (m) btn.textContent = m.hidden ? '显示这条均线' : '隐藏这条均线';
  }

  function fillLegends() {
    buildMaLegend();

    var mb = $('macdLegend');
    if (mb) {
      mb.innerHTML = '';
      var title = document.createElement('span');
      title.className = 'chart__ind-title';
      title.textContent = 'MACD';
      var params = document.createElement('i');
      params.className = 'chart__ind-params';
      params.textContent = '(' + MACD.fast + ',' + MACD.slow + ',' + MACD.signal + ')';
      title.appendChild(params);
      mb.appendChild(title);
      Legend.dif = mkCell(mb, 'DIF', null).b;
      Legend.dea = mkCell(mb, 'DEA', null).b;
      var h = mkCell(mb, '柱', null);
      Legend.hist = h.b;
      Legend.histCell = h.span;
    }
  }

  /** 工具条上的均线按钮：点一下改周期，不是开关。 */
  function renderMaTools() {
    var box = $('maTools');
    if (!box) return;
    box.innerHTML = '';
    Ind.ma.forEach(function (m) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'ma-btn' + (m.hidden ? ' is-off' : '');
      b.setAttribute('data-ma', String(m.p));
      b.style.color = m.c;
      b.textContent = maLabel(m.p);
      b.title = (m.hidden ? '已隐藏 · ' : '') + '点击修改 ' + maLabel(m.p);
      box.appendChild(b);
    });
    var add = document.createElement('button');
    add.type = 'button';
    add.className = 'ma-add';
    add.id = 'maAdd';
    add.textContent = '＋';
    add.title = '添加均线';
    add.setAttribute('aria-label', '添加均线');
    box.appendChild(add);
  }

  // ---------------------------- 浮层 / 右键菜单 ----------------------------

  function placePop(pop, anchor) {
    if (!pop || !anchor || !anchor.getBoundingClientRect) return;
    var r = anchor.getBoundingClientRect();
    pop.hidden = false;
    var w = pop.offsetWidth || 238;
    var h = pop.offsetHeight || 190;
    var left = Math.min(Math.max(8, r.left), (window.innerWidth || 1024) - w - 8);
    var top = r.bottom + 6;
    if (top + h > (window.innerHeight || 768) - 8) top = Math.max(8, r.top - h - 6);
    pop.style.left = left + 'px';
    pop.style.top = top + 'px';
  }

  function placeCtx(menu, x, y) {
    menu.hidden = false;
    var w = menu.offsetWidth || 180;
    var h = menu.offsetHeight || 200;
    var left = Math.min(Math.max(8, x), (window.innerWidth || 1024) - w - 8);
    var top = Math.min(Math.max(8, y), (window.innerHeight || 768) - h - 8);
    menu.style.left = left + 'px';
    menu.style.top = top + 'px';
  }

  function closeMenus(except) {
    ['maPop', 'ctxMenu', 'acctMenu', 'lineMenu'].forEach(function (id) {
      var el = $(id);
      if (el && el !== except) el.hidden = true;
    });
    var openBtn = document.querySelector ? document.querySelector('.ma-chip.is-open') : null;
    if (openBtn) openBtn.classList.remove('is-open');
    var btn = $('btnMenu');
    if (btn) btn.setAttribute('aria-expanded', 'false');
    Ind.editing = 0;
  }

  function renderMaChips() {
    var box = $('maChips');
    if (!box) return;
    box.innerHTML = '';
    var cur = Ind.editing;
    var list = MA_PRESETS.slice();
    if (cur && list.indexOf(cur) < 0) list.unshift(cur);
    list.forEach(function (p) {
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = maLabel(p);
      if (p === cur) b.className = 'is-cur';
      if (p !== cur && maByPeriod(p)) b.disabled = true;
      b.onclick = function () {
        if (cur) changeMaPeriod(cur, p);
        else addMa(p);
      };
      box.appendChild(b);
    });
  }

  function renderMaColors(p) {
    var wrap = $('maColorWrap');
    if (wrap) wrap.hidden = !p;
    var box = $('maColors');
    if (!box) return;
    box.innerHTML = '';
    var m = p ? maByPeriod(p) : null;
    var cur = m ? normColor(m.c) : '';
    MA_SWATCHES.forEach(function (c) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'swatch' + (c === cur ? ' is-cur' : '');
      b.style.background = c;
      b.title = c;
      b.setAttribute('aria-label', '颜色 ' + c);
      b.onclick = function () {
        if (!Ind.editing) return;
        setMaColor(Ind.editing, c);
        renderMaColors(Ind.editing);
      };
      box.appendChild(b);
    });

    var input = document.createElement('input');
    input.type = 'color';
    input.className = 'swatch swatch--custom';
    input.value = cur || MA_SWATCHES[0];
    input.title = '自定义颜色';
    input.setAttribute('aria-label', '自定义颜色');
    input.onchange = function () {
      if (!Ind.editing) return;
      setMaColor(Ind.editing, input.value);
      renderMaColors(Ind.editing);
    };
    box.appendChild(input);
  }

  function setMaColor(period, color) {
    var c = normColor(color);
    if (!c) return;
    var m = maByPeriod(period);
    if (!m) return;
    m.c = c;
    var s = Chart.ma[m.p];
    if (s) {
      try { s.applyOptions({ color: c }); } catch (e) {}
    }
    var cell = Legend.ma[m.p];
    if (cell && cell.i) cell.i.style.color = c;
    var btn = document.querySelector ? document.querySelector('#maTools .ma-btn[data-ma="' + m.p + '"]') : null;
    if (btn) btn.style.color = c;
    saveIndPrefs();
  }

  function openMaPop(p, btn) {
    closeMenus();
    Ind.editing = p || 0;
    var pop = $('maPop');
    if (!pop) return;
    if (btn && btn.classList) btn.classList.add('is-open');
    var title = $('maPopTitle');
    if (title) title.textContent = p ? '均线 ' + maLabel(p) : '添加均线';
    var del = $('maDelete');
    if (del) del.hidden = !p;
    syncMaHideBtn();
    renderMaChips();
    renderMaColors(p || 0);
    var input = $('maCustom');
    if (input) {
      input.value = '';
      input.placeholder = p ? '改成…（2-250）' : '自定义（2-250）';
    }
    pop.hidden = false;
    placePop(pop, btn || $('chart'));
  }

  function ctxItem(menu, label, fn, cls, disabled) {
    var b = document.createElement('button');
    b.type = 'button';
    b.textContent = label;
    if (cls) b.className = cls;
    if (disabled) b.disabled = true;
    b.onclick = function () { if (!disabled) fn(); };
    menu.appendChild(b);
  }

  function ctxLabel(menu, text) {
    var d = document.createElement('div');
    d.className = 'ctx__label';
    d.textContent = text;
    menu.appendChild(d);
  }

  function ctxSep(menu) {
    var d = document.createElement('div');
    d.className = 'ctx__sep';
    menu.appendChild(d);
  }

  function maAtPoint(x, y) {
    if (!Ind.data || !Chart.chart) return null;
    var ts = Chart.chart.timeScale();
    if (!ts || typeof ts.coordinateToTime !== 'function') return null;
    var t = ts.coordinateToTime(x);
    if (t == null) return null;
    var i = indexOfTime(t);
    if (i < 0) return null;
    var best = null;
    var bestD = 7;
    Ind.ma.forEach(function (m) {
      var s = Chart.ma[m.p];
      if (!s || typeof s.priceToCoordinate !== 'function') return;
      var v = Ind.data.ma[m.p] ? Ind.data.ma[m.p][i] : null;
      if (v == null || !Number.isFinite(v)) return;
      var py = s.priceToCoordinate(v);
      if (py == null) return;
      var d = Math.abs(py - y);
      if (d < bestD) {
        bestD = d;
        best = m;
      }
    });
    return best;
  }

  function openCtx(x, y, hit) {
    closeMenus();
    var menu = $('ctxMenu');
    if (!menu) return;
    menu.innerHTML = '';
    if (hit) {
      ctxItem(menu, '删除 ' + maLabel(hit.p), function () { removeMa(hit.p); }, 'is-danger', false);
      ctxSep(menu);
    }
    ctxLabel(menu, '添加均线');
    var full = Ind.ma.length >= MA_MAX;
    MA_PRESETS.forEach(function (p) {
      if (maByPeriod(p)) return;
      ctxItem(menu, maLabel(p), function () { addMa(p); }, '', full);
    });
    if (full) ctxLabel(menu, '最多同时显示 ' + MA_MAX + ' 条');
    ctxSep(menu);
    ctxLabel(menu, '副图');
    ctxItem(menu, (Ind.vol ? '隐藏' : '显示') + '成交量', function () { setVolVisible(!Ind.vol); }, '', false);
    ctxItem(menu, (Ind.macd ? '隐藏' : '显示') + ' MACD', function () { setMacdVisible(!Ind.macd); }, '', false);
    ctxSep(menu);
    ctxItem(menu, '恢复默认均线', resetMa, '', false);
    menu.hidden = false;
    placeCtx(menu, x, y);
  }

  function onChartCtx(e) {
    if (!Chart.ready || !Chart.chart) return;
    e.preventDefault();
    // 右键在直线上：直线菜单（删除 / 锁定 / 颜色）；否则是均线菜单
    var ln = lineAtPoint(e.clientX, e.clientY);
    if (DRAW_DEV === 'm') {
      // 手机长按只留十字线：不再弹「添加均线」菜单（双击屏幕才是入口），
      // 但长按在直线上还是给直线菜单，否则手机上删不了单条直线。
      if (ln && !Draw.active) openLineCtx(e.clientX, e.clientY, ln);
      return;
    }
    if (ln) { openLineCtx(e.clientX, e.clientY, ln); return; }
    var box = $('chart');
    if (!box) return;
    var r = box.getBoundingClientRect();
    openCtx(e.clientX, e.clientY, maAtPoint(e.clientX - r.left, e.clientY - r.top));
  }

  // ---------------------------- 增删改 ----------------------------

  function syncMaSeries() {
    if (!Chart.ready || !Chart.chart) return;
    var wanted = {};
    Ind.ma.forEach(function (m) { wanted[m.p] = 1; });
    Object.keys(Chart.ma).forEach(function (k) {
      if (wanted[+k]) return;
      try { Chart.chart.removeSeries(Chart.ma[k]); } catch (e) {}
      delete Chart.ma[k];
    });
    Ind.ma.forEach(function (m) {
      if (!Chart.ma[m.p]) {
        Chart.ma[m.p] = Chart.chart.addLineSeries({
          color: m.c,
          lineWidth: 1,
          priceLineVisible: false,
          lastValueVisible: false,
          crosshairMarkerVisible: false,
          visible: !m.hidden
        });
      } else {
        try { Chart.ma[m.p].applyOptions({ color: m.c, visible: !m.hidden }); } catch (e) {}
      }
    });
  }

  function refreshAfterMaChange() {
    syncMaSeries();
    renderMaTools();
    buildMaLegend();
    if (Chart.ready && state.bars.length) applyIndicators(state.bars, true);
    saveIndPrefs();
    refreshLegend();
  }

  function addMa(period) {
    period = normPeriod(period);
    if (!period) { toast('周期要填 2-250 的整数'); return; }
    if (maByPeriod(period)) { toast('已经有 ' + maLabel(period) + ' 了'); return; }
    if (Ind.ma.length >= MA_MAX) { toast('最多同时显示 ' + MA_MAX + ' 条均线'); return; }
    Ind.ma.push({ p: period, c: nextMaColor() });
    refreshAfterMaChange();
    closeMenus();
    toast('已添加 ' + maLabel(period));
  }

  function removeMa(period) {
    var i = -1;
    for (var k = 0; k < Ind.ma.length; k += 1) {
      if (Ind.ma[k].p === +period) { i = k; break; }
    }
    if (i < 0) return;
    var label = maLabel(Ind.ma[i].p);
    Ind.ma.splice(i, 1);
    refreshAfterMaChange();
    closeMenus();
    toast('已删除 ' + label);
  }

  function changeMaPeriod(oldP, newP) {
    newP = normPeriod(newP);
    if (!newP) { toast('周期要填 2-250 的整数'); return; }
    var m = maByPeriod(oldP);
    if (!m) return;
    if (m.p === newP) { closeMenus(); return; }
    if (maByPeriod(newP)) { toast('已经有 ' + maLabel(newP) + ' 了'); return; }
    var oldLabel = maLabel(m.p);
    m.p = newP;
    refreshAfterMaChange();
    closeMenus();
    toast(oldLabel + ' 已改为 ' + maLabel(newP));
  }

  function resetMa() {
    Ind.ma = defaultMa();
    refreshAfterMaChange();
    closeMenus();
    toast('已恢复默认均线');
  }

  function applyMaInput() {
    var input = $('maCustom');
    var p = normPeriod(input ? input.value : '');
    if (!p) { toast('周期要填 2-250 的整数'); return; }
    if (Ind.editing) changeMaPeriod(Ind.editing, p);
    else addMa(p);
  }

  // ---------------------------- 账户菜单 ----------------------------

  /** 交易页右下角的「交易笔记」子页面：从右侧滑入，左侧留一段走势图。 */
  function openNotesSlide() {
    if (Account.mode !== 'cloud') {
      pendingNotesSlide = true;
      openModal();
      return;
    }
    var slide = $('notesSlide');
    var frame = $('notesFrame');
    var btn = $('btnNotes');
    if (!slide) return;
    if (frame && !frame.getAttribute('src')) {
      frame.setAttribute('src', (cfg.rel || '') + 'notes/index.html?embed=1');
    }
    slide.classList.add('is-open');
    slide.setAttribute('aria-hidden', 'false');
    if (btn) {
      btn.classList.add('is-on');
      btn.setAttribute('aria-expanded', 'true');
    }
    closeMenus();
  }

  function closeNotesSlide() {
    var slide = $('notesSlide');
    var btn = $('btnNotes');
    if (!slide) return;
    slide.classList.remove('is-open');
    slide.setAttribute('aria-hidden', 'true');
    if (btn) {
      btn.classList.remove('is-on');
      btn.setAttribute('aria-expanded', 'false');
    }
  }

  function resetNotesFrame() {
    var frame = $('notesFrame');
    if (frame) frame.removeAttribute('src');
  }

  function toggleNotesSlide() {
    var slide = $('notesSlide');
    if (slide && slide.classList.contains('is-open')) closeNotesSlide();
    else openNotesSlide();
  }

  function applyTradeAvatar(src) {
    var img = document.querySelector('#btnMenu img');
    if (img) img.src = src || ((cfg.rel || '') + 'assets/icon.png');
  }

  function loadTradeAvatar(force) {
    if (Account.mode !== 'cloud') {
      avatarLoaded = false;
      applyTradeAvatar('');
      return;
    }
    if (avatarLoaded && !force) return;
    avatarLoaded = true;
    api('tradeAvatarGet', {})
      .then(function (j) {
        if (j && j.avatar) applyTradeAvatar(j.avatar);
      })
      .catch(function () {});
  }

  function compressAvatar(file) {
    return new Promise(function (resolve, reject) {
      if (!file || !/^image\/(jpeg|png|webp)$/i.test(file.type || '')) {
        reject(err('bad_image'));
        return;
      }
      if (file.size > 25 * 1024 * 1024) {
        reject(err('too_large'));
        return;
      }
      var url = URL.createObjectURL(file);
      var img = new Image();
      img.onload = function () {
        URL.revokeObjectURL(url);
        try {
          var size = 96;
          var c = document.createElement('canvas');
          c.width = size;
          c.height = size;
          var ctx = c.getContext('2d');
          ctx.fillStyle = '#fff';
          ctx.fillRect(0, 0, size, size);
          var scale = Math.max(size / img.width, size / img.height);
          var w = img.width * scale;
          var h = img.height * scale;
          ctx.drawImage(img, (size - w) / 2, (size - h) / 2, w, h);
          resolve(c.toDataURL('image/jpeg', 0.82));
        } catch (e) {
          reject(err('bad_image'));
        }
      };
      img.onerror = function () {
        URL.revokeObjectURL(url);
        reject(err('bad_image'));
      };
      img.src = url;
    });
  }

  function setTradeAvatar(file) {
    compressAvatar(file)
      .then(function (dataUrl) {
        if (dataUrl.length > 60000) throw err('too_large');
        return api('tradeAvatarSet', { avatar: dataUrl }).then(function () {
          avatarLoaded = true;
          applyTradeAvatar(dataUrl);
          toast('头像已更新');
        });
      })
      .catch(function (e) {
        toast(msgOf(e && e.code));
      });
  }

  function renderAccountMenu() {
    var who = $('menuWho');
    if (who) {
      who.textContent = Account.mode === 'cloud'
        ? '已登录 · ' + (Account.username || '')
        : '未登录 · 本机账户';
    }
    var login = $('menuLogin');
    var logout = $('menuLogout');
    var phone = $('menuPhone');
    var sync = $('menuSync');
    var avatar = $('menuAvatar');
    if (login) login.hidden = Account.mode === 'cloud';
    if (logout) logout.hidden = Account.mode !== 'cloud';
    if (sync) sync.hidden = Account.mode !== 'cloud';
    if (avatar) avatar.hidden = Account.mode !== 'cloud';
    if (phone) {
      phone.hidden = Account.mode !== 'cloud';
      var bound = (Account.data && Account.data.phone) || Phone.bound || '';
      phone.textContent = bound ? '更换手机号' : '绑定手机号';
      phone.title = bound ? '当前绑定 ' + bound : '绑定手机号';
    }
    loadTradeAvatar(false);
  }

  // ---------------------------------------------------------------- 图表
  var Chart = {
    chart: null, candle: null, vol: null,
    macd: null, hist: null, dif: null, dea: null,
    ma: {}, ready: false, hover: null, clearing: false
  };

  // 鼠标当前所在的十字线像素位置（数据更新后把横线钉回这里，避免价格轴自动缩放让它漂走）
  var Cross = { on: false, mx: 0, my: 0, re: false, timer: 0 };

  function crosshairReanchor() {
    if (!Cross.on || !Chart.chart || !Chart.candle || !Draw.canvas) return;
    try {
      var r = Draw.canvas.getBoundingClientRect();
      var vx = r.left + Cross.mx;
      var vy = r.top + Cross.my;
      var el = document.elementFromPoint ? document.elementFromPoint(vx, vy) : null;
      var target = el && el.dispatchEvent ? el : Draw.canvas;
      // 用一次真实的 mousemove 让库在鼠标像素处重画十字线，
      // 比 setCrosshairPosition 精确：不会把竖线吸到 K 线上
      Cross.re = true;
      try {
        target.dispatchEvent(new MouseEvent('mousemove', { clientX: vx, clientY: vy, bubbles: true }));
      } finally {
        Cross.re = false;
      }
    } catch (e) {
      Cross.re = false;
    }
  }

  // ---------------------------------------------------------------- 画线
  // 覆盖在 K 线上的 canvas：存 (时间, 价格) 而不是像素，缩放/平移后能跟着走。
  var Draw = {
    canvas: null, ctx: null, lines: [], undo: [],
    active: false, drawing: null, drag: null, raf: 0,
    tool: 'free', measure: null, pending: null, hover: null,
    showTrades: false, trades: [], flash: null, flashTimer: 0
  };

  // 当前是手机还是电脑：手机上只显示手机上画的线，电脑上只显示电脑上画的线。
  // 手绘笔画存的是画布相对位置，跨屏幕尺寸本来就对不齐，分开存反而更干净。
  var DRAW_DEV = (function () {
    var nav = (typeof navigator !== 'undefined' && navigator) || {};
    var ua = nav.userAgent || '';
    var coarse = false;
    try {
      coarse = !!(window.matchMedia && window.matchMedia('(pointer: coarse)').matches);
    } catch (e) {}
    var touch = (nav.maxTouchPoints || 0) > 1;
    // iPadOS 的 UA 伪装成 Mac，靠 pointer:coarse + 多点触控认出来
    return /Android|iPhone|iPad|iPod|Windows Phone|HarmonyOS|Mobile/i.test(ua) || (coarse && touch) ? 'm' : 'd';
  })();

  /** 一条线属于哪个设备；老数据没有 dev，按电脑（手机端一律不显示它们）。 */
  function lineDev(ln) {
    return ln && ln.dev === 'm' ? 'm' : 'd';
  }

  // 手机上挂个 <html class="mob">：横屏全屏后宽度会超过 760px，
  // 只靠媒体查询会退回到桌面样式，这几个手机专属样式按设备走更稳。
  try {
    if (DRAW_DEV === 'm' && document.documentElement && document.documentElement.classList) {
      document.documentElement.classList.add('mob');
    }
  } catch (e) {}

  // 历史开平仓点统一用黑色
  var TRADE_COLOR = '#1A1A1A';

  function drawPoint(e) {
    if (!Chart.chart || !Chart.candle || !Draw.canvas) return null;
    var r = Draw.canvas.getBoundingClientRect();
    var x = e.clientX - r.left;
    var y = e.clientY - r.top;
    var ts = Chart.chart.timeScale();
    var t = ts.coordinateToTime(x);
    var l = ts.coordinateToLogical ? ts.coordinateToLogical(x) : null;
    var x0 = t != null ? ts.timeToCoordinate(t) : null;
    var dx = x0 != null ? x - x0 : 0;
    var p = Chart.candle.coordinateToPrice(y);
    if (t == null || p == null || !Number.isFinite(p)) return null;
    // 自由画必须保存「柱时间 + 柱心到鼠标的小数像素偏移 dx」。
    // 只存时间/逻辑下标会被吸附到 K 线柱子上，重绘后立刻变成锯齿。
    return {
      x: x, y: y, t: t, p: p, l: l, dx: dx,
      u: r.width ? x / r.width : 0,
      v: r.height ? y / r.height : 0
    };
  }

  /** 绘图区宽度（不含右侧价格轴）：画线层铺满整个 pane，坐标得按绘图区算。 */
  function plotWidth() {
    var w = 0;
    try { w = Chart.chart && Chart.chart.paneSize ? Chart.chart.paneSize().width : 0; } catch (e) {}
    if (!w) {
      w = Draw.canvas ? Draw.canvas.clientWidth : 0;
      try {
        var ps = Chart.chart.priceScale('right');
        if (ps && ps.width) w -= ps.width() || 0;
      } catch (e) {}
    }
    return w;
  }

  /**
   * 逻辑下标 → 画线层上的像素 x。
   * 用图表库自己的刻度标定两根可见 K 线再线性外推：视野外的点也能算出真实 x
   * （库的 logicalToCoordinate 会把左侧越界坐标夹成 0），而且和蜡烛严丝合缝。
   * 以前直接拿「整块画布宽度」乘以逻辑比例，右侧价格轴那 78px 没扣掉，
   * 越靠右的端点偏得越多（桌面端最右能差 70-80px，正好一根 K 线的位置就错了）。
   */
  function logicalToX(ts, idx, w) {
    var bars = state.bars || [];
    var r = null;
    try { r = ts.getVisibleLogicalRange ? ts.getVisibleLogicalRange() : null; } catch (e) {}
    if (r && bars.length && Number.isFinite(r.from) && Number.isFinite(r.to) && r.to > r.from) {
      var i0 = Math.max(0, Math.ceil(r.from));
      var i1 = Math.min(bars.length - 1, Math.floor(r.to));
      if (i1 > i0) {
        var x0 = null;
        var x1 = null;
        try {
          x0 = ts.timeToCoordinate(bars[i0].time);
          x1 = ts.timeToCoordinate(bars[i1].time);
        } catch (e) {}
        if (x0 != null && x1 != null) {
          return x0 + (idx - i0) * ((x1 - x0) / (i1 - i0));
        }
      }
      if (w) return (idx - r.from) / (r.to - r.from) * w;
    }
    try { return ts.logicalToCoordinate(idx); } catch (e) { return null; }
  }

  /** 直线端点存的是 (时间, 价格) 图表坐标，平移/缩放/换周期时跟着走。 */
  function lineCoord(pt) {
    if (!pt || !Chart.chart || !Chart.candle || !state.bars.length) return null;
    var ts = Chart.chart.timeScale();
    var step = (TF_MS[state.iv] || 60000) / 1000;
    var idx = logicalAtTime(state.bars, step, pt.t);
    var x = logicalToX(ts, idx, plotWidth());
    var y = Chart.candle.priceToCoordinate(pt.p);
    if (x == null || y == null) return null;
    return { x: x, y: y };
  }

  /** 测距只关心价位：右侧空白区没有时间也能量。 */
  function drawMeasurePoint(e) {
    if (!Chart.chart || !Chart.candle || !Draw.canvas) return null;
    var r = Draw.canvas.getBoundingClientRect();
    var x = e.clientX - r.left;
    var y = e.clientY - r.top;
    var p = Chart.candle.coordinateToPrice(y);
    if (p == null || !Number.isFinite(p)) return null;
    return {
      x: x, y: y, p: p,
      t: Chart.chart.timeScale().coordinateToTime(x),
      u: r.width ? x / r.width : 0,
      v: r.height ? y / r.height : 0
    };
  }

  // 画线持久化：本地 + 登录后同步到云端（换设备/换浏览器还在）
  var LS_DRAW = 'huideng.trade.draw';
  var DRAW_KEEP = 60;
  var DRAW_BUDGET = 3000;
  var drawCloudTimer = 0;

  function serializeDrawings() {
    var out = [];
    // 手机、电脑各算各的额度，互不挤占
    var budget = { m: DRAW_BUDGET, d: DRAW_BUDGET };
    Draw.lines.forEach(function (ln) {
      if (!ln || !ln.points || ln.points.length < 2) return;
      var dev = lineDev(ln);
      var pts = [];
      if (ln.infinite) {
        ln.points.slice(0, 2).forEach(function (p) {
          if (!isFinite(p.t) || !isFinite(p.p)) return;
          var o = { t: p.t, p: p.p };
          if (p.note) o.note = String(p.note).slice(0, 80);
          pts.push(o);
        });
      } else {
        var stride = Math.max(1, Math.ceil(ln.points.length / Math.max(1, budget[dev])));
        ln.points.forEach(function (p, i) {
          if (i % stride === 0) {
            if (isFinite(p.t) && isFinite(p.p) && isFinite(p.dx)) {
              pts.push({ t: p.t, p: p.p, dx: p.dx });
            } else if (isFinite(p.l) && isFinite(p.p)) {
              pts.push({ l: p.l, p: p.p });
            } else if (isFinite(p.t) && isFinite(p.p)) {
              pts.push({ t: p.t, p: p.p });
            } else {
              pts.push({ u: p.u, v: p.v });
            }
          }
        });
        budget[dev] -= pts.length;
      }
      if (pts.length < 2) return;
      out.push({
        infinite: !!ln.infinite,
        points: pts,
        color: ln.color || '',
        locked: !!ln.locked,
        tfs: ln.tfs && ln.tfs.length ? ln.tfs : null,
        dev: dev
      });
    });
    // 每台设备各留最近 DRAW_KEEP 条：手机画线不会把电脑上的挤掉
    var kept = [];
    ['d', 'm'].forEach(function (dev) {
      var mine = out.filter(function (o) { return o.dev === dev; });
      if (mine.length > DRAW_KEEP) mine = mine.slice(mine.length - DRAW_KEEP);
      kept = kept.concat(mine);
    });
    return kept;
  }

  function parseDrawings(arr) {
    if (!arr || !arr.length) return [];
    var out = [];
    arr.forEach(function (o) {
      if (!o || !o.points || o.points.length < 2) return;
      var ln = {
        infinite: !!o.infinite,
        points: [],
        color: o.color || '',
        locked: !!o.locked,
        tfs: o.tfs || null,
        dev: o.dev === 'm' ? 'm' : 'd'
      };
      o.points.forEach(function (p) {
        if (!p) return;
        if (ln.infinite) {
          if (!isFinite(p.t) || !isFinite(p.p)) return;
          var pt = { t: +p.t, p: +p.p };
          if (p.note) pt.note = String(p.note).slice(0, 80);
          ln.points.push(pt);
        } else if (isFinite(p.t) && isFinite(p.p) && isFinite(p.dx)) {
          ln.points.push({ t: +p.t, p: +p.p, dx: +p.dx });
        } else if (isFinite(p.l) && isFinite(p.p)) {
          ln.points.push({ l: +p.l, p: +p.p });
        } else if (isFinite(p.t) && isFinite(p.p)) {
          ln.points.push({ t: +p.t, p: +p.p });
        } else if (isFinite(p.u) && isFinite(p.v)) {
          ln.points.push({ u: +p.u, v: +p.v });
        }
      });
      if (ln.points.length >= 2) out.push(ln);
    });
    return out;
  }

  function saveDrawings() {
    var arr = [];
    try {
      arr = serializeDrawings();
      writeLS(LS_DRAW, JSON.stringify(arr));
    } catch (e) {}
    cloudDrawPush(false);
  }

  function loadDrawings() {
    var raw = readLS(LS_DRAW);
    if (!raw) return [];
    var arr = null;
    try { arr = JSON.parse(raw); } catch (e) { return []; }
    return parseDrawings(arr);
  }

  /** 登录后拉云端画线；云端为空而本地有，就把本地上传上去。 */
  function cloudDrawPull() {
    if (Account.mode !== 'cloud' || !Account.token) return;
    api('tradeDrawGet', {}).then(function (j) {
      var arr = j && j.drawings;
      if (Array.isArray(arr) && arr.length) {
        Draw.lines = parseDrawings(arr);
        try { writeLS(LS_DRAW, JSON.stringify(serializeDrawings())); } catch (e) {}
        if (Chart.ready) drawRedraw();
      } else if (Draw.lines.length) {
        cloudDrawPush(true);
      }
    }).catch(function () {});
  }

  /** 画线改动后合并成一次上传，避免每拖一下就发请求。 */
  function cloudDrawPush(now) {
    if (Account.mode !== 'cloud' || !Account.token) return;
    if (drawCloudTimer) {
      clearTimeout(drawCloudTimer);
      drawCloudTimer = 0;
    }
    var run = function () {
      drawCloudTimer = 0;
      try {
        api('tradeDrawSet', { drawings: serializeDrawings() }).catch(function () {});
      } catch (e) {}
    };
    if (now) run();
    else drawCloudTimer = setTimeout(run, 1500);
  }

  /** 关页面 / 退出登录时立即把画线推到云端（keepalive，减少被中断）。 */
  function cloudDrawFlush() {
    if (Account.mode !== 'cloud' || !Account.token) return;
    if (drawCloudTimer) {
      clearTimeout(drawCloudTimer);
      drawCloudTimer = 0;
    }
    try {
      var body = JSON.stringify({ action: 'tradeDrawSet', token: Account.token, drawings: serializeDrawings() });
      fetch(cfg.api, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + cfg.key,
          'x-device-id': 'web'
        },
        body: body,
        keepalive: true
      }).catch(function () {});
    } catch (e) {}
  }

  function strokePath(ctx, pts, color) {
    if (!pts || pts.length < 2) return;
    ctx.save();
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.9)';
    ctx.lineWidth = 4;
    ctx.beginPath();
    pts.forEach(function (pt, i) {
      if (i === 0) ctx.moveTo(pt.x, pt.y);
      else ctx.lineTo(pt.x, pt.y);
    });
    ctx.stroke();
    ctx.strokeStyle = color || '#1E5AA8';
    ctx.lineWidth = 1.6;
    ctx.beginPath();
    pts.forEach(function (pt, i) {
      if (i === 0) ctx.moveTo(pt.x, pt.y);
      else ctx.lineTo(pt.x, pt.y);
    });
    ctx.stroke();
    ctx.restore();
  }

  function drawDot(ctx, x, y, color, r, ring) {    if (ring) {
      ctx.beginPath();
      ctx.arc(x, y, r + 5, 0, Math.PI * 2);
      ctx.strokeStyle = color;
      ctx.globalAlpha = 0.45;
      ctx.lineWidth = 2;
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
    ctx.beginPath();
    ctx.arc(x, y, r + 1.6, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(255, 255, 255, 0.92)';
    ctx.fill();
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fillStyle = color;
    ctx.fill();
  }

  // 测距：两点之间的涨跌幅（按两点的价格算，和画线一样存画布相对位置）
  var DRAW_UP = '#7E1319';
  var DRAW_DOWN = '#305C38';

  function measurePct(p1, p2) {
    return p1 ? (p2 - p1) / p1 * 100 : 0;
  }

  /** 两点直线延长到画布四边（返回 [x1,y1,x2,y2]）。 */
  function extendLine(x1, y1, x2, y2, w, h) {
    var dx = x2 - x1;
    var dy = y2 - y1;
    if (!dx && !dy) return null;
    var tMin = -1e9;
    var tMax = 1e9;
    function clip(p, d, lo, hi) {
      if (Math.abs(d) < 1e-9) return;
      var a = (lo - p) / d;
      var b = (hi - p) / d;
      if (a > b) { var t = a; a = b; b = t; }
      if (a > tMin) tMin = a;
      if (b < tMax) tMax = b;
    }
    clip(x1, dx, 0, w);
    clip(y1, dy, 0, h);
    if (tMin > tMax) return null;
    return [x1 + dx * tMin, y1 + dy * tMin, x1 + dx * tMax, y1 + dy * tMax];
  }

  /** 「直线」工具画的是无限直线，两个端点可拖动调整；命中返回 {line, idx}。 */
  function lineHandleAt(x, y) {
    if (!Draw.canvas) return null;
    for (var i = Draw.lines.length - 1; i >= 0; i--) {
      var ln = Draw.lines[i];
      if (!ln.infinite || ln.locked || !lineShown(ln)) continue;
      for (var j = 0; j < ln.points.length && j < 2; j++) {
        var c = lineCoord(ln.points[j]);
        if (!c) continue;
        var dx = x - c.x;
        var dy = y - c.y;
        if (dx * dx + dy * dy <= 144) return { line: ln, idx: j };
      }
    }
    return null;
  }

  var LINE_COLORS = ['#1E5AA8', '#7E1319', '#305C38', '#B08A2E', '#8E5A9E', '#1A1A1A'];

  /** 直线在当前周期是否可见（tfs 为空表示所有周期都显示）；设备不对的一律不显示。 */
  function lineShown(ln) {
    if (lineDev(ln) !== DRAW_DEV) return false;
    return !ln.tfs || !ln.tfs.length || ln.tfs.indexOf(state.iv) >= 0;
  }

  var LineDlg = { mode: '', line: null, idx: 0, sel: {} };

  function renderLineTfs() {
    var box = $('lineDlgTfs');
    if (!box) return;
    box.innerHTML = '';
    TF.forEach(function (iv) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'line-dlg__tf' + (LineDlg.sel[iv] ? ' is-on' : '');
      b.textContent = TF_LABEL[iv] || iv;
      b.setAttribute('data-tf', iv);
      b.onclick = function () {
        if (LineDlg.sel[iv]) delete LineDlg.sel[iv];
        else LineDlg.sel[iv] = 1;
        renderLineTfs();
      };
      box.appendChild(b);
    });
  }

  /** 直线的弹窗：mode='price' 输入价位；mode='tfs' 选可见周期。 */
  function openLineDlg(mode, line, idx) {
    var dlg = $('lineDlg');
    if (!dlg || !line) return;
    var pt = line.points[idx == null ? 0 : idx];
    if (!pt) return;
    LineDlg.mode = mode;
    LineDlg.line = line;
    LineDlg.idx = idx == null ? 0 : idx;
    var title = $('lineDlgTitle');
    var hint = $('lineDlgHint');
    var field = $('lineDlgField');
    var noteWrap = $('lineDlgNoteWrap');
    var noteInput = $('lineDlgNote');
    var tfs = $('lineDlgTfs');
    var quick = $('lineDlgQuick');
    if (mode === 'price') {
      if (title) title.textContent = '输入价位';
      if (hint) hint.textContent = '给直线第 ' + (LineDlg.idx + 1) + ' 个定点设置价位。设置后它会固定在这个价格上，平移、缩放都跟着走势走。';
      if (field) field.hidden = false;
      if (noteWrap) noteWrap.hidden = false;
      if (tfs) tfs.hidden = true;
      if (quick) quick.hidden = true;
      var input = $('lineDlgInput');
      if (input) input.value = fmtAxis(pt.p);
      if (noteInput) noteInput.value = pt.note || '';
    } else {
      if (title) title.textContent = '可见周期';
      if (hint) hint.textContent = '勾选的周期会显示这条直线，取消勾选的周期上不显示。';
      if (field) field.hidden = true;
      if (noteWrap) noteWrap.hidden = true;
      if (tfs) tfs.hidden = false;
      if (quick) quick.hidden = false;
      LineDlg.sel = {};
      // 默认只勾选「画线所在的周期」，其他周期浅色，可再勾选
      var vis = line.tfs && line.tfs.length ? line.tfs : [state.iv];
      vis.forEach(function (k) { LineDlg.sel[k] = 1; });
      renderLineTfs();
    }
    dlg.hidden = false;
    if (mode === 'price') {
      var inp = $('lineDlgInput');
      setTimeout(function () { try { inp.focus(); inp.select(); } catch (e) {} }, 30);
    }
  }

  function closeLineDlg() {
    var dlg = $('lineDlg');
    if (dlg) dlg.hidden = true;
    LineDlg.mode = '';
    LineDlg.line = null;
  }

  function confirmLineDlg() {
    var line = LineDlg.line;
    if (!line) { closeLineDlg(); return; }
    if (LineDlg.mode === 'price') {
      var pt = line.points[LineDlg.idx];
      if (!pt) { closeLineDlg(); return; }
      var input = $('lineDlgInput');
      var raw = input ? input.value : '';
      var price = parseFloat(String(raw).replace(/,/g, ''));
      if (!isFinite(price) || price <= 0) { toast('价格格式不对'); return; }
      pt.p = price;
      var noteEl = $('lineDlgNote');
      pt.note = noteEl && noteEl.value ? String(noteEl.value).trim().slice(0, 80) : '';
      saveDrawings();
      closeLineDlg();
      drawRedraw();
      toast('已把点 ' + (LineDlg.idx + 1) + ' 设到 ' + fmtAxis(price));
      return;
    }
    var sel = Object.keys(LineDlg.sel);
    line.tfs = sel.length >= TF.length ? null : sel;
    saveDrawings();
    closeLineDlg();
    drawRedraw();
    toast(sel.length ? '这条直线只在 ' + sel.length + ' 个周期显示' : '这条直线已全部隐藏');
  }

  /** 命中直线本体（右键菜单用），锁定的也算。 */
  function lineAtPoint(clientX, clientY) {
    if (!Draw.canvas) return null;
    var r = Draw.canvas.getBoundingClientRect();
    var x = clientX - r.left;
    var y = clientY - r.top;
    for (var i = Draw.lines.length - 1; i >= 0; i--) {
      var ln = Draw.lines[i];
      if (!ln.infinite || !ln.points.length || !lineShown(ln)) continue;
      var ca = lineCoord(ln.points[0]);
      var cb = lineCoord(ln.points[1] || ln.points[0]);
      if (!ca || !cb) continue;
      var dx = cb.x - ca.x;
      var dy = cb.y - ca.y;
      var len = Math.sqrt(dx * dx + dy * dy);
      if (!len) continue;
      var d = Math.abs(dy * x - dx * y + cb.x * ca.y - cb.y * ca.x) / len;
      if (d <= 8) return ln;
    }
    return null;
  }

  /** 直线的右键菜单：删除 / 锁定 / 输入价位 / 可见周期 / 颜色。 */
  function openLineCtx(x, y, line, idx) {
    if (!line) return;
    closeMenus();
    var menu = $('lineMenu');
    if (!menu) return;
    menu.innerHTML = '';
    var del = document.createElement('button');
    del.type = 'button';
    del.className = 'is-danger';
    del.textContent = '删除直线';
    del.onclick = function () {
      Draw.lines = Draw.lines.filter(function (ln) { return ln !== line; });
      Draw.undo = Draw.undo.filter(function (a) { return !(a.type === 'add' && a.line === line); });
      saveDrawings();
      closeMenus();
      drawRedraw();
      toast('已删除直线');
    };
    menu.appendChild(del);
    var lock = document.createElement('button');
    lock.type = 'button';
    lock.textContent = line.locked ? '解锁直线' : '锁定直线';
    lock.onclick = function () {
      line.locked = !line.locked;
      saveDrawings();
      closeMenus();
      drawRedraw();
      toast(line.locked ? '直线已锁定，不能拖动' : '直线已解锁');
    };
    menu.appendChild(lock);
    // 输入价位：默认取离右键位置最近的那个端点
    var targetIdx = idx;
    if (targetIdx == null && Draw.canvas) {
      var cr = Draw.canvas.getBoundingClientRect();
      var best = 0;
      var bestD = Infinity;
      line.points.forEach(function (pt, i) {
        var c = lineCoord(pt);
        if (!c) return;
        var dx = c.x + cr.left - x;
        var dy = c.y + cr.top - y;
        var d = dx * dx + dy * dy;
        if (d < bestD) { bestD = d; best = i; }
      });
      targetIdx = best;
    }
    var priceBtn = document.createElement('button');
    priceBtn.type = 'button';
    priceBtn.textContent = '输入价位';
    priceBtn.onclick = function () {
      closeMenus();
      promptLinePrice(line, targetIdx);
    };
    menu.appendChild(priceBtn);
    var tfBtn = document.createElement('button');
    tfBtn.type = 'button';
    tfBtn.textContent = '可见周期' + (line.tfs && line.tfs.length ? '（' + line.tfs.length + '）' : '');
    tfBtn.onclick = function () {
      closeMenus();
      openLineDlg('tfs', line, targetIdx);
    };
    menu.appendChild(tfBtn);
    ctxSep(menu);
    ctxLabel(menu, '颜色');
    var row = document.createElement('div');
    row.className = 'line-ctx__colors';
    var cur = normColor(line.color || '') || LINE_COLORS[0];
    LINE_COLORS.forEach(function (c) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'line-ctx__swatch' + (c === cur ? ' is-on' : '');
      b.style.background = c;
      b.title = c;
      b.onclick = function () {
        line.color = c;
        saveDrawings();
        closeMenus();
        drawRedraw();
      };
      row.appendChild(b);
    });
    menu.appendChild(row);
    menu.hidden = false;
    placeCtx(menu, x, y);
  }

  /** 端点上的价格标签。 */
  function drawPriceLabel(ctx, x, y, text, color) {
    var cw = Draw.canvas.clientWidth || 0;
    ctx.save();
    ctx.font = '600 11px ' + (getComputedStyle(document.body).fontFamily || 'sans-serif');
    var tw = ctx.measureText(text).width;
    var bx = Math.min(x + 9, cw - tw - 18);
    var by = Math.max(2, y - 22);
    ctx.fillStyle = 'rgba(255, 253, 246, 0.96)';
    ctx.strokeStyle = color;
    ctx.lineWidth = 1;
    if (ctx.roundRect) {
      ctx.beginPath();
      ctx.roundRect(bx, by, tw + 12, 18, 5);
      ctx.fill();
      ctx.stroke();
    } else {
      ctx.fillRect(bx, by, tw + 12, 18);
      ctx.strokeRect(bx, by, tw + 12, 18);
    }
    ctx.fillStyle = color;
    ctx.textBaseline = 'middle';
    ctx.fillText(text, bx + 6, by + 9.5);
    ctx.restore();
  }

  /** 测距时的十字虚线，方便对齐位置。 */
  function drawCrosshair(x, y, w, h) {
    var ctx = Draw.ctx;
    ctx.save();
    ctx.setLineDash([4, 5]);
    ctx.strokeStyle = 'rgba(36, 31, 22, .32)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, h);
    ctx.stroke();
    ctx.restore();
  }

  /** 测距端点上的价位小牌。 */
  function drawMeasureTag(x, y, text, color, above) {
    var ctx = Draw.ctx;
    if (!ctx) return;
    var cw = Draw.canvas.clientWidth || 0;
    var ch = Draw.canvas.clientHeight || 0;
    ctx.save();
    ctx.font = '600 11px ' + (getComputedStyle(document.body).fontFamily || 'sans-serif');
    var tw = ctx.measureText(text).width;
    var bw = tw + 12;
    var bh = 18;
    var bx = Math.max(3, Math.min(x - bw / 2, cw - bw - 3));
    var by = above ? y - bh - 7 : y + 7;
    if (by < 3) by = y + 7;
    if (by + bh > ch - 3) by = y - bh - 7;
    ctx.fillStyle = 'rgba(255, 253, 246, 0.96)';
    ctx.strokeStyle = color;
    ctx.lineWidth = 1;
    if (ctx.roundRect) {
      ctx.beginPath();
      ctx.roundRect(bx, by, bw, bh, 5);
      ctx.fill();
      ctx.stroke();
    } else {
      ctx.fillRect(bx, by, bw, bh);
      ctx.strokeRect(bx, by, bw, bh);
    }
    ctx.fillStyle = color;
    ctx.textBaseline = 'middle';
    ctx.fillText(text, bx + 6, by + bh / 2);
    ctx.restore();
  }

  function drawMeasure(m) {
    if (!m || !Draw.ctx || !Draw.canvas) return;
    var w = Draw.canvas.clientWidth || 0;
    var h = Draw.canvas.clientHeight || 0;
    if (!w || !h) return;
    var ts = Chart.chart ? Chart.chart.timeScale() : null;
    var x1 = m.t1 != null && ts ? ts.timeToCoordinate(m.t1) : m.u1 * w;
    var y1 = m.p1 != null && Chart.candle ? Chart.candle.priceToCoordinate(m.p1) : m.v1 * h;
    var x2 = m.t2 != null && ts ? ts.timeToCoordinate(m.t2) : m.u2 * w;
    var y2 = m.p2 != null && Chart.candle ? Chart.candle.priceToCoordinate(m.p2) : m.v2 * h;
    if (x1 == null || y1 == null || x2 == null || y2 == null) return;
    var pct = measurePct(m.p1, m.p2);
    var color = pct >= 0 ? DRAW_UP : DRAW_DOWN;
    var ctx = Draw.ctx;
    ctx.save();
    ctx.setLineDash([6, 4]);
    ctx.strokeStyle = 'rgba(255,255,255,.9)';
    ctx.lineWidth = 3.6;
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x2, y2);
    ctx.stroke();
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.4;
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x2, y2);
    ctx.stroke();
    ctx.setLineDash([]);
    drawDot(ctx, x1, y1, color, 3.2);
    drawDot(ctx, x2, y2, color, 3.2);
    // 两端显示价位，方便看测的是哪两个价格
    drawMeasureTag(x1, y1, fmtAxis(m.p1), color, true);
    drawMeasureTag(x2, y2, fmtAxis(m.p2), color, false);
    var label = (pct > 0 ? '+' : '') + pct.toFixed(2) + '%';
    ctx.font = '600 12px ' + (getComputedStyle(document.body).fontFamily || 'sans-serif');
    var tw = ctx.measureText(label).width;
    var bx = (x1 + x2) / 2 + 10;
    var by = (y1 + y2) / 2 - 12;
    bx = Math.max(4, Math.min(w - tw - 22, bx));
    by = Math.max(4, Math.min(h - 28, by));
    ctx.fillStyle = 'rgba(255, 253, 246, 0.96)';
    ctx.strokeStyle = color;
    ctx.lineWidth = 1;
    if (ctx.roundRect) {
      ctx.beginPath();
      ctx.roundRect(bx, by, tw + 16, 24, 6);
      ctx.fill();
      ctx.stroke();
    } else {
      ctx.fillRect(bx, by, tw + 16, 24);
      ctx.strokeRect(bx, by, tw + 16, 24);
    }
    ctx.fillStyle = color;
    ctx.textBaseline = 'middle';
    ctx.fillText(label, bx + 8, by + 12.5);
    ctx.restore();
  }

  /** 开平仓时间是毫秒时间戳，吸到最近的一根 K 线上，坐标才换得出来。 */
  function nearestBarTime(sec) {
    var arr = Ind.times;
    if (!arr.length) return 0;
    var lo = 0;
    var hi = arr.length - 1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (arr[mid] === sec) return sec;
      if (arr[mid] < sec) lo = mid + 1;
      else hi = mid - 1;
    }
    var a = arr[Math.max(0, lo - 1)];
    var b = arr[Math.min(arr.length - 1, lo)];
    return Math.abs(a - sec) <= Math.abs(b - sec) ? a : b;
  }

  function drawTradesOn(trips, flashing) {
    var ts = Chart.chart.timeScale();
    var pulse = flashing ? 7 + 2.5 * Math.sin(Date.now() / 80) : 3.6;
    trips.forEach(function (t, i) {
      if (!t || t.entry == null || !t.openAt) return;
      var t1 = nearestBarTime(t.openAt / 1000);
      var t2 = nearestBarTime(t.at / 1000);
      if (!t1 || !t2) return;
      var x1 = ts.timeToCoordinate(t1);
      var y1 = Chart.candle.priceToCoordinate(t.entry);
      var x2 = ts.timeToCoordinate(t2);
      var y2 = Chart.candle.priceToCoordinate(t.exit);
      if (x1 == null || y1 == null || x2 == null || y2 == null) return;
      var color = TRADE_COLOR;
      Draw.ctx.save();
      Draw.ctx.globalAlpha = flashing ? 0.85 : 0.45;
      Draw.ctx.strokeStyle = color;
      Draw.ctx.lineWidth = 1.2;
      Draw.ctx.beginPath();
      Draw.ctx.moveTo(x1, y1);
      Draw.ctx.lineTo(x2, y2);
      Draw.ctx.stroke();
      Draw.ctx.globalAlpha = 1;
      drawDot(Draw.ctx, x1, y1, color, pulse, flashing);
      drawDot(Draw.ctx, x2, y2, color, pulse, flashing);
      Draw.ctx.restore();
    });
  }

  function drawRedraw() {
    if (!Draw.ctx || !Draw.canvas || !Chart.chart) return;
    // 切周期清数据的那一瞬间不要碰图表坐标，等新数据回来再画
    if (!state.bars.length) return;
    var w = Draw.canvas.clientWidth || 0;
    var h = Draw.canvas.clientHeight || 0;
    Draw.ctx.clearRect(0, 0, w, h);
    var ts = Chart.chart.timeScale();
    var w = Draw.canvas.clientWidth || 0;
    var h = Draw.canvas.clientHeight || 0;
    Draw.lines.forEach(function (ln) {
      // 设备不对（电脑上画的线跑到手机上，或反过来）就直接跳过
      if (!lineShown(ln)) return;
      if (ln.infinite) {
        // 直线：存的是 (时间, 价格)，和走势图一起平移/缩放
        var ca = lineCoord(ln.points[0]);
        var cb = lineCoord(ln.points[1]);
        if (!ca || !cb) return;
        var lc = ln.color || '#1E5AA8';
        var ext = extendLine(ca.x, ca.y, cb.x, cb.y, w, h);
        if (ext) strokePath(Draw.ctx, [{ x: ext[0], y: ext[1] }, { x: ext[2], y: ext[3] }], lc);
        // 直线的两个定位点：拖动它们可以调整直线的位置和角度
        drawDot(Draw.ctx, ca.x, ca.y, lc, ln.locked ? 2.6 : 3.4);
        drawDot(Draw.ctx, cb.x, cb.y, lc, ln.locked ? 2.6 : 3.4);
        return;
      }
      var pts = [];
      ln.points.forEach(function (pt) {
        var x = null;
        var y = null;
        if (pt.t != null && pt.p != null && pt.dx != null) {
          x = ts.timeToCoordinate(pt.t);
          if (x != null) x += pt.dx;
          y = Chart.candle.priceToCoordinate(pt.p);
        } else if (pt.l != null && pt.p != null) {
          x = ts.logicalToCoordinate ? ts.logicalToCoordinate(pt.l) : null;
          if (x == null && pt.t != null) x = ts.timeToCoordinate(pt.t);
          y = Chart.candle.priceToCoordinate(pt.p);
        } else if (pt.t != null && pt.p != null) {
          x = ts.timeToCoordinate(pt.t);
          y = Chart.candle.priceToCoordinate(pt.p);
          if (x != null && ts.coordinateToLogical) pt.l = ts.coordinateToLogical(x);
        } else {
          x = pt.u != null ? pt.u * w : null;
          y = pt.v != null ? pt.v * h : null;
          // 旧版自由画存的是画布相对位置，换算成逻辑坐标后跟着 K 线走。
          if (x != null && y != null) {
            var pp = Chart.candle.coordinateToPrice(y);
            if (pp != null) {
              pt.p = pp;
              if (ts.coordinateToLogical) pt.l = ts.coordinateToLogical(x);
            }
          }
        }
        if (x == null || y == null) return;
        pts.push({ x: x, y: y });
      });
      if (pts.length > 1) strokePath(Draw.ctx, pts);
    });
    if (Draw.drawing && Draw.drawing.points.length > 1 && Draw.tool !== 'measure') {
      strokePath(Draw.ctx, Draw.drawing.points);
    }
    // 直线的第一个点已定：预览一条穿过起点和鼠标的无限直线
    if (Draw.pending) {
      var pa = lineCoord(Draw.pending);
      if (pa) {
        var pb = Draw.hover ? lineCoord(Draw.hover) : null;
        if (pb) {
          var pext = extendLine(pa.x, pa.y, pb.x, pb.y, w, h);
          if (pext) strokePath(Draw.ctx, [{ x: pext[0], y: pext[1] }, { x: pext[2], y: pext[3] }]);
        }
        drawDot(Draw.ctx, pa.x, pa.y, '#1E5AA8', 3.4);
        if (pb && (pb.x !== pa.x || pb.y !== pa.y)) drawCrosshair(pb.x, pb.y, w, h);
      }
    }
    if (Draw.measure) drawMeasure(Draw.measure);
    if (Draw.drawing && Draw.tool === 'measure') {
      var mc = Draw.drawing.points[Draw.drawing.points.length - 1];
      drawCrosshair(mc.x, mc.y, w, h);
      if (Draw.drawing.points.length > 1) {
        var ma = Draw.drawing.points[0];
        drawMeasure({ u1: ma.u, v1: ma.v, p1: ma.p, u2: mc.u, v2: mc.v, p2: mc.p });
      }
    }
    if (Draw.showTrades && Draw.trades.length && isTradingSymbol()) drawTradesOn(Draw.trades, false);
    if (Draw.flash) drawTradesOn([Draw.flash.trip], true);
    syncHandles();
  }

  function drawSchedule() {
    if (!Draw.ctx || Draw.raf) return;
    var raf = window.requestAnimationFrame || function (fn) { return setTimeout(fn, 16); };
    Draw.raf = raf(function () {
      Draw.raf = 0;
      drawRedraw();
    });
  }

  function drawResize() {
    if (!Draw.canvas || !Draw.ctx) return;
    var dpr = window.devicePixelRatio || 1;
    var w = Draw.canvas.clientWidth || 0;
    var h = Draw.canvas.clientHeight || 0;
    if (!w || !h) return;
    var cw = Math.round(w * dpr);
    var ch = Math.round(h * dpr);
    if (Draw.canvas.width !== cw || Draw.canvas.height !== ch) {
      Draw.canvas.width = cw;
      Draw.canvas.height = ch;
    }
    Draw.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    drawRedraw();
  }

  function setDrawActive(on, tool) {
    Draw.active = !!on;
    if (tool) Draw.tool = tool;
    if (!on) {
      Draw.drawing = null;
      Draw.drag = null;
      Draw.pending = null;
      Draw.hover = null;
    }
    var map = { btnDraw: 'free', btnLine: 'line', btnMeasure: 'measure' };
    Object.keys(map).forEach(function (id) {
      var b = $(id);
      var now = Draw.active && Draw.tool === map[id];
      if (b) {
        b.classList.toggle('is-active', now);
        b.setAttribute('aria-pressed', now ? 'true' : 'false');
      }
    });
    var pane = document.querySelector ? document.querySelector('.pane--main') : null;
    if (pane) pane.classList.toggle('is-drawing', Draw.active);
    if (!Draw.active && Draw.canvas) Draw.canvas.style.cursor = '';
    if (Chart.ready) drawRedraw();
  }

  function setHistActive(on) {
    Draw.showTrades = !!on;
    var btn = $('btnHist');
    if (btn) {
      btn.classList.toggle('is-active', Draw.showTrades);
      btn.setAttribute('aria-pressed', Draw.showTrades ? 'true' : 'false');
    }
    if (Draw.showTrades) Draw.trades = roundTrips();
    drawRedraw();
  }

  /** 把当前 chartwrap 里所有可见 canvas 合成为一张截图（K 线、坐标轴、画线、交易点都在）。 */
  function captureChartCanvas() {
    var wrap = document.querySelector ? document.querySelector('.chartwrap') : null;
    if (!wrap) return null;
    var rect = wrap.getBoundingClientRect();
    if (!rect.width || !rect.height) return null;
    var dpr = Math.min(2, +(global.devicePixelRatio || 1));
    var out = document.createElement('canvas');
    out.width = Math.max(1, Math.round(rect.width * dpr));
    out.height = Math.max(1, Math.round(rect.height * dpr));
    var ctx = out.getContext('2d');
    if (!ctx) return null;
    ctx.fillStyle = '#F4ECD9';
    ctx.fillRect(0, 0, out.width, out.height);

    var canvases = wrap.querySelectorAll('canvas');
    for (var i = 0; i < canvases.length; i += 1) {
      var c = canvases[i];
      var cs = null;
      try { cs = global.getComputedStyle(c); } catch (e) {}
      if (cs && (cs.display === 'none' || cs.visibility === 'hidden' || +cs.opacity === 0)) continue;
      var cr = c.getBoundingClientRect();
      if (!cr.width || !cr.height) continue;
      try {
        ctx.drawImage(
          c,
          (cr.left - rect.left) * dpr,
          (cr.top - rect.top) * dpr,
          cr.width * dpr,
          cr.height * dpr
        );
      } catch (e) {}
    }
    return out;
  }

  function screenshotChart() {
    var btn = $('btnShot');
    var canvas = captureChartCanvas();
    if (!canvas) {
      toast('走势图还没准备好，稍后再试');
      return;
    }
    if (btn) btn.disabled = true;
    function finish() {
      if (btn) btn.disabled = false;
    }
    function download(blob) {
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a');
      a.href = url;
      a.download = 'chart-' + Date.now() + '.png';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 30000);
      toast('浏览器不支持复制图片，截图已下载');
      finish();
    }
    canvas.toBlob(function (blob) {
      if (!blob) {
        toast('截图生成失败，请重试');
        finish();
        return;
      }
      if (global.navigator && global.navigator.clipboard &&
          global.navigator.clipboard.write && global.ClipboardItem) {
        try {
          var item = new global.ClipboardItem({ 'image/png': blob });
          global.navigator.clipboard.write([item]).then(function () {
            toast('截图已复制，按 Ctrl+V 粘贴到交易笔记');
            finish();
          }, function () {
            download(blob);
          });
          return;
        } catch (e) {}
      }
      download(blob);
    }, 'image/png');
  }

  /** 点成交记录某一行：把那一笔的开/平仓点在图上闪一下。 */
  function flashTrade(trip) {
    if (!trip) return;
    Draw.flash = { trip: trip, until: Date.now() + 2400 };
    if (Draw.flashTimer) return;
    Draw.flashTimer = setInterval(function () {
      if (!Draw.flash || Date.now() > Draw.flash.until) {
        clearInterval(Draw.flashTimer);
        Draw.flashTimer = 0;
        Draw.flash = null;
      }
      drawRedraw();
    }, 60);
  }

  function onDrawDown(e) {
    if (!Draw.active || !Draw.ctx) return;
    if (e.button != null && e.button > 0) return; // 右键留给直线菜单
    var pt = Draw.tool === 'measure' ? drawMeasurePoint(e) : drawPoint(e);
    if (!pt) return;
    // 直线：两点式。第一次点确定起点并实时预览，第二次点定下直线；
    // 端点随时可以拖（先判断是不是抓住了已有直线的端点）。
    if (Draw.tool === 'line') {
      var r = Draw.canvas.getBoundingClientRect();
      var hit = lineHandleAt(e.clientX - r.left, e.clientY - r.top);
      if (hit) {
        e.preventDefault();
        Draw.drag = hit;
        if (Draw.canvas.setPointerCapture) {
          try { Draw.canvas.setPointerCapture(e.pointerId); } catch (err) {}
        }
        return;
      }
      e.preventDefault();
      if (!Draw.pending) {
        Draw.pending = { t: pt.t, p: pt.p };
        Draw.hover = { t: pt.t, p: pt.p };
        drawRedraw();
        return;
      }
      var pa = lineCoord(Draw.pending);
      if (pa && (Math.abs(pa.x - pt.x) + Math.abs(pa.y - pt.y) >= 4)) {
        var seg = { points: [{ t: Draw.pending.t, p: Draw.pending.p }, { t: pt.t, p: pt.p }], infinite: true, tfs: [state.iv], dev: DRAW_DEV };
        Draw.lines.push(seg);
        Draw.undo.push({ type: 'add', line: seg });
        if (Draw.undo.length > 200) Draw.undo.shift();
        saveDrawings();
      }
      Draw.pending = null;
      Draw.hover = null;
      // 画完两个点自动退出工具，鼠标恢复正常；端点热区仍然可以拖
      setDrawActive(false);
      drawRedraw();
      return;
    }
    e.preventDefault();
    Draw.drawing = { points: [pt] };
    if (Draw.canvas.setPointerCapture) {
      try { Draw.canvas.setPointerCapture(e.pointerId); } catch (err) {}
    }
    drawRedraw();
  }

  function onDrawMove(e) {
    if (Draw.active && Draw.tool === 'line' && Draw.canvas) {
      var hr = Draw.canvas.getBoundingClientRect();
      Draw.canvas.style.cursor = lineHandleAt(e.clientX - hr.left, e.clientY - hr.top) ? 'default' : 'crosshair';
    }
    if (Draw.pending) {
      var hpt = drawPoint(e);
      if (!hpt) return;
      Draw.hover = { t: hpt.t, p: hpt.p };
      drawRedraw();
      return;
    }
    if (Draw.drag) {
      var dpt = drawPoint(e);
      if (!dpt) return;
      var handle = Draw.drag.line.points[Draw.drag.idx];
      handle.t = dpt.t;
      handle.p = dpt.p;
      drawRedraw();
      return;
    }
    if (!Draw.drawing) return;
    var pt = Draw.tool === 'measure' ? drawMeasurePoint(e) : drawPoint(e);
    if (!pt) return;
    var pts = Draw.drawing.points;
    if (Draw.tool !== 'free' || e.shiftKey) {
      // 直线 / 测距 / Shift 自由画：只留起点和当前点
      Draw.drawing.points = [pts[0], pt];
    } else {
      var last = pts[pts.length - 1];
      var dx = pt.x - last.x;
      var dy = pt.y - last.y;
      if (dx * dx + dy * dy >= 4) pts.push(pt);
    }
    drawRedraw();
  }

  function onDrawUp(e) {
    if (Draw.drag) {
      Draw.drag = null;
      saveDrawings();
      drawRedraw();
      return;
    }
    if (!Draw.drawing) return;
    var pts = Draw.drawing.points;
    var first = pts[0];
    var last = pts[pts.length - 1];
    var pt = (Draw.tool === 'measure' ? drawMeasurePoint(e) : drawPoint(e)) || last;
    var moved = (Math.abs(pt.x - first.x) + Math.abs(pt.y - first.y)) >= 4;

    // 直线：按下拖到终点，松手成一条两点直线（渲染时延长到整块画布）
    if (Draw.tool === 'line') {
      Draw.drawing = null;
      if (moved) {
        var seg = { points: [{ t: first.t, p: first.p }, { t: pt.t, p: pt.p }], infinite: true, dev: DRAW_DEV };
        Draw.lines.push(seg);
        Draw.undo.push({ type: 'add', line: seg });
        if (Draw.undo.length > 200) Draw.undo.shift();
      }
      setDrawActive(false);
      drawRedraw();
      return;
    }

    // 测距：松手后保留这条测距线，显示两点之间的涨跌幅
    if (Draw.tool === 'measure') {
      Draw.drawing = null;
      if (moved) {
        Draw.measure = { t1: first.t, t2: pt.t, u1: first.u, v1: first.v, p1: first.p, u2: pt.u, v2: pt.v, p2: pt.p };
      }
      setDrawActive(false);
      drawRedraw();
      return;
    }

    if (e.shiftKey) {
      pts = [first, pt];
    } else if (pt.x !== last.x || pt.y !== last.y) {
      pts.push(pt);
    }
    Draw.drawing = null;

    var minX = Infinity;
    var maxX = -Infinity;
    var minY = Infinity;
    var maxY = -Infinity;
    pts.forEach(function (p) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    });

    if (pts.length >= 2 && (maxX - minX) + (maxY - minY) >= 4) {
      var line = {
        points: pts.map(function (p) {
          return { t: p.t, p: p.p, dx: p.dx, l: p.l, u: p.u, v: p.v };
        }),
        dev: DRAW_DEV
      };
      Draw.lines.push(line);
      Draw.undo.push({ type: 'add', line: line });
      if (Draw.undo.length > 200) Draw.undo.shift();
      saveDrawings();
      setDrawActive(false); // 画完一笔自动退出，下一次要重新点
    }
    drawRedraw();
  }

  function onDrawCancel() {
    if (!Draw.drawing) return;
    Draw.drawing = null;
    drawRedraw();
  }

  /** 给某个端点输入价位（走页面内弹窗，不再用系统 prompt）。 */
  function promptLinePrice(line, idx) {
    openLineDlg('price', line, idx);
  }

  function bindLineDlg() {
    var dlg = $('lineDlg');
    if (!dlg) return;
    var cancel = $('lineDlgCancel');
    if (cancel) cancel.addEventListener('click', closeLineDlg);
    var ok = $('lineDlgOk');
    if (ok) ok.addEventListener('click', confirmLineDlg);
    dlg.addEventListener('click', function (e) {
      if (e.target === dlg) closeLineDlg();
    });
    var input = $('lineDlgInput');
    if (input) {
      input.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); confirmLineDlg(); }
      });
    }
    var quick = $('lineDlgQuick');
    if (quick) {
      quick.addEventListener('click', function (e) {
        var b = e.target && e.target.closest ? e.target.closest('[data-tfq]') : null;
        if (!b) return;
        var q = b.getAttribute('data-tfq');
        LineDlg.sel = {};
        if (q === 'all') TF.forEach(function (k) { LineDlg.sel[k] = 1; });
        else LineDlg.sel[state.iv] = 1;
        renderLineTfs();
      });
    }
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !dlg.hidden) closeLineDlg();
    });
  }

  /** 端点热区：按下就拖，右键出直线菜单。 */
  function onHandleDown(e) {
    var el = e.currentTarget;
    var line = el && el._line;
    if (!line || line.locked) return;
    if (e.button != null && e.button > 0) return;
    e.preventDefault();
    e.stopPropagation();
    Draw.drag = { line: line, idx: el._idx };
    if (el.setPointerCapture) {
      try { el.setPointerCapture(e.pointerId); } catch (err) {}
    }
  }

  function onHandleCtx(e) {
    var el = e.currentTarget;
    if (!el || !el._line) return;
    e.preventDefault();
    e.stopPropagation();
    openLineCtx(e.clientX, e.clientY, el._line, el._idx);
  }

  /** 把直线的两个端点同步成 DOM 热区（这样工具没激活也能悬停/拖动）。 */
  function syncHandles() {
    var layer = $('lineHandles');
    if (!layer) return;
    var items = [];
    Draw.lines.forEach(function (ln) {
      if (!ln.infinite || !lineShown(ln)) return;
      ln.points.forEach(function (pt, idx) {
        items.push({ ln: ln, idx: idx, c: lineCoord(pt) });
      });
    });
    while (layer.children.length < items.length) {
      var d = document.createElement('div');
      d.className = 'line-handle';
      d.addEventListener('pointerdown', onHandleDown);
      d.addEventListener('contextmenu', onHandleCtx);
      layer.appendChild(d);
    }
    while (layer.children.length > items.length) layer.removeChild(layer.lastChild);
    items.forEach(function (it, i) {
      var el = layer.children[i];
      el._line = it.ln;
      el._idx = it.idx;
      el.classList.toggle('is-locked', !!it.ln.locked);
      el.style.display = it.c ? 'block' : 'none';
      if (it.c) {
        el.style.left = (it.c.x - 9) + 'px';
        el.style.top = (it.c.y - 9) + 'px';
      }
    });
  }

  /** 画线层上的右键：命中直线就开直线菜单。 */
  function onCanvasCtx(e) {
    if (!Draw.canvas) return;
    e.preventDefault();
    var ln = lineAtPoint(e.clientX, e.clientY);
    if (ln) openLineCtx(e.clientX, e.clientY, ln);
    else closeMenus();
  }

  function eraseDrawings() {
    // 只擦当前这台设备上的画线，另一台设备的原样留着
    var mine = Draw.lines.filter(function (ln) { return lineDev(ln) === DRAW_DEV; });
    var free = mine.filter(function (ln) { return !ln.infinite; });
    if (!free.length && !Draw.measure) {
      if (mine.length) toast('直线请右键删除');
      else toast('还没有画线');
      return;
    }
    if (free.length) Draw.undo.push({ type: 'clear', lines: free });
    Draw.lines = Draw.lines.filter(function (ln) {
      return ln.infinite || lineDev(ln) !== DRAW_DEV;
    });
    Draw.measure = null;
    saveDrawings();
    drawRedraw();
    toast('已擦除自由画线');
  }

  function undoDrawings() {
    var act = Draw.undo.pop();
    if (!act) {
      toast('没有可撤销的操作');
      return;
    }
    if (act.type === 'add') {
      var i = Draw.lines.indexOf(act.line);
      if (i >= 0) Draw.lines.splice(i, 1);
    } else if (act.type === 'clear') {
      // 只把擦掉的这些补回来，别把另一台设备的画线覆盖掉
      act.lines.forEach(function (ln) {
        if (Draw.lines.indexOf(ln) < 0) Draw.lines.push(ln);
      });
    }
    saveDrawings();
    drawRedraw();
  }

  function onDrawKey(e) {
    var tag = (document.activeElement && document.activeElement.tagName) || '';
    if (/INPUT|TEXTAREA|SELECT/.test(tag)) return;
    if ((e.ctrlKey || e.metaKey) && (e.key === 'z' || e.key === 'Z')) {
      if (!Draw.undo.length && !Draw.lines.length) return;
      e.preventDefault();
      undoDrawings();
      return;
    }
    if (e.key === 'Escape') setDrawActive(false);
  }

  /** 点画布别处 / 页面其他区域，测距自动消失（不必点橡皮擦）。 */
  function onDocPointerDown() {
    if (!Draw.measure) return;
    Draw.measure = null;
    drawRedraw();
  }

  function drawInit() {
    Draw.canvas = $('drawLayer');
    if (!Draw.canvas || !Chart.chart || typeof Draw.canvas.getContext !== 'function') return;
    Draw.ctx = Draw.canvas.getContext('2d');
    if (!Draw.ctx) return;
    drawResize();
    if (window.ResizeObserver) {
      try {
        new ResizeObserver(function () { drawResize(); }).observe($('chart'));
      } catch (e) {}
    }
    window.addEventListener('resize', drawResize);
    Draw.canvas.addEventListener('pointerdown', onDrawDown);
    Draw.canvas.addEventListener('contextmenu', onCanvasCtx);
    window.addEventListener('pointermove', onDrawMove);
    window.addEventListener('pointerup', onDrawUp);
    window.addEventListener('pointercancel', onDrawCancel);
    document.addEventListener('keydown', onDrawKey);
    document.addEventListener('pointerdown', onDocPointerDown, true);
  }

  function showMsg(text) {
    var m = $('chartMsg');
    if (!m) return;
    m.textContent = text;
    m.hidden = false;
  }
  function hideMsg() {
    var m = $('chartMsg');
    if (m) m.hidden = true;
  }

  function showLegend(bar) {
    if (!bar) return;
    var up = bar.close >= bar.open;
    var cls = up ? 'is-up' : 'is-down';
    // 顶部图例不再显示开高低收，只留涨跌幅和成交量
    set('lgChg', fmtPct(bar.open ? (bar.close - bar.open) / bar.open * 100 : 0), cls);
    set('lgV', fmtQty(bar.volume), '');
    function set(id, text, cls) {
      var e = $(id);
      if (!e) return;
      e.textContent = text;
      e.className = cls;
    }
    // 均线 / MACD 的数值跟着同一个时间点走，悬停和最新一根都走这里
    showInd(indexOfTime(bar.time));
  }

  function volColor(bar) {
    return bar.close >= bar.open ? UP_SOFT : DOWN_SOFT;
  }

  function chartInit() {
    var box = $('chart');
    if (!box) return;
    if (typeof LightweightCharts === 'undefined') {
      showMsg('图表组件加载失败，请刷新重试。行情数据仍然可用。');
      return;
    }
    // 手机：右侧那 78px 透明价格轴纯属留白，直接收掉，K 线一直画到屏幕右边；
    // 上下压扁/拉伸改由右边缘长按拖动接手（见 bindScaleStrip）。
    var mobileChart = DRAW_DEV === 'm';
    var rightOffset = mobileChart ? 4 : RIGHT_OFFSET;
    var fontFamily = getComputedStyle(document.body).fontFamily;
    var tickFmt = function (time, type) {
      var d = new Date(time * 1000);
      if (state.iv === '1M') return type === 0 ? String(d.getFullYear()) : (d.getFullYear() % 100) + '/' + (d.getMonth() + 1);
      // type：0 年 / 1 月 / 2 日 / 3 时 / 4 时分秒。日线以上只给日期，长区间才看得清
      if (type === 0) return String(d.getFullYear());
      if (type === 1 || type === 2) return (d.getMonth() + 1) + '/' + d.getDate();
      return pad(d.getHours()) + ':' + pad(d.getMinutes());
    };
    // 十字线的时间标签：月线只到年月，3/5 日线和周线只到月日
    var crossTime = function (t) {
      var d = new Date(t * 1000);
      if (state.iv === '1M') return d.getFullYear() + '/' + (d.getMonth() + 1);
      if (state.iv === '1w' || state.iv === '3d' || state.iv === '5d') {
        return (d.getMonth() + 1) + '/' + d.getDate();
      }
      return fmtDateTime(t * 1000);
    };

    try {
      Chart.chart = LightweightCharts.createChart(box, {
        autoSize: true,
        layout: {
          // 画布透明，底色交给 #chart 容器的渐变：
          // 已经走出 K 线的区域 #EEE7D4，右侧还没走势的空区用页面底 #F4ECD9。
          background: { type: 'solid', color: 'rgba(238, 231, 212, 0)' },
          textColor: '#6B6250',
          fontSize: 12,
          fontFamily: fontFamily,
          attributionLogo: false
        },
        // 横向网格线由页面自己画（见 drawPriceAxis），这样刻度疏密可控
        grid: {
          vertLines: { color: 'rgba(0, 0, 0, 0)' },
          horzLines: { color: 'rgba(0, 0, 0, 0)' }
        },
        // 右侧价格轴：桌面留出宽度（当上下拖拽的压扁/拉伸区），
        // 刻度数字由 drawPriceAxis 画，库自带的刻度关掉（太密）。
        // 手机不占宽度（右边缘长按那条手势带负责压扁）。
        rightPriceScale: {
          visible: !mobileChart,
          borderVisible: false,
          ticksVisible: false,
          textColor: mobileChart ? 'rgba(0,0,0,0)' : 'rgba(0,0,0,0)',
          entireTextOnly: true,
          alignLabels: true,
          minimumWidth: mobileChart ? 0 : 70,
          scaleMargins: { top: 0.08, bottom: 0.26 }
        },
        timeScale: {
          borderColor: '#E1D5B9',
          timeVisible: true,
          secondsVisible: false,
          rightOffset: rightOffset,
          // 有副图时时间轴只画在副图上，两个图共用一条
          visible: !Ind.macd,
          tickMarkFormatter: tickFmt
        },
        crosshair: {
          // Normal：十字线严格跟着鼠标，横纵交点就在指针上；Magnet 会把横线吸到收盘价
          mode: (LightweightCharts.CrosshairMode && LightweightCharts.CrosshairMode.Normal) || 0,
          vertLine: { color: '#B8B8B8', width: 1, style: 3, labelBackgroundColor: '#1C1C1C' },
          // 横线价格标签由页面自己画（#hoverTag），关掉库自带标签，避免灰色标签外再套一层黑色
          horzLine: { color: '#B8B8B8', width: 1, style: 3, labelVisible: false }
        },
        localization: {
          locale: 'zh-CN',
          priceFormatter: function (p) { return fmtAxis(p); },
          // 图表库传进来的是秒；月/周线只显示到月或日
          timeFormatter: crossTime
        },
        // 右侧价格轴上下拖拽可以压扁/拉伸走势（时间轴拖拽不开）
        handleScroll: { mouseWheel: true, pressedMouseMove: true, horzTouchDrag: true, vertTouchDrag: false },
        handleScale: { axisPressedMouseMove: { time: false, price: true }, mouseWheel: true, pinch: true }
      });

      Chart.candle = Chart.chart.addCandlestickSeries({
        upColor: UP,
        downColor: DOWN,
        borderUpColor: UP,
        borderDownColor: DOWN,
        wickUpColor: UP,
        wickDownColor: DOWN,
        // 当前实时价：一条虚线横穿图表；价格标签用页面自定义的 #priceTag，别让库再画一个
        priceLineVisible: true,
        priceLineWidth: 1,
        priceLineStyle: (LightweightCharts.LineStyle && LightweightCharts.LineStyle.Dashed) || 2,
        priceLineColor: '#8A7F68',
        lastValueVisible: false
      });

      Chart.vol = Chart.chart.addHistogramSeries({
        priceFormat: { type: 'volume' },
        priceScaleId: '',
        priceLineVisible: false,
        lastValueVisible: false,
        visible: !!Ind.vol
      });
      Chart.chart.priceScale('').applyOptions({ scaleMargins: { top: 0.76, bottom: 0 } });

      // 主图均线：按当前列表建 series，增删改走 syncMaSeries()
      Ind.ma.forEach(function (m) {
        Chart.ma[m.p] = Chart.chart.addLineSeries({
          color: m.c,
          lineWidth: 1,
          priceLineVisible: false,
          lastValueVisible: false,
          crosshairMarkerVisible: false,
          visible: !m.hidden
        });
      });
    } catch (e) {
      showMsg('图表初始化失败：' + (e && e.message));
      return;
    }

    // 副图 MACD：单独一个 chart 实例，主图把时间轴让给它。
    // 建失败也不影响主图，只是没有副图。
    try {
      Chart.macd = LightweightCharts.createChart($('chartMacd'), {
        autoSize: true,
        layout: {
          background: { type: 'solid', color: 'rgba(238, 231, 212, 0)' },
          textColor: '#6B6250',
          fontSize: 12,
          fontFamily: fontFamily,
          // 主图左下角已经有一个 TradingView 标识，副图不再重复
          attributionLogo: false
        },
        grid: {
          vertLines: { color: 'rgba(0, 0, 0, 0)' },
          horzLines: { color: '#EADFC7', style: (LightweightCharts.LineStyle && LightweightCharts.LineStyle.Dashed) || 2 }
        },
        rightPriceScale: {
          visible: !mobileChart,
          borderVisible: false,
          ticksVisible: false,
          textColor: 'rgba(0,0,0,0)',
          scaleMargins: { top: 0.16, bottom: 0.12 }
        },
        timeScale: {
          borderColor: '#E1D5B9',
          timeVisible: true,
          secondsVisible: false,
          rightOffset: rightOffset,
          tickMarkFormatter: tickFmt
        },
        crosshair: {
          // 和主图一样用 Normal，副图的纵线才不会跳格；横线不画
          mode: (LightweightCharts.CrosshairMode && LightweightCharts.CrosshairMode.Normal) || 0,
          // 副图不显示横向价格线，只借它的竖向准星和时间标签
          vertLine: { color: '#B8B8B8', width: 1, style: 3, labelBackgroundColor: '#1C1C1C' },
          horzLine: { visible: false, labelVisible: false }
        },
        localization: {
          locale: 'zh-CN',
          priceFormatter: function (p) { return fmtAxis(p); },
          timeFormatter: crossTime
        },
        // 副图同样支持右侧价格轴上下拖拽缩放
        handleScroll: { mouseWheel: true, pressedMouseMove: true, horzTouchDrag: true, vertTouchDrag: false },
        handleScale: { axisPressedMouseMove: { time: false, price: true }, mouseWheel: true, pinch: true }
      });

      Chart.hist = Chart.macd.addHistogramSeries({
        priceFormat: { type: 'price', precision: 2, minMove: 0.01 },
        priceLineVisible: false,
        lastValueVisible: false,
        // 让 0 轴始终在可见范围内，柱子才有正负的分界
        autoscaleInfoProvider: function (original) {
          var r = original();
          if (!r || !r.priceRange) return r;
          r.priceRange.minValue = Math.min(r.priceRange.minValue, 0);
          r.priceRange.maxValue = Math.max(r.priceRange.maxValue, 0);
          return r;
        }
      });
      try {
        Chart.hist.createPriceLine({
          price: 0,
          color: '#C9BFA6',
          lineWidth: 1,
          lineStyle: (LightweightCharts.LineStyle && LightweightCharts.LineStyle.Dashed) || 2,
          axisLabelVisible: false,
          title: ''
        });
      } catch (e) {}

      Chart.dif = Chart.macd.addLineSeries({
        color: DIF_COLOR, lineWidth: 1,
        priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false
      });
      Chart.dea = Chart.macd.addLineSeries({
        color: DEA_COLOR, lineWidth: 1,
        priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false
      });
    } catch (e) {
      Chart.macd = null;
      Chart.hist = null;
      Chart.dif = null;
      Chart.dea = null;
    }

    // 十字线联动：主图 ↔ 副图，同一根 K 线两边同时对齐
    Chart.chart.subscribeCrosshairMove(function (param) {
      if (Ind.syncing) return;
      if (!Cross.re) Cross.on = !!(param && param.point);
      handleCrosshair(param, true);
      mirrorCrosshair(Chart.macd, param && param.time, 0, Chart.dif);
    });
    // 记录鼠标真实像素位置：滚轮缩放时用它把十字线钉回光标处（capture 先于图表库的监听）
    if (Chart.chart) {
      var pane = document.querySelector ? document.querySelector('.pane--main') : null;
      if (pane && pane.addEventListener) {
        pane.addEventListener('mousemove', function (e) {
          if (!Draw.canvas) return;
          var r = Draw.canvas.getBoundingClientRect();
          Cross.mx = e.clientX - r.left;
          Cross.my = e.clientY - r.top;
        }, true);
        pane.addEventListener('mouseleave', function () { Cross.on = false; });
      }
    }
    if (Chart.macd) {
      Chart.macd.subscribeCrosshairMove(function (param) {
        if (Ind.syncing) return;
        handleCrosshair(param, false);
        // 不再把副图时间反写回主图：反写时只能拿到收盘价，会导致主图横线
        // 在拖动过程中先吸到 K 线又弹回鼠标，表现为横线来回跳。
      });
    }

    linkCharts();
    applyChartTimeFormat(state.iv);

    Chart.ready = true;
    // 分界线（已走 / 未走区域）要跟着最后一根 K 线走
    var scaleApi = Chart.chart.timeScale();
    if (scaleApi && typeof scaleApi.subscribeVisibleLogicalRangeChange === 'function') {
      scaleApi.subscribeVisibleLogicalRangeChange(paintChartBg);
      // 走势图左右平移/缩放时，画线层必须按新的时间坐标重画，否则线会停在原地
      scaleApi.subscribeVisibleLogicalRangeChange(function () {
        if (Chart.ready && !Chart.clearing) drawRedraw();
      });
      // 滚轮缩放/平移后，等图表这一帧画完，再把十字线钉回鼠标像素位置
      scaleApi.subscribeVisibleLogicalRangeChange(function () {
        if (!Cross.on) return;
        if (Cross.timer) clearTimeout(Cross.timer);
        Cross.timer = setTimeout(function () {
          Cross.timer = 0;
          crosshairReanchor();
        }, 30);
      });
    }

    setMacdVisible(Ind.macd, false);
    applyChartMargins();
    drawInit();
    paintChartBg();
  }

  function applyTimeAxis() {
    if (!Chart.chart) return;
    var withMacd = !!(Chart.macd && Ind.macd);
    try {
      Chart.chart.applyOptions({ timeScale: { visible: !withMacd } });
    } catch (e) {}
  }

  /**
   * 时间轴/十字线的格式跟周期绑定。图表库会按时间点缓存刻度文字，
   * 只在初始化时塞一个读 state.iv 的闭包，切到周/月线时会留下旧格式，
   * 所以每次换周期都重新 apply 一个新的 formatter。
   */
  function applyChartTimeFormat(iv) {
    if (!Chart.chart) return;
    var tick = function (time, type) {
      var d = new Date(time * 1000);
      if (iv === '1M') return type === 0 ? String(d.getFullYear()) : (d.getFullYear() % 100) + '/' + (d.getMonth() + 1);
      if (type === 0) return String(d.getFullYear());
      if (type === 1 || type === 2) return (d.getMonth() + 1) + '/' + d.getDate();
      return pad(d.getHours()) + ':' + pad(d.getMinutes());
    };
    var cross = function (t) {
      var d = new Date(t * 1000);
      if (iv === '1M') return d.getFullYear() + '/' + (d.getMonth() + 1);
      if (iv === '1w' || iv === '3d' || iv === '5d') return (d.getMonth() + 1) + '/' + d.getDate();
      return fmtDateTime(t * 1000);
    };
    try {
      Chart.chart.applyOptions({ timeScale: { tickMarkFormatter: tick }, localization: { timeFormatter: cross } });
    } catch (e) {}
    if (Chart.macd) {
      try {
        Chart.macd.applyOptions({ timeScale: { tickMarkFormatter: tick }, localization: { timeFormatter: cross } });
      } catch (e) {}
    }
  }

  function handleCrosshair(param, onMain) {
    updateHoverTag(param, !!onMain);
    if (!param || !param.time || !param.seriesData) {
      Chart.hover = null;
      var last = state.bars[state.bars.length - 1];
      if (last) showLegend(last);
      return;
    }
    var d = param.seriesData.get(Chart.candle);
    if (d && d.open != null) {
      Chart.hover = d;
      showLegend({ time: d.time, open: d.open, high: d.high, low: d.low, close: d.close, volume: 0 });
      var vd = param.seriesData.get(Chart.vol);
      var lg = $('lgV');
      if (lg && vd) lg.textContent = fmtQty(vd.value);
      return;
    }
    // 悬停在副图上：主图没有蜡烛数据，按时间找那一根
    var i = indexOfTime(param.time);
    if (i >= 0) {
      Chart.hover = state.bars[i];
      showLegend(state.bars[i]);
    }
  }

  /** 把一边的十字线放到另一边；Ind.syncing 防止两边互相回调成死循环。 */
  function mirrorCrosshair(target, time, price, series) {
    if (!Ind.macd || !target || !series) return;
    Ind.syncing = true;
    try {
      if (time == null) target.clearCrosshairPosition();
      else target.setCrosshairPosition(price || 0, time, series);
    } catch (e) {}
    Ind.syncing = false;
  }

  function linkCharts() {
    if (!Chart.chart || !Chart.macd) return;
    var lock = false;
    function mirror(src, dst) {
      if (!src || !dst || typeof src.subscribeVisibleLogicalRangeChange !== 'function') return;
      src.subscribeVisibleLogicalRangeChange(function (range) {
        // 切周期清数据的那一瞬间不做同步，避免往空图里写可见范围
        if (lock || !range || !state.bars.length || Chart.clearing) return;
        lock = true;
        try { dst.setVisibleLogicalRange(range); } catch (e) {}
        lock = false;
      });
    }
    mirror(Chart.chart.timeScale(), Chart.macd.timeScale());
    mirror(Chart.macd.timeScale(), Chart.chart.timeScale());
  }

  /** 副图重新显示或切换周期后，把主图的可见区间套过去。 */
  function syncRangeFromMain() {
    if (!Chart.chart || !Chart.macd || !Ind.macd) return;
    var ts = Chart.chart.timeScale();
    var mt = Chart.macd.timeScale();
    if (!mt || typeof ts.getVisibleLogicalRange !== 'function') return;
    var r = null;
    try { r = ts.getVisibleLogicalRange(); } catch (e) {}
    if (!r) return;
    try { mt.setVisibleLogicalRange(r); } catch (e) {}
  }

  // 右边缘长按拖动：手机上用来压扁 / 拉伸走势（squash 越大，K 线越扁）
  var Scale = { squash: 0, active: false, timer: 0, startY: 0, startSquash: 0, hintShown: false };

  /** 成交量筒收起时，把主图下方空出来的位置还给 K 线；同时叠上用户压扁/拉伸的量。 */
  function applyChartMargins() {
    if (!Chart.chart) return;
    var s = Math.max(0, Math.min(0.34, Scale.squash || 0));
    var top = Math.min(0.44, 0.08 + s);
    var bottom = Math.min(0.5, (Ind.vol ? 0.26 : 0.06) + s);
    if (top + bottom > 0.82) {
      var over = top + bottom - 0.82;
      top -= over / 2;
      bottom -= over / 2;
    }
    var opts = { scaleMargins: { top: top, bottom: bottom } };
    try {
      // 真正生效的是 K 线自己那条价格轴：图表级 rightPriceScale 只是默认值，
      // 改了不会动到已经建好的 series（原来成交量收起时的让位就一直没生效）。
      if (Chart.candle && Chart.candle.priceScale) Chart.candle.priceScale().applyOptions(opts);
      else Chart.chart.applyOptions({ rightPriceScale: opts });
    } catch (e) {}
  }

  function setVolVisible(on, persist) {
    Ind.vol = !!on;
    if (Chart.vol) {
      try { Chart.vol.applyOptions({ visible: !!Ind.vol }); } catch (e) {}
    }
    applyChartMargins();
    paintChartBg();
    if (persist !== false) saveIndPrefs();
  }

  function setMacdVisible(on, persist) {
    Ind.macd = !!on;
    var pane = $('macdPane');
    if (pane) pane.hidden = !Ind.macd || !Chart.macd;
    applyTimeAxis();
    paintChartBg();
    if (Chart.macd && Ind.macd) {
      setTimeout(function () {
        syncRangeFromMain();
        paintChartBg();
      }, 0);
    }
    if (persist !== false) saveIndPrefs();
  }

  function bindChartTools() {
    var tools = $('maTools');
    if (tools) {
      tools.addEventListener('click', function (e) {
        var b = e.target && e.target.closest ? e.target.closest('button') : null;
        if (!b) return;
        if (b.id === 'maAdd') {
          openMaPop(0, b);
          return;
        }
        var p = b.getAttribute('data-ma');
        if (p != null) openMaPop(+p, b);
      });
    }

    var chartBox = $('chart');
    if (chartBox) chartBox.addEventListener('contextmenu', onChartCtx);

    var macdBox = $('chartMacd');
    if (macdBox) {
      macdBox.addEventListener('contextmenu', function (e) {
        e.preventDefault();
        // 手机上长按只留十字线，不弹「添加均线」菜单（双击屏幕才是入口）
        if (DRAW_DEV === 'm') return;
        openCtx(e.clientX, e.clientY, null);
      });
    }

    var apply = $('maApply');
    if (apply) apply.addEventListener('click', applyMaInput);

    var resetBtn = $('btnReset');
    if (resetBtn) resetBtn.addEventListener('click', resetChart);

    var hideMa = $('maHide');
    if (hideMa) {
      hideMa.addEventListener('click', function () {
        if (!Ind.editing) return;
        var m = maByPeriod(Ind.editing);
        if (m) setMaHidden(m.p, !m.hidden);
      });
    }

    var del = $('maDelete');
    if (del) del.addEventListener('click', function () {
      if (Ind.editing) removeMa(Ind.editing);
    });

    var input = $('maCustom');
    if (input) {
      input.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          applyMaInput();
        }
      });
    }

    // 均线数值已经挪到图例里了，这个按钮只剩「添加一条均线」
    var maToggle = $('maToggle');
    if (maToggle) {
      maToggle.addEventListener('click', function (e) {
        e.stopPropagation();
        openMaPop(0, maToggle);
      });
    }

    // 历史开平仓点 / 画线 / 擦除 / 截图
    var histBtn = $('btnHist');
    if (histBtn) histBtn.addEventListener('click', function () { setHistActive(!Draw.showTrades); });
    var shotBtn = $('btnShot');
    if (shotBtn) shotBtn.addEventListener('click', screenshotChart);
    var drawBtn = $('btnDraw');
    if (drawBtn) drawBtn.addEventListener('click', function () {
      setDrawActive(!(Draw.active && Draw.tool === 'free'), 'free');
    });
    var lineBtn = $('btnLine');
    if (lineBtn) lineBtn.addEventListener('click', function () {
      // 可以画多条直线，重新点按钮只是切换工具，不清空旧直线
      var on = Draw.active && Draw.tool === 'line';
      setDrawActive(!on, 'line');
      if (!on) toast('点图上两个点画直线');
    });
    var measureBtn = $('btnMeasure');
    if (measureBtn) measureBtn.addEventListener('click', function () {
      setDrawActive(!(Draw.active && Draw.tool === 'measure'), 'measure');
    });
    bindLineDlg();
    var eraseBtn = $('btnErase');
    if (eraseBtn) eraseBtn.addEventListener('click', eraseDrawings);
  }

  // ---------------------------- 手机手势 ----------------------------

  /** 手机：双击走势图打开「添加均线」（长按已经不再弹菜单）。 */
  function bindDoubleTapAddMa() {
    var wrap = $('chartWrap');
    if (!wrap || DRAW_DEV !== 'm') return;
    var last = 0;
    var lx = 0;
    var ly = 0;
    wrap.addEventListener('pointerup', function (e) {
      if (e.pointerType && e.pointerType !== 'touch') return;
      if (Draw.active) return; // 画线 / 测距时两次点击另有含义
      var t = e.target;
      if (t && t.closest && t.closest(
        'button, a, input, textarea, select, #chartInds, .pane-tools, .scale-strip, ' +
        '#maPop, #ctxMenu, #lineMenu, #lineDlg, .modal'
      )) return;
      var pop = $('maPop');
      if (pop && !pop.hidden) return;
      var now = Date.now();
      if (now - last < 340 && Math.abs(e.clientX - lx) < 44 && Math.abs(e.clientY - ly) < 44) {
        last = 0;
        openMaPop(0, $('maToggle') || wrap);
        return;
      }
      last = now;
      lx = e.clientX;
      ly = e.clientY;
    });
  }

  /** 手机：右边缘长按后上下拖，压扁 / 拉伸走势（顶替原来那条看不见的价格轴）。 */
  function bindScaleStrip() {
    var strip = $('scaleStrip');
    if (!strip || DRAW_DEV !== 'm') return;
    var pid = null;

    function stopArm() {
      if (Scale.timer) { clearTimeout(Scale.timer); Scale.timer = 0; }
    }

    function end() {
      stopArm();
      if (!Scale.active) return;
      Scale.active = false;
      strip.classList.remove('is-active');
      pid = null;
      drawSchedule();
    }

    strip.addEventListener('pointerdown', function (e) {
      if (e.button != null && e.button > 0) return;
      e.preventDefault();
      e.stopPropagation();
      pid = e.pointerId;
      Scale.startY = e.clientY;
      Scale.startSquash = Scale.squash || 0;
      try { if (strip.setPointerCapture) strip.setPointerCapture(pid); } catch (err) {}
      stopArm();
      Scale.timer = setTimeout(function () {
        Scale.timer = 0;
        Scale.active = true;
        strip.classList.add('is-active');
        if (!Scale.hintShown) {
          Scale.hintShown = true;
          toast('按住后上下拖动，可以压扁 / 拉伸走势');
        }
      }, 200);
    });

    strip.addEventListener('pointermove', function (e) {
      if (!Scale.active) {
        // 还没长按就滑走了：当滑动，不触发压扁
        if (Scale.timer && Math.abs(e.clientY - Scale.startY) > 10) stopArm();
        return;
      }
      e.preventDefault();
      var dy = e.clientY - Scale.startY;
      Scale.squash = Math.max(0, Math.min(0.34, Scale.startSquash + dy / 520));
      applyChartMargins();
      paintChartBg();
      drawSchedule();
    });

    ['pointerup', 'pointercancel', 'pointerleave'].forEach(function (type) {
      strip.addEventListener(type, end);
    });
  }

  // 全屏看盘：优先真·全屏（能顺便锁横屏），不支持就用固定层铺满视口
  var FS = { on: false, home: null };

  /** 全屏对象是 .desk-chart：顶部周期栏 + 走势图一起进全屏，横屏后还能选周期。 */
  function fsTarget() {
    var el = document.querySelector ? document.querySelector('.desk-chart') : null;
    return el || $('chartWrap');
  }

  /** iOS 这类没有元素全屏的浏览器：先挂到 body 再 fixed，免得被 .page-track 的 transform 和 overflow 困住。 */
  function fsDetach(el) {
    if (!el || !el.parentNode || FS.home || !document.body) return;
    FS.home = { parent: el.parentNode, next: el.nextSibling };
    try { document.body.appendChild(el); } catch (e) { FS.home = null; }
  }

  function fsAttach(el) {
    if (!FS.home) return;
    try {
      if (FS.home.parent) FS.home.parent.insertBefore(el, FS.home.next || null);
    } catch (e) {}
    FS.home = null;
  }

  function unlockOrientation() {
    try {
      var so = window.screen && window.screen.orientation;
      if (so && typeof so.unlock === 'function') so.unlock();
    } catch (e) {}
  }

  function lockLandscape() {
    try {
      var so = window.screen && window.screen.orientation;
      if (so && typeof so.lock === 'function') {
        var p = so.lock('landscape');
        if (p && p.catch) p.catch(function () {});
      }
    } catch (e) {}
  }

  function fsSync(on) {
    FS.on = !!on;
    if (!FS.on) fsAttach(fsTarget());
    var wrap = fsTarget();
    if (wrap) wrap.classList.toggle('is-fs', FS.on);
    if (document.body && document.body.classList) document.body.classList.toggle('is-fs', FS.on);
    var btn = $('btnFs');
    if (btn) {
      btn.classList.toggle('is-on', FS.on);
      btn.setAttribute('aria-pressed', FS.on ? 'true' : 'false');
      btn.setAttribute('aria-label', FS.on ? '退出全屏' : '全屏查看走势图');
      btn.title = FS.on ? '退出全屏' : '全屏查看走势图';
    }
    // 尺寸变了：图表、背景、画线层都要重新量一次
    setTimeout(function () {
      drawResize();
      paintChartBg();
      syncRangeFromMain();
      syncRightPad();
    }, 60);
    setTimeout(function () {
      drawResize();
      paintChartBg();
      syncRightPad();
    }, 260);
  }

  function toggleChartFullscreen() {
    var el = fsTarget();
    if (!el) return;
    var realFs = !!(document.fullscreenElement || document.webkitFullscreenElement);
    if (FS.on) {
      if (realFs) {
        var exit = document.exitFullscreen || document.webkitExitFullscreen;
        try { if (exit) exit.call(document); } catch (e) {}
      }
      fsAttach(el);
      unlockOrientation();
      fsSync(false);
      return;
    }
    var req = el.requestFullscreen || el.webkitRequestFullscreen;
    if (!req) {
      // iOS Safari 没有元素全屏：挂到 body 上再用固定定位铺满，横屏靠用户自己转
      fsDetach(el);
      fsSync(true);
      return;
    }
    try {
      var p = req.call(el, { navigationUI: 'hide' });
      if (p && p.then) {
        p.then(function () { fsSync(true); lockLandscape(); }).catch(function () {
          fsDetach(el);
          fsSync(true);
        });
      } else {
        fsSync(true);
        lockLandscape();
      }
    } catch (e) {
      fsDetach(el);
      fsSync(true);
    }
  }

  function bindFullscreen() {
    var btn = $('btnFs');
    if (btn) {
      btn.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        toggleChartFullscreen();
      });
    }
    function sync() {
      var on = !!(document.fullscreenElement || document.webkitFullscreenElement);
      if (on === FS.on) return;
      if (!on) unlockOrientation();
      fsSync(on);
    }
    document.addEventListener('fullscreenchange', sync);
    document.addEventListener('webkitfullscreenchange', sync);
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Escape' || !FS.on) return;
      // 真全屏时浏览器自己会退出并触发 fullscreenchange
      if (document.fullscreenElement || document.webkitFullscreenElement) return;
      unlockOrientation();
      fsSync(false);
    });
  }

  function bindChartGestures() {
    bindDoubleTapAddMa();
    bindScaleStrip();
    bindFullscreen();
    // 缩放时保持右边那点留白的像素宽度
    if (DRAW_DEV === 'm' && Chart.chart && Chart.chart.timeScale) {
      var ts = Chart.chart.timeScale();
      if (ts.subscribeVisibleLogicalRangeChange) ts.subscribeVisibleLogicalRangeChange(syncRightPad);
    }
  }

  /** 把指标数组画上去：整段就 setData，单根就 update 最后一个点。 */
  function applyIndicators(bars, full) {
    if (!Chart.ready) return;
    var ind = computeIndicators(bars);
    Ind.data = ind;
    Ind.times = [];
    for (var i = 0; i < bars.length; i += 1) Ind.times.push(bars[i].time);

    Ind.ma.forEach(function (m) {
      var s = Chart.ma[m.p];
      if (!s) return;
      var pts = pointsOf(bars, ind.ma[m.p]);
      try {
        if (full) s.setData(pts);
        else if (pts.length) s.update(pts[pts.length - 1]);
      } catch (e) {}
    });

    var dif = pointsOf(bars, ind.dif);
    var dea = pointsOf(bars, ind.dea);
    var hist = histPointsOf(bars, ind.hist);
    if (!Chart.dif) { Chart.clearing = false; return; }
    try {
      if (full) {
        Chart.dif.setData(dif);
        Chart.dea.setData(dea);
        Chart.hist.setData(hist);
      } else if (dif.length) {
        Chart.dif.update(dif[dif.length - 1]);
        Chart.dea.update(dea[dea.length - 1]);
        Chart.hist.update(hist[hist.length - 1]);
      }
    } catch (e) {}
    Chart.clearing = false;
    drawSchedule();
  }

  /**
   * 主图和副图是两张独立的图，右侧价格轴各按自己的刻度文字算宽度：
   * 主图「78,105.58」→ 78px，副图「-35.45」→ 58px，绘图区宽度就差 20px。
   * 同一个时间点在两张图上的 x 因此差十几像素，竖直的十字线接不上 MACD 柱子。
   * 给两边同一个 minimumWidth，绘图区就等宽了。返回 true 表示这次真的改了宽度。
   */
  function syncPaneWidths() {
    if (!Chart.chart || !Chart.macd) return false;
    try {
      var a = Chart.chart.priceScale('right');
      var b = Chart.macd.priceScale('right');
      var wa = a.width();
      var wb = b.width();
      if (!(wa >= 0) || !(wb >= 0)) return false;
      if (Math.abs(wa - wb) < 1) return false;
      var w = Math.max(wa, wb);
      a.applyOptions({ minimumWidth: w });
      b.applyOptions({ minimumWidth: w });
      return true;
    } catch (e) {}
    return false;
  }

  /**
   * 图表底色：已走出 K 线的区域 #EEE7D4，右侧还没有走势的空区用页面底 #F4ECD9，
   * 分界就是最后一根（正在走的那根）K 线的右边缘。
   * 主图和副图各画一条，两张图的横坐标一致，分界线也就对得上。
   */
  function paintChartBg() {
    var widthsChanged = syncPaneWidths();
    paintPaneBg('chart', Chart.chart);
    paintPaneBg('chartMacd', Chart.macd);
    // 缩放/平移时实时价标签要立刻跟着价格轴走，不能等下一次行情刷新
    updatePriceTag();
    schedulePriceTag();
    drawSchedule();
    drawPriceAxis();
    if (widthsChanged) {
      // 价格轴宽度变了，绘图区要等库重排一帧，再补一次底色和浮标
      setTimeout(function () {
        paintPaneBg('chart', Chart.chart);
        paintPaneBg('chartMacd', Chart.macd);
        updatePriceTag();
        drawSchedule();
        drawPriceAxis();
      }, 60);
    }
  }

  // 图表库自己渲染/自动缩放是在下一帧，等它画完再补一次价格标签位置
  var tagRaf = 0;
  function schedulePriceTag() {
    if (tagRaf) return;
    var raf = window.requestAnimationFrame || function (fn) { return setTimeout(fn, 16); };
    tagRaf = raf(function () {
      tagRaf = raf(function () {
        tagRaf = 0;
        updatePriceTag();
        drawPriceAxis();
      });
    });
  }

  /**
   * 右侧价格刻度：自己画横向虚线和价格数字，控制在 5～6 条，不要像库自带那样挤满。
   * 数字写在右侧那条价格轴的宽度里；那条轴本身还是上下拖拽的压扁 / 拉伸区。
   */
  function nicePriceStep(raw) {
    if (!(raw > 0)) return 0;
    var p = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10));
    var n = raw / p;
    var m = n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10;
    return m * p;
  }

  function drawPriceAxis() {
    var cv = $('axisLayer');
    if (!cv || !Chart.ready || !Chart.chart || !Chart.candle) return;
    var box = $('chart');
    if (!box) return;
    var w = Math.max(1, box.clientWidth || 0);
    var h = Math.max(1, box.clientHeight || 0);
    var dpr = window.devicePixelRatio || 1;
    var pw = Math.round(w * dpr);
    var ph = Math.round(h * dpr);
    if (cv.width !== pw || cv.height !== ph) {
      cv.width = pw;
      cv.height = ph;
    }
    var ctx = cv.getContext('2d');
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    var scaleW = 0;
    try {
      scaleW = Chart.chart.priceScale('right').width() || 0;
    } catch (e) {}
    if (scaleW < 30) return; // 手机上不画（右边缘是手势带）
    var plotW = Math.max(1, w - scaleW);

    var top;
    var bottom;
    try {
      top = Chart.candle.coordinateToPrice(0);
      bottom = Chart.candle.coordinateToPrice(h);
    } catch (e) {
      return;
    }
    if (!Number.isFinite(top) || !Number.isFinite(bottom) || top <= bottom) return;

    var step = nicePriceStep((top - bottom) / 5);
    if (!(step > 0)) return;

    ctx.save();
    ctx.font = '11px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.lineWidth = 1;
    var start = Math.ceil(bottom / step) * step;
    for (var v = start; v <= top + step * 1e-6; v += step) {
      var y = Chart.candle.priceToCoordinate(v);
      if (y == null || !Number.isFinite(y) || y < 10 || y > h - 10) continue;
      var yy = Math.round(y) + 0.5;
      ctx.strokeStyle = 'rgba(107, 98, 80, 0.22)';
      ctx.setLineDash([3, 4]);
      ctx.beginPath();
      ctx.moveTo(0, yy);
      ctx.lineTo(plotW, yy);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = 'rgba(107, 98, 80, 0.9)';
      ctx.fillText(fmtAxis(v), plotW + 7, yy);
    }
    ctx.restore();
  }

  function paintPaneBg(id, chart) {
    var box = $(id);
    if (!box || !chart) return;
    var w = box.clientWidth || 0;
    var edge = 0;
    var bars = state.bars || [];
    if (bars.length) {
      var ts = chart.timeScale();
      var x = ts && typeof ts.timeToCoordinate === 'function'
        ? ts.timeToCoordinate(bars[bars.length - 1].time)
        : null;
      if (x != null) {
        var opts = ts.options ? ts.options() : null;
        var bs = (opts && opts.barSpacing) || 6;
        edge = Math.round(x + bs / 2);
      }
    }
    if (edge < 0) edge = 0;
    if (edge > w) edge = w;
    var bg = 'linear-gradient(90deg, #EEE7D4 0, #EEE7D4 ' + edge +
      'px, #F4ECD9 ' + edge + 'px)';
    if (box.style.background !== bg) box.style.background = bg;
  }

  /**
   * 右侧价格轴隐藏后，用图表内的浮层标签显示「当前价」和「十字线价格」。
   * 标签贴着绘图区右边界，不占宽度，横轴能多看好几根 K 线。
   */
  function chartBoxHeight() {
    var box = $('chart');
    return (box && box.clientHeight) || 0;
  }

  /** 绘图区高度：扣掉主图底部的时间轴，浮标不要盖到时间刻度上。 */
  function chartPlotHeight() {
    var h = chartBoxHeight();
    if (!h) return 0;
    try {
      var ts = Chart.chart && Chart.chart.timeScale();
      var th = ts && typeof ts.height === 'function' ? ts.height() : 0;
      if (th > 0 && th < h) h -= th;
    } catch (e) {}
    return h;
  }

  function placeChartTag(tag, y) {
    var h = chartPlotHeight();
    if (!h || !Number.isFinite(y) || y < 0 || y > h) { tag.hidden = true; return false; }
    tag.hidden = false;
    tag.style.top = Math.max(9, Math.min(h - 9, y)) + 'px';
    return true;
  }

  function updatePriceTag() {
    var tag = $('priceTag');
    if (!tag) return;
    var last = state.bars[state.bars.length - 1];
    var price = last ? +last.close : 0;
    if (!Chart.candle || typeof Chart.candle.priceToCoordinate !== 'function' || !price) {
      tag.hidden = true;
      return;
    }
    var y = null;
    try { y = Chart.candle.priceToCoordinate(price); } catch (e) {}
    if (y == null || !Number.isFinite(y) || !placeChartTag(tag, y)) return;
    tag.textContent = fmtAxis(price);
    var pct = +state.chartPct || 0;
    tag.classList.toggle('is-up', pct >= 0);
    tag.classList.toggle('is-down', pct < 0);
  }

  /**
   * 十字线价格浮标：鼠标在主图上就显示，包括右侧还没走出 K 线的空白区。
   * 空白区没有 time / seriesData，但有鼠标坐标，价格直接用坐标换算，
   * 这样「未来区」也能看到指针所在位置的价位。
   */
  function updateHoverTag(param, onMain) {
    var tag = $('hoverTag');
    if (!tag) return;
    var priceTag = $('priceTag');
    if (!onMain || !param || !param.point || !Chart.candle) {
      tag.hidden = true;
      if (priceTag) updatePriceTag();
      return;
    }
    var price = null;
    try { price = Chart.candle.coordinateToPrice(param.point.y); } catch (e) {}
    if (!Number.isFinite(price) || !placeChartTag(tag, param.point.y)) {
      tag.hidden = true;
      if (priceTag) updatePriceTag();
      return;
    }
    if (priceTag) priceTag.hidden = false;
    tag.textContent = fmtAxis(price);
  }

  // ---------------------------------------------------------------- 视口保持
  // 换周期时图表默认会 fitContent：把新周期的 1000 根全塞进屏幕，K 线缩成一条条
  // 细线一直铺到右边界，用户之前放大的位置就丢了。这里在切换前记下「可见根数」
  //（宽度不变时它就等于蜡烛宽度）和「右边界时间」，新周期数据到了按这两样还原：
  // 根数不变 → 蜡烛宽度不变；右边界时间不变 → 看到的位置不跳。
  // 贴着最新价时额外记住右侧留白，切完仍是「最新一根 + 同样多根空位」。

  /** 逻辑下标 → 时间（秒）；下标落在数据外时按周期步长外推，右侧留白也算得出来。 */
  function barTimeAt(bars, step, idx) {
    var last = bars.length - 1;
    if (idx <= 0) return bars[0].time + idx * step;
    if (idx >= last) return bars[last].time + (idx - last) * step;
    var i = Math.floor(idx);
    return bars[i].time + (idx - i) * step;
  }

  /** 时间（秒）→ 逻辑下标，允许小数和越界（数据外的部分按步长外推）。 */
  function logicalAtTime(bars, step, t) {
    var last = bars.length - 1;
    if (t <= bars[0].time) return (t - bars[0].time) / step;
    if (t >= bars[last].time) return last + (t - bars[last].time) / step;
    var lo = 0;
    var hi = last;
    while (hi - lo > 1) {
      var mid = (lo + hi) >> 1;
      if (bars[mid].time <= t) lo = mid;
      else hi = mid;
    }
    return lo + (t - bars[lo].time) / step;
  }

  /** 切换周期前调一次：记下可见根数、右边界时间、右侧留白。 */
  function captureView() {
    if (!Chart.chart || state.bars.length < 3) return null;
    var r = null;
    try { r = Chart.chart.timeScale().getVisibleLogicalRange(); } catch (e) {}
    if (!r || !Number.isFinite(r.from) || !Number.isFinite(r.to) || r.to <= r.from) return null;
    var step = (TF_MS[state.iv] || 60000) / 1000;
    var last = state.bars.length - 1;
    return {
      count: r.to - r.from,           // 可见根数 = 蜡烛宽度
      to: barTimeAt(state.bars, step, r.to),
      atEnd: r.to >= last,            // 右边界在最新一根或它右侧的留白里
      // 右侧留白按实际根数记：用户可以拖出很大的留白，不能夹到 rightOffset
      offset: Math.max(0, r.to - last)
    };
  }

  /**
   * 新周期数据画上去之后调：根数不变、右边界停在原来的时间上。
   * 返回 false 表示没有待还原的视口（首次加载照旧铺满全图）。
   */
  function applyViewRestore() {
    if (!state.view) return false;
    // 历史是整页拉回来的（PAGE 根）。不足半页多半是换周期后 WS 先推来的一两根，
    // 拿它换算时间没有意义，先留着视口，等整页数据到了再还原。
    if (!Chart.chart || state.bars.length < PAGE / 2) return false;
    var v = state.view;
    state.view = null; // 只还原一次；之后 WS 推送、补历史仍按原来的逻辑保持视口

    var step = (TF_MS[state.iv] || 60000) / 1000;
    var last = state.bars.length - 1;

    // 视口宽度（根数）按原样保留：它就是蜡烛宽度，不能因为数据不够就先改它
    var count = v.count;
    var to;
    if (v.atEnd) {
      // 右边界原来在最新一根右侧：把这段留白按同样的根数搬过来，
      // 拖出几十根留白也照搬，最后一根到右边界的距离（像素）才不变
      to = last + v.offset;
    } else {
      to = logicalAtTime(state.bars, step, v.to);
    }
    var from = to - count;

    // 目标时间比已拉到的第一根还早：右边界整段落在数据外，先贴住最早的数据显示，
    // 不然是一张空白图（更早的历史补上来后 loadOlderBars 会右移视口）。
    if (to < 0) {
      from = 0;
      to = Math.min(count, last + RIGHT_OFFSET);
    }
    if (to <= from) return false;

    var ts = Chart.chart.timeScale();
    var pin = function () {
      try { ts.setVisibleLogicalRange({ from: from, to: to }); } catch (e) {}
    };
    pin();
    // setData 之后图表还可能自动贴到最新一根定位一帧，同步设置的视口会被盖掉，下一帧再钉一次
    if (typeof requestAnimationFrame === 'function') requestAnimationFrame(pin);
    return true;
  }

  /**
   * 手机右侧留白按「像素」算：约 22px，缩放时换算成对应的根数改 rightOffset。
   * 用根数写死不行——放大后同样根数会变成一大块空白，缩小后又会贴边。
   */
  var RightPad = { px: 22, busy: false };

  function syncRightPad() {
    if (DRAW_DEV !== 'm' || !Chart.chart || RightPad.busy) return;
    var ts = Chart.chart.timeScale();
    var opts = ts.options ? ts.options() : null;
    if (!opts || !opts.barSpacing) return;
    var want = Math.max(2, Math.min(240, Math.round(RightPad.px / opts.barSpacing)));
    if (Math.abs(want - (+opts.rightOffset || 0)) < 2) return;
    RightPad.busy = true;
    try { ts.applyOptions({ rightOffset: want }); } catch (e) {}
    RightPad.busy = false;
  }

  /** 图表换了一批数据之后：换周期就回到原视口，首次加载才铺满全图。 */
  function settleView() {
    if (!Chart.chart || !state.bars.length) return;
    if (applyViewRestore()) {
      state.firstLoad = false;
      return;
    }
    // 视口还在等整页数据（见 applyViewRestore 的 PAGE/2 门槛）：先别铺满全图，
    // 否则会先闪一下整页、再跳回原视口。
    if (state.view) return;
    if (state.firstLoad && state.bars.length > 2) {
      Chart.chart.timeScale().fitContent();
      state.firstLoad = false;
      // fitContent 会一路铺到右边界；手机上补一段留白，K 线不要贴着屏幕边
      if (typeof requestAnimationFrame === 'function') requestAnimationFrame(syncRightPad);
      else syncRightPad();
    }
  }

  function chartSet(bars) {
    if (!Chart.ready || !bars.length) return;
    try {
      Chart.candle.setData(bars);
      Chart.vol.setData(bars.map(function (b) {
        return { time: b.time, value: b.volume, color: volColor(b) };
      }));
      var last = bars[bars.length - 1];
      Chart.candle.applyOptions({ priceLineColor: last.close >= last.open ? UP : DOWN });
      applyIndicators(bars, true);
      refreshLegend();
    } catch (e) {
      // 极端情况下时间重复/乱序，别把整个图卡死
    }
    paintChartBg();
    updatePriceTag();
    crosshairReanchor();
  }

  function chartUpdate(bar) {
    if (!Chart.ready) return;
    try {
      Chart.candle.update(bar);
      Chart.vol.update({ time: bar.time, value: bar.volume, color: volColor(bar) });
      Chart.candle.applyOptions({ priceLineColor: bar.close >= bar.open ? UP : DOWN });
      // 指标要跟着最后一根重算（EMA 是递推的，不能只改这一根）
      applyIndicators(state.bars, false);
    } catch (e) {
      // update 只接受不早于最后一根的时间，顺序被打乱就整段重画
      chartSet(state.bars);
    }
    paintChartBg();
    updatePriceTag();
    crosshairReanchor();
  }

  // ---------------------------------------------------------------- 账户
  function newGuest() {
    return {
      cash: INITIAL_CASH,
      baseCash: INITIAL_CASH,
      totalTrades: 0,
      positions: [],
      orders: [],
      history: [],
      lastPrice: 0
    };
  }

  function loadGuest() {
    var raw = readLS(LS.guest);
    if (raw) {
      try {
        var a = JSON.parse(raw);
        if (a && typeof a.cash === 'number') {
          a.positions = a.positions || [];
          a.orders = a.orders || [];
          a.history = a.history || [];
          normalizePositions(a);
          // 老账户没有这两个字段：本金按 10 万算，累计单数用历史补上
          if (!Number.isFinite(+a.baseCash) || +a.baseCash <= 0) a.baseCash = INITIAL_CASH;
          if (!Number.isFinite(+a.totalTrades)) {
            a.totalTrades = a.history.filter(function (h) {
              return h && (h.type === 'close' || h.type === 'liquidated');
            }).length;
          }
          return a;
        }
      } catch (e) {}
    }
    return newGuest();
  }

  /**
   * 同一方向只留一单：老版本把每次开仓都存成独立持仓，这里在读取时合并，
   * 数量与保证金相加，开仓价改成「总成本 / 总数量」的加权均价。
   */
  function normalizePositions(a) {
    var groups = {};
    var out = [];
    (a.positions || []).forEach(function (p) {
      if (!p || (p.side !== 'long' && p.side !== 'short')) return;
      var g = groups[p.side];
      if (!g) {
        g = groups[p.side] = {
          id: p.id, side: p.side, qty: 0, entry: p.entry || 0,
          margin: 0, openFee: 0, openedAt: p.openedAt || 0, cost: 0
        };
        out.push(g);
      }
      var q = +p.qty || 0;
      g.qty += q;
      g.margin += +p.margin || 0;
      g.openFee += +p.openFee || 0;
      g.cost += (+p.entry || 0) * q;
      if (p.openedAt && (!g.openedAt || p.openedAt < g.openedAt)) g.openedAt = p.openedAt;
    });
    out.forEach(function (g) {
      g.qty = round6(g.qty);
      g.margin = round6(g.margin);
      g.openFee = round6(g.openFee);
      g.entry = g.qty > 0 ? round(g.cost / g.qty, 8) : g.entry;
      delete g.cost;
    });
    a.positions = out;
  }

  function saveAccount() {
    if (Account.mode === 'guest') {
      writeLS(LS.guest, JSON.stringify(Account.data));
    }
  }

  // 云端账户最近一次成功快照：网络短暂中断时先用它顶上，避免页面显示成本机
  // 账户的 100,000 / 0 单，看起来像“登录了但数据全丢了”。
  var LS_CACHE = 'huideng.trade.cache';

  function cacheCloud() {
    if (Account.mode !== 'cloud' || !Account.data) return;
    try {
      writeLS(LS_CACHE, JSON.stringify({
        u: Account.username || '',
        at: Date.now(),
        data: Account.data
      }));
    } catch (e) {}
  }

  function loadCloudCache() {
    if (Account.mode !== 'cloud') return;
    var raw = readLS(LS_CACHE);
    if (!raw) return;
    try {
      var c = JSON.parse(raw);
      if (c && c.u === (Account.username || '') && c.data && typeof c.data.cash === 'number') {
        c.data.positions = c.data.positions || [];
        c.data.orders = c.data.orders || [];
        c.data.history = c.data.history || [];
        Account.data = c.data;
      }
    } catch (e) {}
  }

  function api(action, params) {
    var body = { action: action, token: Account.token };
    if (params) Object.keys(params).forEach(function (k) { body[k] = params[k]; });
    return fetch(cfg.api, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + cfg.key,
        'x-device-id': 'web'
      },
      body: JSON.stringify(body)
    }).then(function (res) {
      if (!res.ok) throw err('HTTP ' + res.status);
      return res.json();
    }).then(function (j) {
      if (!j.ok) throw err(j.error);
      return j;
    }, function (e) {
      if (e && e.code) throw e;
      throw err('network');
    });
  }

  /** 拉云端账户；网络抖动自动重试 3 次，失败时保留本地缓存快照。 */
  function loadCloudState(announce) {
    function attempt(n) {
      return api('tradeState', {}).then(function (j) {
        Account.data = j.account;
        renderAll();
        cloudDrawPull();
        if (announce) toast('交易记录已同步');
      }).catch(function (e) {
        if (e && e.code === 'unauthorized') {
          dropAuth();
          toast('登录已过期，请重新登录');
          return;
        }
        if (e && e.code === 'network' && n < 3) {
          return new Promise(function (resolve) {
            setTimeout(resolve, 700 * (n + 1));
          }).then(function () { return attempt(n + 1); });
        }
        toast('交易记录同步失败：' + msgOf(e && e.code) + '，可点右上角头像 → 同步交易记录');
      });
    }
    return attempt(0);
  }

  function syncAccount() {
    if (Account.mode !== 'cloud') {
      toast('当前是本机账户，无需同步');
      return;
    }
    toast('正在同步交易记录…');
    loadCloudState(true);
  }

  function unrealized(pos, mark) {
    if (!mark) return 0;
    var diff = pos.side === 'short' ? (pos.entry - mark) : (mark - pos.entry);
    return diff * pos.qty * PNL_MULT;
  }

  function equity(mark) {
    var a = Account.data;
    if (!a) return 0;
    var sum = a.cash;
    (a.positions || []).forEach(function (p) { sum += p.margin + unrealized(p, mark || state.price); });
    return sum;
  }

  // ---- 本机账户：与 cloudfunctions/api/trade.js 完全同一套规则 ----

  /**
   * 同方向还没平仓的持仓合并成一单：数量、保证金、手续费相加，
   * 开仓价按「总成本 / 总数量」算加权均价，并保留第一次开仓的 posId。
   */
  function localAddPosition(a, side, qty, price, margin, fee) {
    var existing = null;
    for (var i = 0; i < a.positions.length; i += 1) {
      if (a.positions[i].side === side) { existing = a.positions[i]; break; }
    }
    if (existing) {
      var total = round6(existing.qty + qty);
      if (total > 0) {
        existing.entry = round((existing.entry * existing.qty + price * qty) / total, 8);
      }
      existing.qty = total;
      existing.margin = round6((+existing.margin || 0) + margin);
      existing.openFee = round6((+existing.openFee || 0) + fee);
      return existing.id;
    }
    var posId = uid();
    a.positions.push({
      id: posId,
      side: side,
      qty: qty,
      entry: price,
      margin: margin,
      openFee: fee,
      openedAt: Date.now()
    });
    return posId;
  }

  function localPlace(o) {
    var a = Account.data;
    var qty = round6(o.qty);
    var price = round2(o.price);
    if (!Number.isFinite(qty) || qty <= 0 || qty > MAX_QTY) throw err('bad_qty');
    if (!Number.isFinite(price) || price <= 0) throw err('bad_price');
    if (price * qty < MIN_NOTIONAL) throw err('min_notional');

    if (o.kind === 'limit') {
      a.orders.push({ id: uid(), side: o.side, price: price, qty: qty, createdAt: Date.now() });
      saveAccount();
      return;
    }

    var fee = price * qty * FEE;
    var margin = price * qty;
    // 100% 时价格可能在点击后跳了一点：差额在 0.5% 内就按可用余额截一下，直接成交
    if (a.cash < margin + fee) {
      var maxQ = Math.floor((a.cash / (price * (1 + FEE))) * 1e6) / 1e6;
      if (maxQ > 0 && qty <= maxQ * 1.005 + 1e-6) {
        qty = maxQ;
        fee = price * qty * FEE;
        margin = price * qty;
      }
    }
    if (a.cash < margin + fee) throw err('insufficient_balance');
    a.cash = round6(a.cash - margin - fee);
    var posId = localAddPosition(a, o.side, qty, price, margin, fee);
    pushHistory({ type: 'open', side: o.side, qty: qty, price: price, fee: fee, pnl: 0, posId: posId });
    saveAccount();
  }

  function localClose(id, price, pct) {
    var a = Account.data;
    var idx = -1;
    a.positions.forEach(function (p, i) { if (p.id === id) idx = i; });
    if (idx < 0) throw err('not_found');
    var p = a.positions[idx];
    pct = (pct == null || !(+pct > 0)) ? 1 : Math.min(1, +pct);
    var qty = round6(p.qty * pct);
    if (qty <= 0) throw err('bad_qty');
    var diff = p.side === 'short' ? (p.entry - price) : (price - p.entry);
    var pnl = diff * qty * PNL_MULT;
    var marginPart = p.margin * pct;
    var fee = price * qty * FEE;
    var proceeds = marginPart + pnl - fee;
    if (proceeds < 0) proceeds = 0;
    a.cash = round6(a.cash + proceeds);
    if (pct >= 1 - 1e-9) {
      a.positions.splice(idx, 1);
    } else {
      p.qty = round6(p.qty - qty);
      p.margin = round6(p.margin - marginPart);
    }
    pushHistory({
      type: 'close', side: p.side, qty: qty, price: price,
      fee: fee, pnl: pnl, posId: p.id
    });
    a.totalTrades = (+a.totalTrades || 0) + 1;
    saveAccount();
  }

  function localMatch(price) {
    var a = Account.data;
    var changed = false;
    var i;

    for (i = a.orders.length - 1; i >= 0; i--) {
      var o = a.orders[i];
      var hit = o.side === 'long' ? price <= o.price : price >= o.price;
      if (!hit) continue;
      var fee = price * o.qty * FEE;
      var margin = price * o.qty;
      if (a.cash < margin + fee) { a.orders.splice(i, 1); changed = true; continue; }
      a.orders.splice(i, 1);
      a.cash = round6(a.cash - margin - fee);
      var orderPosId = localAddPosition(a, o.side, o.qty, price, margin, fee);
      pushHistory({ type: 'open', side: o.side, qty: o.qty, price: price, fee: fee, pnl: 0, posId: orderPosId });
      changed = true;
    }

    for (i = a.positions.length - 1; i >= 0; i--) {
      var p = a.positions[i];
      if (p.margin + unrealized(p, price) > 0) continue;
      a.positions.splice(i, 1);
      pushHistory({ type: 'liquidated', side: p.side, qty: p.qty, price: price, fee: 0, pnl: -p.margin, posId: p.id });
      a.totalTrades = (+a.totalTrades || 0) + 1;
      toast('有一笔持仓已逐仓强平');
      changed = true;
    }

    if (changed) saveAccount();
    return changed;
  }

  function pushHistory(item) {
    var a = Account.data;
    item.id = uid();
    item.at = Date.now();
    a.history.unshift(item);
    if (a.history.length > MAX_HISTORY) a.history.length = MAX_HISTORY;
  }

  // ---- 对外的四件事（本机 / 云端同一接口） ----

  function place(o) {
    if (Account.mode === 'guest') {
      localPlace(o);
      renderAll();
      return Promise.resolve();
    }
    return api('tradePlace', {
      kind: o.kind, side: o.side, qty: o.qty,
      price: o.price, limitPrice: o.limitPrice || 0
    }).then(function (j) {
      Account.data = j.account;
      renderAll();
    });
  }

  function closePos(id, price, pct) {
    pct = (pct == null || !(+pct > 0)) ? 1 : Math.min(1, +pct);
    if (Account.mode === 'guest') {
      localClose(id, price, pct);
      renderAll();
      return Promise.resolve();
    }
    return api('tradeClose', { positionId: id, price: price, pct: pct }).then(function (j) {
      Account.data = j.account;
      renderAll();
    });
  }

  function cancel(id) {
    if (Account.mode === 'guest') {
      var a = Account.data;
      a.orders = a.orders.filter(function (o) { return o.id !== id; });
      saveAccount();
      renderAll();
      return Promise.resolve();
    }
    return api('tradeCancel', { orderId: id }).then(function (j) {
      Account.data = j.account;
      renderAll();
    });
  }

  var lastSync = 0;
  function maybeSync(price) {
    if (!price || !Account.data) return;
    var hasOrders = (Account.data.orders || []).length > 0;
    var hasPos = (Account.data.positions || []).length > 0;
    if (!hasOrders && !hasPos) return;

    if (Account.mode === 'guest') {
      if (hasOrders || hasPos) localMatch(price);
      return;
    }
    if (Date.now() - lastSync < SYNC_MS) return;
    lastSync = Date.now();
    api('tradeSync', { price: price }).then(function (j) {
      Account.data = j.account;
      renderAll();
    }).catch(function (e) {
      if (e && e.code === 'unauthorized') dropAuth();
    });
  }

  function showErr(e) {
    var code = e && e.code ? e.code : (e && e.message ? e.message : '');
    if (code === 'unauthorized') {
      dropAuth();
      toast('登录已过期，请重新登录');
      return;
    }
    if (code === 'insufficient_balance') {
      // 云端才是权威余额；本机显示可能过期，提示同步而不是反复自动拉
      toast('可用余额可能不是最新，请点右上角头像 → 同步交易记录后再试');
      return;
    }
    toast(msgOf(code));
  }

  // ---------------------------------------------------------------- 认证
  function restoreAuth() {
    var token = readLS(LS.token);
    if (!token) return false;
    Account.token = token;
    Account.username = readLS(LS.user) || '';
    Account.mode = 'cloud';
    loadCloudCache();
    return true;
  }

  /** 重置资金：金额可选（默认 10 万），清掉持仓/挂单，历史成交、总单数和胜率保留。 */
  var RESET_MIN = 100;
  var RESET_MAX = 100000000;
  var RESET_DEFAULT = 100000;

  function openReset() {
    var m = $('resetModal');
    if (!m) return;
    if ($('resetAmount')) $('resetAmount').value = String(RESET_DEFAULT);
    if ($('resetErr')) $('resetErr').textContent = '';
    m.hidden = false;
    setTimeout(function () {
      var input = $('resetAmount');
      if (input && input.focus) input.focus();
    }, 30);
  }

  function closeReset() {
    var m = $('resetModal');
    if (m) m.hidden = true;
  }

  function readResetAmount() {
    var raw = ($('resetAmount') && $('resetAmount').value) || '';
    var amount = parseFloat(String(raw).replace(/[,\s]/g, ''));
    if (!Number.isFinite(amount) || amount < RESET_MIN || amount > RESET_MAX) return null;
    return Math.round(amount * 100) / 100;
  }

  function pushResetEvent(amount) {
    try {
      var raw = window.localStorage.getItem('huideng.trade.resets');
      var list = raw ? JSON.parse(raw) : [];
      if (!Array.isArray(list)) list = [];
      list.push({ at: Date.now(), amount: amount });
      if (list.length > 50) list = list.slice(-50);
      window.localStorage.setItem('huideng.trade.resets', JSON.stringify(list));
    } catch (e) {}
  }

  function doReset() {
    var amount = readResetAmount();
    var errBox = $('resetErr');
    if (amount == null) {
      if (errBox) errBox.textContent = '请输入 ' + group(RESET_MIN, 0) + ' ~ ' + group(RESET_MAX, 0) + ' 之间的金额';
      return;
    }
    var btn = $('resetSubmit');
    if (btn) btn.disabled = true;
    if (Account.mode === 'guest') {
      var a = Account.data;
      a.cash = amount;
      a.baseCash = amount;
      a.positions = [];
      a.orders = [];
      a.lastPrice = 0;
      saveAccount();
      pushResetEvent(amount);
      renderAll();
      closeReset();
      if (btn) btn.disabled = false;
      toast('资金已重置为 ' + group(amount, 2) + ' USDT，历史与总单数保留');
      return;
    }
    api('tradeReset', { amount: amount }).then(function (j) {
      Account.data = j.account;
      pushResetEvent(amount);
      renderAll();
      closeReset();
      toast('资金已重置为 ' + group(amount, 2) + ' USDT，历史与总单数保留');
    }).catch(showErr).then(function () {
      if (btn) btn.disabled = false;
    });
  }

  function dropAuth() {
    dropLS(LS.token);
    dropLS(LS.user);
    Account.token = '';
    Account.username = '';
    Account.mode = 'guest';
    Account.data = loadGuest();
    renderAll();
  }

  function doAuth(mode, username, password) {
    var action = mode === 'register' ? 'tradeRegister' : 'tradeLogin';
    return api(action, { username: username, password: password }).then(function (j) {
      Account.token = j.token;
      Account.username = j.username || username;
      Account.mode = 'cloud';
      writeLS(LS.token, j.token);
      writeLS(LS.user, Account.username);
      return loadCloudState(false);
    }).then(function () {
      if (pendingNotes) {
        pendingNotes = false;
        window.location.href = (cfg.rel || '') + 'notes/index.html';
        return;
      }
      if (pendingNotesSlide) {
        pendingNotesSlide = false;
        closeModal();
        openNotesSlide();
        return;
      }
      closeModal();
      toast('已登录，模拟账户跨设备同步');
    });
  }

  // ---------------------------------------------------------------- 渲染
  function renderAll() {
    renderAcct();
    renderTables();
    renderSummary();
    renderEst();
    renderPosCalc();
    updateOrderUI();
    renderAccountMenu();
    cacheCloud();
  }

  /**
   * 开仓/平仓配成「一单」：历史是新的在前，这里按时间正序用栈配对。
   * 同一持仓 id 的多次开仓会先合成一个成本池，平仓价差按加权成本均价算；
   * 老数据没有 posId 时仍退回按方向 + 数量配对。
   */
  function roundTrips() {
    var list = (Account.data && Account.data.history) || [];
    var chrono = list.slice().reverse();
    var opens = [];      // 没有 posId 的旧开仓
    var pools = {};      // posId -> { side, qty, cost, at }
    var out = [];

    function take(pool, qty) {
      var before = pool.qty;
      if (before <= 1e-12) return 0;
      var n = Math.min(qty, before);
      var avg = pool.cost / before;
      pool.qty = round6(before - n);
      pool.cost = Math.max(0, pool.cost - avg * n);
      if (pool.qty <= 1e-9) {
        pool.qty = 0;
        pool.cost = 0;
      }
      return { qty: n, cost: avg * n };
    }

    chrono.forEach(function (h) {
      if (!h) return;
      if (h.type === 'open') {
        if (h.posId) {
          var p = pools[h.posId];
          if (!p) p = pools[h.posId] = { side: h.side, qty: 0, cost: 0, at: h.at };
          p.qty += +h.qty || 0;
          p.cost += (+h.price || 0) * (+h.qty || 0);
          if (h.at && (!p.at || h.at < p.at)) p.at = h.at;
        } else {
          opens.push(h);
        }
        return;
      }
      if (h.type !== 'close' && h.type !== 'liquidated') return;

      var need = +h.qty || 0;
      var gotQty = 0;
      var gotCost = 0;
      var openAt = 0;
      var i;

      if (h.posId && pools[h.posId]) {
        var main = pools[h.posId];
        openAt = main.at;
        var part = take(main, need);
        gotQty += part.qty;
        gotCost += part.cost;

        // 老数据同方向曾经合并过持仓，但仍保留多条开仓记录：
        // 当前成本池不够时，用同方向其它开仓池补齐，成本同样按加权均价。
        if (need - gotQty > 1e-9) {
          var extras = [];
          Object.keys(pools).forEach(function (id) {
            if (id === h.posId) return;
            var q = pools[id];
            if (q.side === h.side && q.qty > 1e-9) extras.push(q);
          });
          extras.sort(function (a, b) { return (a.at || 0) - (b.at || 0); });
          for (i = 0; i < extras.length && need - gotQty > 1e-9; i += 1) {
            var more = take(extras[i], need - gotQty);
            gotQty += more.qty;
            gotCost += more.cost;
          }
        }
      } else if (!h.posId) {
        // 旧数据没有 posId：退回按方向 + 数量配对
        for (i = opens.length - 1; i >= 0; i -= 1) {
          if (opens[i].side === h.side && Math.abs(opens[i].qty - h.qty) < 1e-9) {
            var o = opens.splice(i, 1)[0];
            gotQty = +o.qty || 0;
            gotCost = (+o.price || 0) * gotQty;
            openAt = o.at;
            break;
          }
        }
      }

      out.push({
        at: h.at,
        openAt: openAt,
        side: h.side,
        qty: h.qty,
        entry: gotQty > 1e-12 ? round(gotCost / gotQty, 8) : null,
        exit: h.price,
        pnl: h.pnl || 0,
        liquidated: h.type === 'liquidated'
      });
    });

    return out.reverse(); // 新的在前，和原来的记录顺序一致
  }

  /**
   * 胜率 = 盈利单数 / 完成的单数；当日单数 = 最近 24 小时平掉的单数。
   * 盈利的判定：这一笔的收益率 > 0.1%（收益率 = 浮动盈亏 ÷ 开仓金额），
   * 太小的小赚/打平不算赢。
   */
  var WIN_RATE_MIN = 0.001; // 0.1%

  function tradeStats() {
    var trips = roundTrips();
    var dayAgo = Date.now() - 24 * 3600 * 1000;
    var wins = 0;
    var today = 0;
    trips.forEach(function (t) {
      var base = t.entry != null ? Math.abs(+t.entry * (+t.qty || 0)) : 0;
      var rate = base > 0 ? t.pnl / base : 0;
      if (t.pnl > 0 && rate > WIN_RATE_MIN) wins += 1;
      if (t.at >= dayAgo) today += 1;
    });
    // 最近 7 笔的回撤：按开仓价到平仓价的不利方向幅度算，盈利单记为 0。
    // 模拟盘按 10 倍杠杆，所以价格波动幅度要放大 10 倍。
    var LEVERAGE = 10;
    var recent = trips.slice(0, 7);
    var ddSum = 0;
    recent.forEach(function (t) {
      if (!+t.entry || !+t.exit) return;
      var adverse = t.side === 'long'
        ? (+t.entry - +t.exit) / +t.entry
        : (+t.exit - +t.entry) / +t.entry;
      ddSum += Math.max(0, adverse) * 100 * LEVERAGE;
    });
    return {
      total: trips.length,
      today: today,
      winRate: trips.length ? (wins / trips.length) * 100 : null,
      drawdown: recent.length ? ddSum / recent.length : null
    };
  }

  function renderAcct() {
    var a = Account.data;
    if (!a) return;
    var mark = state.price;
    var eq = equity(mark);
    var base = +a.baseCash > 0 ? +a.baseCash : INITIAL_CASH;
    var pnl = eq - base;
    var pct = base ? (pnl / base) * 100 : 0;
    setNum('acctEquity', eq, 2);
    setNum('acctCash', a.cash, 2);
    var ePnl = $('acctPnl');
    if (ePnl) {
      ePnl.textContent = (pct >= 0 ? '+' : '') + pct.toFixed(2) + '%';
      ePnl.className = pct > 0 ? 'is-up' : pct < 0 ? 'is-down' : '';
      ePnl.style.color = pct > 0 ? UP : pct < 0 ? DOWN : '';
      ePnl.title = (pnl >= 0 ? '+' : '') + group(pnl, 2) + ' USDT';
    }
    var st = tradeStats();
    var total = Math.max(Number.isFinite(+a.totalTrades) ? +a.totalTrades : 0, st.total);
    if ($('statOps')) $('statOps').textContent = st.today + '/' + total;
    if ($('statDD')) {
      $('statDD').textContent = st.drawdown == null ? '--' : st.drawdown.toFixed(1) + '%';
      $('statDD').title = '最近 7 笔平均回撤（按 10 倍杠杆）';
    }
    if ($('statWin')) {
      $('statWin').textContent = st.winRate == null ? '--' : st.winRate.toFixed(1) + '%';
      $('statWin').title = '收益率（盈亏 ÷ 开仓金额）大于 0.1% 的平仓单 ÷ 已平仓单数';
    }
  }

  function setNum(id, v, digits) {
    var e = $(id);
    if (e) e.textContent = Number.isFinite(+v) ? group(+v, digits) : '--';
  }

  function renderTables() {
    var a = Account.data;
    if (!a) return;

    // 挂单
    var ordBody = $('tblOrd');
    if (ordBody) {
      ordBody.innerHTML = '';
      (a.orders || []).forEach(function (o) {
        ordBody.appendChild(row([
          cell(o.side === 'long' ? '看多' : '看空', o.side === 'long' ? 'is-up' : 'is-down'),
          cell(fmtPrice(o.price), 'num'),
          cell(fmtQty(o.qty), 'num'),
          cell(fmtPrice(o.price * o.qty), 'num'),
          cell(fmtDateTime(o.createdAt), ''),
          cellBtn('撤单', function () { doCancel(o.id); }, 'btn-mini')
        ]));
      });
    }

    // 历史记录：一开一平合成一条；全部渲染，行多了在侧滑面板里滚
    var trips = roundTrips();
    Draw.trades = trips;
    var hisBody = $('tblHis');
    if (hisBody) {
      hisBody.innerHTML = '';
      for (var ti = 0; ti < trips.length; ti += 1) {
        var t = trips[ti];
        var sideText = (t.side === 'long' ? '看多' : '看空') + (t.liquidated ? ' · 强平' : '');
        var tr = row([
          cell(fmtDateTime(t.at), ''),
          cell(sideText, t.side === 'long' ? 'is-up' : 'is-down'),
          cell((t.pnl >= 0 ? '+' : '') + group(t.pnl, 2), 'num ' + (t.pnl >= 0 ? 'is-up' : 'is-down')),
          cell(t.entry == null ? '—' : fmtPrice(t.entry), 'num'),
          cell(fmtPrice(t.exit), 'num'),
          cell(fmtQty(t.qty), 'num')
        ]);
        tr.className = 'his-row';
        tr.onclick = (function (trip) {
          return function () { flashTrade(trip); };
        })(t);
        hisBody.appendChild(tr);
      }
    }
    if ($('hisEmpty')) $('hisEmpty').hidden = trips.length > 0;

    if (Draw.showTrades) drawSchedule();
  }

  /** 右侧持仓概览：合计市值 / 未实现盈亏 / 保证金，以及合并后的持仓成本。 */
  /**
   * 展示用聚合：同一方向只显示一单。
   * 本地帐号开仓时已经合并；云端老数据可能还是多笔，这里按方向再合一次，
   * 数量/保证金相加，开仓价用总成本除以总数量。平仓仍按原始持仓逐笔平。
   */
  function groupPositions(positions) {
    var groups = {};
    var out = [];
    (positions || []).forEach(function (p) {
      if (!p || (p.side !== 'long' && p.side !== 'short')) return;
      var g = groups[p.side];
      if (!g) {
        g = groups[p.side] = {
          id: p.id, side: p.side, qty: 0, entry: 0,
          margin: 0, openFee: 0, count: 0, cost: 0
        };
        out.push(g);
      }
      var q = +p.qty || 0;
      g.qty += q;
      g.margin += +p.margin || 0;
      g.openFee += +p.openFee || 0;
      g.cost += (+p.entry || 0) * q;
      g.count += 1;
    });
    out.forEach(function (g) {
      g.qty = round6(g.qty);
      g.margin = round6(g.margin);
      g.openFee = round6(g.openFee);
      g.entry = g.qty > 0 ? round(g.cost / g.qty, 8) : 0;
      delete g.cost;
    });
    return out;
  }

  function renderSummary() {
    var a = Account.data;
    if (!a) return;
    var mark = state.price;
    var list = groupPositions(a.positions);

    var box = $('sidePos');
    if (box) {
      box.innerHTML = '';
      list.forEach(function (p) { box.appendChild(sidePosRow(p, mark)); });
    }

    // 没有持仓时整块（明细 + 平仓按钮）都不显示，右侧那点地方留给仓位计算
    var panel = $('sideSummary');
    if (panel) panel.hidden = list.length === 0;

    // 有持仓就锁死方向，反向那一侧点不动
    syncDirLock();
    syncCloseAllBtn();
  }

  /**
   * 持仓明细一行：
   *   第一行：方向 + 开仓金额（USDT）+ 仓位百分比（开仓金额 ÷ 总资产）
   *   第二行：两个小格子 —— 未实现收益的绝对值、收益率
   */
  function sidePosRow(p, mark) {
    var row = document.createElement('div');
    row.className = 'side-pos';

    var tag = document.createElement('span');
    tag.className = 'side-pos__tag ' + (p.side === 'long' ? 'is-up' : 'is-down');
    tag.textContent = p.side === 'long' ? '多' : '空';

    var qty = +p.qty || 0;
    var entry = +p.entry || 0;
    var amount = qty * entry;                      // 开仓金额（USDT）
    var eq = equity(mark) || 0;                    // 总资产
    var posPct = eq > 0 ? (amount / eq) * 100 : 0; // 仓位占总资产的比例
    var value = unrealized(p, mark);               // 绝对收益（USDT）
    var pnlPct = amount > 0 ? (value / amount) * 100 : 0;
    var tone = value > 0 ? 'is-up' : value < 0 ? 'is-down' : '';

    var head = document.createElement('div');
    head.className = 'side-pos__head';

    var main = document.createElement('div');
    main.className = 'side-pos__main';
    var amountEl = document.createElement('b');
    amountEl.textContent = fmtPrice(amount) + ' U';
    amountEl.title = '开仓金额';
    var pctEl = document.createElement('em');
    pctEl.textContent = '仓位 ' + posPct.toFixed(2) + '%';
    pctEl.title = '开仓金额 ÷ 总资产';
    main.appendChild(amountEl);
    main.appendChild(pctEl);
    head.appendChild(tag);
    head.appendChild(main);

    var stats = document.createElement('div');
    stats.className = 'side-pos__stats';

    function stat(label, text, cls, title) {
      var box = document.createElement('div');
      box.className = 'side-pos__stat';
      var name = document.createElement('span');
      name.textContent = label;
      var val = document.createElement('b');
      val.className = cls || '';
      val.textContent = text;
      if (title) val.title = title;
      box.appendChild(name);
      box.appendChild(val);
      return box;
    }

    stats.appendChild(stat('未实现', (value >= 0 ? '+' : '') + group(value, 2), tone, '未实现收益（USDT）'));
    stats.appendChild(stat('收益率', (pnlPct >= 0 ? '+' : '') + pnlPct.toFixed(2) + '%', tone, '未实现收益 ÷ 开仓金额'));

    row.appendChild(head);
    row.appendChild(stats);
    return row;
  }

  function cell(text, cls) {
    var td = document.createElement('td');
    if (cls) td.className = cls;
    td.textContent = text;
    return td;
  }

  function cellBtn(text, onclick, cls) {
    var td = document.createElement('td');
    var b = document.createElement('button');
    b.type = 'button';
    b.className = cls || 'btn-mini';
    b.textContent = text;
    b.onclick = function () { onclick(b); };
    td.appendChild(b);
    return td;
  }

  function row(cells) {
    var tr = document.createElement('tr');
    cells.forEach(function (c) { tr.appendChild(c); });
    return tr;
  }

  /**
   * 按可用余额能下的最大金额（USDT）：手续费也在这笔钱里，所以先除 (1 + FEE)，
   * 再向下取到分，100% 一定下得出去。
   */
  function maxAmount() {
    var a = Account.data;
    if (!a) return 0;
    var max = +a.cash > 0 ? +a.cash / (1 + FEE) : 0;
    return Math.max(0, Math.floor(max * 100) / 100);
  }

  var OpenPctSlider = null;

  /** 0–100% 任意比例滑杆：横线、5 个节点，可点节点也可拖动。 */
  function createPctSlider(id, initial, onChange) {
    var root = $(id);
    if (!root) return null;
    var track = root.querySelector('.pct-slider__track');
    var thumb = root.querySelector('.pct-slider__thumb');
    var bubble = root.querySelector('.pct-slider__bubble');
    var dots = root.querySelectorAll('.pct-slider__dot');
    if (!track || !thumb || !bubble) return null;
    var value = Math.max(0, Math.min(100, +initial || 0));
    var dragging = false;

    function paint(notify) {
      var shown = Math.round(value);
      thumb.style.left = value + '%';
      bubble.textContent = shown + '%';
      root.setAttribute('aria-valuenow', String(shown));
      Array.prototype.forEach.call(dots, function (dot) {
        dot.classList.toggle('is-on', Math.abs((+dot.getAttribute('data-pct') || 0) - shown) < 0.5);
      });
      if (notify && onChange) onChange(value / 100);
    }

    function set(v, notify) {
      value = Math.max(0, Math.min(100, +v || 0));
      paint(notify);
    }

    function fromEvent(e) {
      var r = track.getBoundingClientRect();
      if (!r.width) return value;
      return ((e.clientX - r.left) / r.width) * 100;
    }

    root.addEventListener('pointerdown', function (e) {
      e.preventDefault();
      dragging = true;
      if (root.setPointerCapture) {
        try { root.setPointerCapture(e.pointerId); } catch (err) {}
      }
      set(fromEvent(e), true);
    });
    root.addEventListener('pointermove', function (e) {
      if (dragging) set(fromEvent(e), true);
    });
    function endDrag() {
      if (!dragging) return;
      dragging = false;
    }
    root.addEventListener('pointerup', endDrag);
    root.addEventListener('pointercancel', endDrag);
    root.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') {
        e.preventDefault();
        set(value - 1, true);
      } else if (e.key === 'ArrowRight' || e.key === 'ArrowUp') {
        e.preventDefault();
        set(value + 1, true);
      }
    });
    Array.prototype.forEach.call(dots, function (dot) {
      dot.addEventListener('click', function (e) {
        e.stopPropagation();
        set(+dot.getAttribute('data-pct') || 0, true);
      });
    });
    paint(false);
    return { set: set, get: function () { return value; } };
  }

  function orderPrice() {
    return state.price;
  }

  /** 金额输入框改成 USDT 之后，这里只负责把实时价挂到提示上（其它换算在开仓时做）。 */
  function renderEst() {
    var hint = $('priceHint');
    if (hint) hint.textContent = '当前 ' + fmtPrice(state.price);
  }

  // ---------------------------------------------------------------- 仓位计算
  /**
   * 持仓明细下面的仓位计算（对齐 App 侧边栏底部那套的指标）：
   *   仓位 = 初始资金 × 单笔风险R ÷ 止损距离（R 和止损距离都按百分比填）
   *   杠杆 = 仓位 ÷ 初始资金（这里不填杠杆倍数，直接由仓位倒推）
   * 三个数：
   *   初始资金 —— 默认跟顶部「总资产」走，也可以自己改来当计算器用（标签上「自动」会消失）；
   *               手里有持仓时锁死成总资产，不能改；
   *   单笔风险R —— 填一次就记住（localStorage），刷新页面也不变，除非自己再改；
   *   止损距离 —— 每单都不一样，每次自己填（不记忆，默认 2%）。
   */
  var LS_RISK_R = 'huideng.trade.riskr';
  var CALC_STOP_DEFAULT = '2'; // 止损距离的初始值（不记忆）
  var calcManualCapital = '';  // 手填的初始资金（空 = 跟随总资产）
  var calcWasLocked = false;   // 上一帧是否因为持仓被锁（用来平仓后还回手填值）

  function calcNum(id) {
    var el = $(id);
    if (!el) return 0;
    var n = parseFloat(String(el.value).replace(/[,\s]/g, ''));
    return Number.isFinite(n) && n > 0 ? n : 0;
  }

  /** 顶部「总资产」：现金 + 各持仓占用保证金 + 浮动盈亏。 */
  function calcCapital() {
    var eq = equity(state.price);
    return Number.isFinite(eq) && eq > 0 ? eq : 0;
  }

  function renderPosCalc() {
    var out = $('calcPosition');
    if (!out) return;

    var eq = calcCapital();
    var hasPos = ((Account.data && Account.data.positions) || []).length > 0;
    var capEl = $('calcCapital');
    var focused = capEl && document.activeElement === capEl;

    if (capEl) {
      capEl.readOnly = hasPos;
      capEl.classList.toggle('is-locked', hasPos);
      if (hasPos) {
        capEl.value = eq > 0 ? group(eq, 2) : '0.00';       // 有持仓：锁死跟总资产
      } else if (!calcManualCapital) {
        if (!focused) capEl.value = eq > 0 ? group(eq, 2) : '0.00'; // 没手改过：跟着总资产
      } else if (calcWasLocked) {
        capEl.value = calcManualCapital;                     // 刚平完仓：把手填的值还回去
      }
    }

    var tag = $('calcAutoTag');
    if (tag) tag.hidden = hasPos || !!calcManualCapital;
    calcWasLocked = hasPos;

    var capital;
    if (hasPos || !calcManualCapital) capital = eq;
    else capital = Math.max(0, parseFloat(String(calcManualCapital).replace(/[,\s]/g, '')) || 0);

    var risk = calcNum('calcRisk');
    var stop = calcNum('calcStop');

    var position = capital > 0 && risk > 0 && stop > 0 ? (capital * risk) / stop : 0;
    out.textContent = position > 0 ? group(position, 2) : '0';
    out.classList.toggle('has-result', position > 0);

    var lev = capital > 0 && position > 0 ? position / capital : 0;
    var levEl = $('calcLeverage');
    if (levEl) {
      levEl.textContent = lev > 0 ? lev.toFixed(2) + 'x' : '--';
      levEl.classList.toggle('has-result', lev > 0);
    }

    // 按当前价折成「数量 (BTC)」，照抄进上面的下单框就是算出来的仓位
    var qtyEl = $('calcQty');
    if (qtyEl) {
      var p = state.price;
      qtyEl.textContent = position > 0 && p > 0 ? '≈ ' + fmtQty(position / p) + ' BTC' : '';
    }
  }

  function initPosCalc() {
    var cap = $('calcCapital');
    var risk = $('calcRisk');
    var stop = $('calcStop');
    if (!risk || !stop) return;

    // 单笔风险R：用上次填过的值，没有才用 2
    var savedRisk = parseFloat(readLS(LS_RISK_R));
    risk.value = Number.isFinite(savedRisk) && savedRisk > 0 ? String(round(savedRisk, 2)) : '2';
    if (!stop.value) stop.value = CALC_STOP_DEFAULT;

    // 初始资金：手改就固定下来，清空又回到「跟总资产」
    if (cap) {
      cap.addEventListener('input', function () {
        if (cap.readOnly) return;
        calcManualCapital = String(cap.value).trim();
        renderPosCalc();
      });
      cap.addEventListener('change', function () {
        if (cap.readOnly) return;
        var n = parseFloat(String(cap.value).replace(/[,\s]/g, ''));
        if (!Number.isFinite(n) || n <= 0) {
          calcManualCapital = '';
        } else {
          calcManualCapital = String(round(n, 2));
          cap.value = calcManualCapital;
        }
        renderPosCalc();
      });
    }

    risk.addEventListener('input', function () {
      var n = parseFloat(String(risk.value).replace(/[,\s]/g, ''));
      if (Number.isFinite(n) && n > 0) writeLS(LS_RISK_R, String(n));
      renderPosCalc();
    });
    // 改完（回车 / 失焦）规整一下；清空或填 0 就退回记住的那个值
    risk.addEventListener('change', function () {
      var n = parseFloat(String(risk.value).replace(/[,\s]/g, ''));
      if (!Number.isFinite(n) || n <= 0) {
        var saved = parseFloat(readLS(LS_RISK_R));
        n = Number.isFinite(saved) && saved > 0 ? saved : 2;
      }
      risk.value = String(round(n, 2));
      writeLS(LS_RISK_R, String(round(n, 2)));
      renderPosCalc();
    });

    stop.addEventListener('input', renderPosCalc);
    stop.addEventListener('change', function () {
      var n = parseFloat(String(stop.value).replace(/[,\s]/g, ''));
      if (!Number.isFinite(n) || n < 0) stop.value = '';
      else stop.value = String(round(n, 2));
      renderPosCalc();
    });

    renderPosCalc();
  }

  // ---------------------------------------------------------------- 下单交互
  var orderSide = 'long';   // 方向条当前选的是看多还是看空
  var orderLockSide = '';   // 有持仓时只能加同一方向：'' 不锁 / 'long' / 'short'
  var placing = false;      // 「开仓」请求进行中，避免连点

  /** 各方向还有多少持仓（同方向多笔已经合并过，这里再兜一层）。 */
  function positionSides() {
    var out = { long: 0, short: 0 };
    ((Account.data && Account.data.positions) || []).forEach(function (p) {
      if (p.side === 'long') out.long += +p.qty || 0;
      else if (p.side === 'short') out.short += +p.qty || 0;
    });
    return out;
  }

  /**
   * 有持仓时锁方向：手里有多单就只能继续开多，有空单就只能继续开空，
   * 另一侧按钮置灰点不动（反向开单被禁掉）。
   */
  function syncDirLock() {
    var sides = positionSides();
    var lock = '';
    if (sides.long > 0 && sides.short <= 0) lock = 'long';
    else if (sides.short > 0 && sides.long <= 0) lock = 'short';
    orderLockSide = lock;

    var seg = $('dirSeg');
    if (!seg) return;
    if (lock && orderSide !== lock) setOrderSide(lock);
    Array.prototype.forEach.call(seg.querySelectorAll('button[data-side]'), function (b) {
      var side = b.getAttribute('data-side');
      var blocked = !!lock && side !== lock;
      b.disabled = blocked;
      b.title = blocked
        ? (lock === 'long' ? '手里有多单，只能继续开多' : '手里有空单，只能继续开空')
        : '';
    });
    seg.classList.toggle('is-locked', !!lock);
  }

  /** 切方向：胶囊里的滑块滑到左 / 右，选中一侧是浅红（多）或浅绿（空）。 */
  function setOrderSide(side) {
    if (orderLockSide && side !== orderLockSide) side = orderLockSide;
    orderSide = side === 'short' ? 'short' : 'long';
    var seg = $('dirSeg');
    if (!seg) return;
    seg.setAttribute('data-side', orderSide);
    Array.prototype.forEach.call(seg.querySelectorAll('button[data-side]'), function (b) {
      var on = b.getAttribute('data-side') === orderSide;
      b.classList.toggle('is-on', on);
      b.setAttribute('aria-checked', on ? 'true' : 'false');
    });
  }

  /** 方向胶囊：点一下切换，按住左右滑也能切，键盘左右键同样可以。 */
  function initDirSeg() {
    var seg = $('dirSeg');
    if (!seg) return;
    setOrderSide(orderSide);

    function pickAt(clientX) {
      var r = seg.getBoundingClientRect();
      if (!r.width) return;
      setOrderSide(clientX < r.left + r.width / 2 ? 'long' : 'short');
    }

    var dragging = false;
    seg.addEventListener('pointerdown', function (e) {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      dragging = true;
      pickAt(e.clientX);
      if (seg.setPointerCapture) {
        try { seg.setPointerCapture(e.pointerId); } catch (err) {}
      }
    });
    seg.addEventListener('pointermove', function (e) {
      if (!dragging) return;
      pickAt(e.clientX);
    });
    function stopDrag() { dragging = false; }
    seg.addEventListener('pointerup', stopDrag);
    seg.addEventListener('pointercancel', stopDrag);

    seg.addEventListener('click', function (e) {
      var b = e.target && e.target.closest ? e.target.closest('button[data-side]') : null;
      if (b) setOrderSide(b.getAttribute('data-side'));
    });
    seg.addEventListener('keydown', function (e) {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      e.preventDefault();
      setOrderSide(e.key === 'ArrowRight' ? 'short' : 'long');
    });
  }

  /**
   * 开仓：输入的是**金额（USDT）**，按当前价换算成 BTC 数量再下单。
   * 数量向下取到 6 位，避免四舍五入后比余额多一点点。
   */
  function doOpen(side, btn) {
    if (!isTradingSymbol()) return; // 看其他币时按钮是置灰的，这里再兜一层
    var field = $('fAmount');
    var amount = parseFloat(String(field ? field.value : '').replace(/[,\s]/g, ''));
    var price = state.price;

    if (!Number.isFinite(price) || price <= 0) {
      toast('行情还没连上，稍等一下再下单');
      return;
    }
    if (!Number.isFinite(amount) || amount <= 0) {
      toast('请填写金额');
      if (field) field.focus();
      return;
    }
    var qty = Math.floor((amount / price) * 1e6) / 1e6;
    if (!(qty > 0)) {
      toast('金额太小，不够 0.000001 BTC');
      return;
    }

    // 反向开单：手里有多单就不许开空，反之亦然（只能在原方向上继续加）
    var sides = positionSides();
    if (side === 'long' && sides.short > 0 && sides.long <= 0) {
      toast('手里有空单，只能继续开空');
      syncDirLock();
      return;
    }
    if (side === 'short' && sides.long > 0 && sides.short <= 0) {
      toast('手里有多单，只能继续开多');
      syncDirLock();
      return;
    }

    placing = true;
    if (btn) btn.disabled = true;
    place({ kind: 'market', side: side, qty: qty, price: price }).then(function () {
      toast('已开仓 ' + fmtQty(qty) + ' BTC（' + fmtPrice(amount) + ' USDT）');
      if (field) field.value = '';
      renderEst();
    }).catch(showErr).then(function () {
      placing = false;
      updateOrderUI();
    });
  }

  function positionById(id) {
    var list = (Account.data && Account.data.positions) || [];
    for (var i = 0; i < list.length; i += 1) {
      if (list[i].id === id) return list[i];
    }
    return null;
  }

  // 全部平仓进行中（避免连点重复提交）
  var closingAll = false;

  /** 「平仓」按钮的可用状态：有持仓、有行情、看的是 BTC 才让点。 */
  function syncCloseAllBtn() {
    var btn = $('btnCloseAll');
    if (!btn) return;
    var has = ((Account.data && Account.data.positions) || []).length > 0;
    btn.disabled = closingAll || !has || !state.price || !isTradingSymbol();
  }

  /**
   * 持仓明细下面的「平仓」：不再按比例 / 数量平，
   * 直接按当前价把手里所有持仓 100% 平掉。
   */
  function closeAllPositions(btn) {
    if (!isTradingSymbol()) { toast('切回 BTC 才能平仓'); return; }
    var a = Account.data;
    var list = (a && a.positions) || [];
    if (!list.length) { toast('暂无持仓'); return; }
    if (!state.price) { toast('行情还没连上，稍等一下再平'); return; }
    if (closingAll) return;

    var price = state.price;
    var total = 0;
    list.forEach(function (p) { total += +p.qty || 0; });

    closingAll = true;
    if (btn) btn.disabled = true;

    var chain = Promise.resolve();
    list.slice().forEach(function (p) {
      chain = chain.then(function () { return closePos(p.id, price, 1); });
    });
    chain.then(function () {
      toast('已全部平仓 ' + fmtQty(total) + ' BTC');
    }).catch(showErr).then(function () {
      closingAll = false;
      syncCloseAllBtn();
    });
  }

  function doCancel(id) {
    cancel(id).then(function () { toast('已撤单'); }).catch(showErr);
  }

  // ---------------------------------------------------------------- 弹窗
  function openModal() {
    var m = $('authModal');
    if (!m) return;
    m.hidden = false;
    $('authErr').textContent = '';
    syncAuthMode();
    setTimeout(function () {
      var first = authMode() === 'register' ? $('aPhone') : $('aUser');
      if (first) first.focus();
    }, 30);
  }

  function closeModal() {
    var m = $('authModal');
    if (m) m.hidden = true;
    // 关掉登录框（取消/点空白）就不再惦记「登录后去笔记页」，避免下次登录被带走。
    pendingNotes = false;
    pendingNotesSlide = false;
  }

  // ------------------------------------------------- 绑定手机 / 找回密码
  //
  // 短信验证码由云函数用云开发的验证码服务发出（App 登录用的同一套），
  // 这里只负责收手机号、倒计时、把 id+验证码回传。两个场景：
  //   bind  —— 已登录，把手机号绑到当前账号（之后能用它重置密码）
  //   reset —— 未登录，验证手机号后直接改密码，再用新密码登录
  var Phone = { scene: 'bind', id: '', phone: '', bound: '', timer: 0 };

  function setAuthMode(mode) {
    var b = document.querySelector('#authSeg button[data-mode="' + mode + '"]');
    if (b && !b.classList.contains('is-on')) b.click();
  }

  function openPhone(scene) {
    var m = $('phoneModal');
    if (!m) return;
    Phone.scene = scene === 'reset' ? 'reset' : 'bind';
    Phone.id = '';
    Phone.phone = '';
    Phone.bound = (Account.data && Account.data.phone) || Phone.bound || '';
    if (Phone.timer) { clearInterval(Phone.timer); Phone.timer = 0; }
    var changing = Phone.scene === 'bind' && !!Phone.bound;
    $('phoneTitle').textContent = Phone.scene === 'reset'
      ? '找回密码'
      : changing
        ? '更换手机号'
        : '绑定手机号';
    $('phoneIntro').textContent = Phone.scene === 'reset'
      ? '用绑定过的手机号收验证码；验证通过后直接设置新密码，再用新密码登录。'
      : changing
        ? '当前绑定 ' + Phone.bound + '。验证新手机号后会替换旧号码，旧号码自动解绑。'
        : '绑定后可以用短信验证码重置密码，忘了密码不至于找不回来。';
    $('pPwdField').hidden = Phone.scene !== 'reset';
    $('pErr').textContent = '';
    $('pPhone').value = '';
    $('pPhone').placeholder = changing ? '新手机号' : '11 位手机号';
    $('pCode').value = '';
    $('pNewPwd').value = '';
    $('pHint').textContent = '先填手机号';
    $('pSend').disabled = false;
    $('pSend').textContent = '获取验证码';
    $('pSubmit').textContent = Phone.scene === 'reset' ? '重置密码' : Phone.bound ? '更换' : '绑定';
    m.hidden = false;
    setTimeout(function () { $('pPhone').focus(); }, 30);
  }

  function closePhone() {
    var m = $('phoneModal');
    if (m) m.hidden = true;
    if (Phone.timer) { clearInterval(Phone.timer); Phone.timer = 0; }
  }

  function phoneDigits() {
    return ($('pPhone').value || '').replace(/[\s()\-]/g, '');
  }

  function sendPhoneCode() {
    var phone = phoneDigits();
    var err = $('pErr');
    err.textContent = '';
    if (!/^1[3-9]\d{9}$/.test(phone)) { err.textContent = '请填 11 位手机号'; return; }
    var btn = $('pSend');
    btn.disabled = true;
    btn.textContent = '发送中…';
    api('tradePhoneCode', { phone: phone, scene: Phone.scene }).then(function (j) {
      Phone.id = j.id || phone;
      Phone.phone = phone;
      toast('验证码已发到 ' + (j.display || phone));
      var left = 60;
      btn.textContent = left + 's';
      Phone.timer = setInterval(function () {
        left -= 1;
        if (left <= 0) {
          clearInterval(Phone.timer);
          Phone.timer = 0;
          btn.disabled = false;
          btn.textContent = '重新获取';
        } else {
          btn.textContent = left + 's';
        }
      }, 1000);
    }).catch(function (e) {
      btn.disabled = false;
      btn.textContent = '获取验证码';
      err.textContent = msgOf(e && e.code);
    });
  }

  function submitPhone() {
    var err = $('pErr');
    var code = ($('pCode').value || '').trim();
    err.textContent = '';
    if (!Phone.id) { err.textContent = '请先点「获取验证码」'; return; }
    if (!/^\d{4,8}$/.test(code)) { err.textContent = '请填收到的验证码'; return; }
    var body = { id: Phone.id, code: code, scene: Phone.scene };
    if (Phone.scene === 'reset') {
      var pwd = $('pNewPwd').value;
      if (pwd.length < 6) { err.textContent = '新密码至少 6 位'; return; }
      body.newPassword = pwd;
    }
    var btn = $('pSubmit');
    btn.disabled = true;
    api('tradePhoneConfirm', body).then(function (j) {
      var scene = Phone.scene;
      var wasBound = !!Phone.bound;
      var boundPhone = j.phone || '';
      closePhone();
      if (scene === 'reset') {
        toast('密码已重置，请用新密码登录');
        openModal();
        setAuthMode('login');
        if (j.username) $('aUser').value = j.username;
        $('aPass').value = '';
        $('aPass').focus();
      } else {
        Phone.bound = boundPhone;
        if (Account.data) Account.data.phone = boundPhone;
        renderAccountMenu();
        toast(wasBound ? '手机号已更换' : (boundPhone ? '已绑定 ' + boundPhone : '手机号已绑定'));
      }
    }).catch(function (e) {
      err.textContent = msgOf(e && e.code);
    }).then(function () { btn.disabled = false; });
  }

  function authMode() {
    var b = document.querySelector('#authSeg button.is-on');
    return b ? b.getAttribute('data-mode') : 'login';
  }

  // 注册 tab 里的手机号注册：手机号 + 验证码 + 密码，账号名可留空（服务端自动生成）
  var AuthCode = { id: '', phone: '', timer: 0 };

  function authPhone() {
    var el = $('aPhone');
    return el ? (el.value || '').replace(/[\s()\-]/g, '') : '';
  }

  function syncAuthMode() {
    var register = authMode() === 'register';
    var box = $('regOnly');
    if (box) box.hidden = !register;
    var forgot = $('btnForgot');
    if (forgot) forgot.hidden = register;
    var u = $('aUser');
    if (u) {
      u.placeholder = register
        ? '账号名（可留空，自动生成）'
        : '2-20 位中文、字母、数字或下划线';
    }
  }

  function sendAuthCode() {
    var phone = authPhone();
    var box = $('authErr');
    box.textContent = '';
    if (!/^1[3-9]\d{9}$/.test(phone)) { box.textContent = '请填 11 位手机号'; return; }
    var btn = $('aSend');
    btn.disabled = true;
    btn.textContent = '发送中…';
    api('tradePhoneCode', { phone: phone, scene: 'register' }).then(function (j) {
      AuthCode.id = j.id || phone;
      AuthCode.phone = phone;
      toast('验证码已发到 ' + (j.display || phone));
      var left = 60;
      btn.textContent = left + 's';
      AuthCode.timer = setInterval(function () {
        left -= 1;
        if (left <= 0) {
          clearInterval(AuthCode.timer);
          AuthCode.timer = 0;
          btn.disabled = false;
          btn.textContent = '重新获取';
        } else {
          btn.textContent = left + 's';
        }
      }, 1000);
    }).catch(function (e) {
      btn.disabled = false;
      btn.textContent = '获取验证码';
      box.textContent = msgOf(e && e.code);
    });
  }

  function submitAuth() {
    var mode = authMode();
    var u = $('aUser').value.trim();
    var p = $('aPass').value;
    var box = $('authErr');
    var btn = $('authSubmit');
    box.textContent = '';
    if (p.length < 6) { box.textContent = '密码至少 6 位'; return; }

    var phone = authPhone();
    if (mode === 'register' && phone) {
      var code = ($('aCode').value || '').trim();
      if (!AuthCode.id) { box.textContent = '请先点「获取验证码」'; return; }
      if (!/^\d{4,8}$/.test(code)) { box.textContent = '请填收到的验证码'; return; }
      btn.disabled = true;
      btn.textContent = '提交中…';
      api('tradePhoneConfirm', {
        id: AuthCode.id,
        code: code,
        scene: 'register',
        password: p,
        username: u
      }).then(function (j) {
        Account.token = j.token;
        Account.username = j.username || u;
        Account.mode = 'cloud';
        writeLS(LS.token, j.token);
        writeLS(LS.user, Account.username);
        return api('tradeState', {});
      }).then(function (j) {
        Account.data = j.account;
        closeModal();
        renderAll();
        cloudDrawPull();
        toast('注册成功，你的账号是 ' + Account.username);
      }).catch(function (e) {
        box.textContent = msgOf(e && e.code);
      }).then(function () {
        btn.disabled = false;
        btn.textContent = '注册并登录';
      });
      return;
    }

    if (!u) { box.textContent = '请填写账号'; return; }
    btn.disabled = true;
    btn.textContent = '提交中…';
    doAuth(mode, u, p).catch(function (e) {
      box.textContent = msgOf(e && e.code);
    }).then(function () {
      btn.disabled = false;
      btn.textContent = mode === 'register' ? '注册并登录' : '登录';
    });
  }

  // ---------------------------------------------------------------- 事件绑定
  /** 走势图和右侧面板之间的分隔条：拖动改宽度，双击恢复默认。 */
  function initSplit() {
    var panel = $('deskPanel');
    var side = $('deskSide');
    var split = $('deskSplit');
    if (!panel || !side || !split || !split.addEventListener) return;
    if (typeof side.getBoundingClientRect !== 'function' || typeof panel.getBoundingClientRect !== 'function') return;
    var MIN = 270;
    var MAX = 720;
    var cur = side.getBoundingClientRect().width || 288;
    var saved = parseFloat(readLS('huideng.trade.sidew'));
    if (saved >= MIN && saved <= MAX) cur = saved;

    function clampW(w) {
      var pw = panel.getBoundingClientRect().width || 1024;
      var max = Math.min(MAX, pw - 460);
      if (max < MIN) max = MIN;
      return Math.max(MIN, Math.min(max, w));
    }

    function apply(w, persist) {
      w = clampW(w);
      cur = w;
      panel.style.setProperty('--side-w', w + 'px');
      split.setAttribute('aria-valuenow', String(Math.round(w)));
      if (persist) writeLS('huideng.trade.sidew', String(Math.round(w)));
      paintChartBg();
    }

    apply(cur, false);

    var drag = null;
    split.addEventListener('pointerdown', function (e) {
      if (e.button !== 0) return;
      e.preventDefault();
      drag = { x: e.clientX, w: side.getBoundingClientRect().width };
      split.classList.add('is-drag');
      document.body.style.userSelect = 'none';
      if (split.setPointerCapture) {
        try { split.setPointerCapture(e.pointerId); } catch (err) {}
      }
    });

    window.addEventListener('pointermove', function (e) {
      if (!drag) return;
      apply(drag.w + drag.x - e.clientX, false);
    });

    function endDrag() {
      if (!drag) return;
      drag = null;
      split.classList.remove('is-drag');
      document.body.style.userSelect = '';
      apply(cur, true);
      drawResize();
    }
    window.addEventListener('pointerup', endDrag);
    window.addEventListener('pointercancel', endDrag);

    split.addEventListener('dblclick', function () {
      apply(288, true);
    });

    window.addEventListener('resize', function () {
      if (side.classList.contains('is-hidden')) return;
      apply(side.getBoundingClientRect().width, false);
    });
  }

  /**
   * 走势图 / 持仓区之间的横向分隔条：上下拖动改变持仓区高度（也就是走势图高度），
   * 拖完写入 localStorage，下次打开直接恢复。
   * 底部持仓区已经去掉（持仓看右侧、历史记录看右下角悬浮按钮），这里没有元素就直接返回。
   */
  function initHSplit() {
    var main = $('main');
    var pos = $('posPanel');
    var split = $('deskHSplit');
    if (!main || !pos || !split || !split.addEventListener) return;
    if (split.offsetParent === null) return; // 窄屏隐藏了分隔条
    if (typeof main.getBoundingClientRect !== 'function' || typeof pos.getBoundingClientRect !== 'function') return;

    // 允许一直缩到只剩「持仓 / 历史记录」两个标签
    var MIN = 48;
    var MAX = 620;
    var KEY = 'huideng.trade.posh';
    var cur = 0;

    function mainH() {
      return main.getBoundingClientRect().height || 0;
    }

    function clampH(h) {
      var mh = mainH();
      var max = Math.min(MAX, Math.max(MIN, mh - 260));
      return Math.max(MIN, Math.min(max, h));
    }

    function apply(h, persist) {
      h = clampH(h);
      cur = h;
      pos.style.flex = '0 0 ' + h + 'px';
      split.setAttribute('aria-valuenow', String(Math.round(h)));
      split.setAttribute('aria-valuemax', String(Math.round(Math.min(MAX, Math.max(MIN, mainH() - 260)))));
      if (persist) writeLS(KEY, String(Math.round(h)));
      drawResize();
      paintChartBg();
    }

    var saved = parseFloat(readLS(KEY));
    if (saved >= MIN) cur = saved;
    if (!cur) cur = pos.getBoundingClientRect().height || 200;
    apply(cur, false);

    var drag = null;
    split.addEventListener('pointerdown', function (e) {
      if (e.button !== 0) return;
      e.preventDefault();
      drag = { y: e.clientY, h: pos.getBoundingClientRect().height };
      split.classList.add('is-drag');
      document.body.style.userSelect = 'none';
      if (split.setPointerCapture) {
        try { split.setPointerCapture(e.pointerId); } catch (err) {}
      }
    });

    window.addEventListener('pointermove', function (e) {
      if (!drag) return;
      apply(drag.h + drag.y - e.clientY, false);
    });

    function endDrag() {
      if (!drag) return;
      drag = null;
      split.classList.remove('is-drag');
      document.body.style.userSelect = '';
      apply(cur, true);
    }
    window.addEventListener('pointerup', endDrag);
    window.addEventListener('pointercancel', endDrag);

    split.addEventListener('dblclick', function () {
      apply(Math.max(MIN, Math.min(240, mainH() * 0.2)), true);
    });

    window.addEventListener('resize', function () {
      apply(pos.getBoundingClientRect().height, false);
    });
  }

  function bind() {
    // 图表工具条：均线增删改、成交量 / MACD 开关、右键菜单
    bindChartTools();

    // 手机手势：双击加均线、右边缘长按压扁、右下角全屏
    bindChartGestures();

    // 走势图币种搜索
    bindSymbolSearch();

    // 持仓概览下面的仓位计算
    initPosCalc();

    // 周期
    var tf = $('tf');
    if (tf) {
      tf.addEventListener('click', function (e) {
        var b = e.target.closest('button[data-iv]');
        if (!b) return;
        var iv = b.getAttribute('data-iv');
        if (iv === state.iv) return;
        Array.prototype.forEach.call(tf.querySelectorAll('button'), function (x) { x.classList.remove('is-on'); });
        b.classList.add('is-on');
        switchInterval(iv);
      });
    }

    // 方向胶囊（看多 / 看空，可点可滑）+ 唯一的「开仓」按钮
    initDirSeg();
    var openBtn = $('btnOpen');
    if (openBtn) {
      openBtn.addEventListener('click', function () { doOpen(orderSide, openBtn); });
    }

    // 持仓明细下面的「平仓」：全部 100% 平掉
    var closeAllBtn = $('btnCloseAll');
    if (closeAllBtn) {
      closeAllBtn.addEventListener('click', function () { closeAllPositions(closeAllBtn); });
    }
    updateOrderUI();

    // 金额 (USDT) + 任意比例滑杆（比例按可用余额算）
    // 输入框只放数字（右边「USDT」是单独的灰色小字，不参与编辑）
    var fAmount = $('fAmount');
    function amountText(n) {
      return Number.isFinite(n) && n > 0 ? n.toFixed(2) : '';
    }
    if (fAmount) {
      fAmount.addEventListener('blur', function () {
        var n = parseFloat(String(fAmount.value).replace(/[,\sU]/gi, ''));
        fAmount.value = amountText(n);
      });
      fAmount.addEventListener('input', function () {
        renderEst();
        if (OpenPctSlider) {
          var max = maxAmount();
          var amt = parseFloat(String(fAmount.value).replace(/[,\sU]/gi, '')) || 0;
          OpenPctSlider.set(max > 0 ? (amt / max) * 100 : 0, false);
        }
      });
    }

    OpenPctSlider = createPctSlider('openPctSlider', 0, function (ratio) {
      var a = Account.data;
      if (!a || !fAmount) return;
      // 比例是「可用余额的比例」，手续费也含在这笔钱里
      var amt = Math.floor((a.cash * ratio) / (1 + FEE) * 100) / 100;
      fAmount.value = amt > 0 ? amt.toFixed(2) : '0';
      renderEst();
    });

    // 走势图右下角的「历史」悬浮按钮 → 贴着走势图右边界往左滑出历史记录
    var hisFab = $('btnHisSlide');
    var hisSlide = $('hisSlide');

    /** 面板右边界对齐走势图右边界（右侧面板被收起时就贴到页面右边）。 */
    function placeHisSlide() {
      if (!hisSlide) return;
      var chart = $('chartWrap');
      var right = 0;
      if (chart && chart.getBoundingClientRect) {
        right = (window.innerWidth || 0) - chart.getBoundingClientRect().right;
      }
      if (!(right > 0)) right = 0;
      hisSlide.style.right = Math.max(0, Math.round(right)) + 'px';
    }

    function openHisSlide() {
      if (!hisSlide) return;
      placeHisSlide();
      renderTables();
      hisSlide.classList.add('is-open');
      hisSlide.setAttribute('aria-hidden', 'false');
      if (hisFab) {
        hisFab.classList.add('is-on');
        hisFab.setAttribute('aria-expanded', 'true');
      }
    }
    function closeHisSlide() {
      if (!hisSlide) return;
      hisSlide.classList.remove('is-open');
      hisSlide.setAttribute('aria-hidden', 'true');
      if (hisFab) {
        hisFab.classList.remove('is-on');
        hisFab.setAttribute('aria-expanded', 'false');
      }
    }
    if (hisFab) {
      hisFab.addEventListener('click', function () {
        if (hisSlide && hisSlide.classList.contains('is-open')) closeHisSlide();
        else openHisSlide();
      });
    }
    var hisClose = $('hisSlideClose');
    if (hisClose) hisClose.addEventListener('click', closeHisSlide);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeHisSlide();
    });
    placeHisSlide(); // 没展开也先钉在走势图右边界，折叠动画不会越界
    window.addEventListener('resize', function () {
      placeHisSlide();
    });

    // 右侧面板折叠 / 展开（周期栏最右边的 TRADE）
    var tradeTab = $('tradeTab');
    if (tradeTab) {
      tradeTab.addEventListener('click', function () {
        var side = $('deskSide');
        if (!side) return;
        var hidden = side.classList.toggle('is-hidden');
        tradeTab.setAttribute('aria-expanded', hidden ? 'false' : 'true');
        tradeTab.title = hidden ? '展开右侧面板' : '收起右侧面板';
        var split = $('deskSplit');
        if (split) split.hidden = hidden;
        paintChartBg();
      });
    }

    initSplit();
    initHSplit();

    // 账户：登录 / 绑定手机 / 退出都收进右上角头像菜单
    var menuBtn = $('btnMenu');
    if (menuBtn) {
      menuBtn.addEventListener('click', function (e) {
        e.stopPropagation();
        var menu = $('acctMenu');
        if (!menu) return;
        var willOpen = menu.hidden;
        closeMenus();
        if (willOpen) {
          menu.hidden = false;
          menuBtn.setAttribute('aria-expanded', 'true');
        }
      });
    }

    // 交易笔记子页面：右下角按钮打开/关闭
    var notesBtn = $('btnNotes');
    if (notesBtn) notesBtn.addEventListener('click', toggleNotesSlide);

    var notesClose = $('notesSlideClose');
    if (notesClose) notesClose.addEventListener('click', closeNotesSlide);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeNotesSlide();
    });

    var avatarInput = $('avatarInput');
    if (avatarInput) {
      avatarInput.addEventListener('change', function () {
        setTradeAvatar(avatarInput.files && avatarInput.files[0]);
      });
    }

    var acctMenu = $('acctMenu');
    if (acctMenu) {
      acctMenu.addEventListener('click', function (e) {
        var b = e.target && e.target.closest ? e.target.closest('button[data-act]') : null;
        if (!b) return;
        var act = b.getAttribute('data-act');
        closeMenus();
        if (act === 'avatar') {
          var avInput = $('avatarInput');
          if (avInput) {
            avInput.value = '';
            avInput.click();
          }
        }
        else if (act === 'login') openModal();
        else if (act === 'phone') openPhone('bind');
        else if (act === 'sync') syncAccount();
        else if (act === 'reset') openReset();
        else if (act === 'logout') {
          closeNotesSlide();
          resetNotesFrame();
          cloudDrawFlush();
          dropAuth();
          toast('已退出，回到本机账户');
        }
      });
    }

    // 滚动/缩放后浮层还停在原地就错位了，直接收起
    window.addEventListener('resize', function () {
      closeMenus();
      updatePriceTag();
    });
    window.addEventListener('scroll', function () { closeMenus(); }, true);
    // 关浏览器 / 切后台离开时，把画线一次性推到云端（不会反复同步）
    window.addEventListener('pagehide', cloudDrawFlush);
    window.addEventListener('beforeunload', cloudDrawFlush);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden') cloudDrawFlush();
    });

    // 点空白处关掉浮层；点工具条按钮本身不关（否则刚开就被关）
    document.addEventListener('click', function (e) {
      var t = e.target;
      if (t && t.closest) {
        if (
          t.closest('#maPop') || t.closest('#ctxMenu') || t.closest('#lineMenu') ||
          t.closest('#acctMenu') || t.closest('#btnMenu') || t.closest('#maTools') ||
          t.closest('#dirSeg') || t.closest('#btnOpen') || t.closest('#btnCloseAll') ||
          t.closest('#btnHisSlide') || t.closest('#hisSlide')
        ) return;
      }
      closeMenus();
    });

    // 弹窗
    var seg = $('authSeg');
    if (seg) seg.addEventListener('click', function (e) {
      var b = e.target.closest('button[data-mode]');
      if (!b) return;
      Array.prototype.forEach.call(seg.querySelectorAll('button'), function (x) { x.classList.remove('is-on'); });
      b.classList.add('is-on');
      var m = b.getAttribute('data-mode');
      $('authSubmit').textContent = m === 'register' ? '注册并登录' : '登录';
      $('authErr').textContent = '';
      syncAuthMode();
    });
    var cancelBtn = $('authCancel');
    if (cancelBtn) cancelBtn.onclick = closeModal;
    var submitBtn = $('authSubmit');
    if (submitBtn) submitBtn.onclick = submitAuth;
    var modal = $('authModal');
    if (modal) modal.addEventListener('click', function (e) { if (e.target === modal) closeModal(); });

    // 找回密码 / 绑定手机
    var forgot = $('btnForgot');
    if (forgot) forgot.onclick = function () { closeModal(); openPhone('reset'); };
    var pSend = $('pSend');
    if (pSend) pSend.onclick = sendPhoneCode;
    var pCancel = $('pCancel');
    if (pCancel) pCancel.onclick = closePhone;
    var pSubmit = $('pSubmit');
    if (pSubmit) pSubmit.onclick = submitPhone;
    var phoneModal = $('phoneModal');
    if (phoneModal) phoneModal.addEventListener('click', function (e) {
      if (e.target === phoneModal) closePhone();
    });
    var pPhone = $('pPhone');
    if (pPhone) pPhone.addEventListener('input', function () {
      var hint = $('pHint');
      if (hint) hint.textContent = /^1[3-9]\d{9}$/.test(phoneDigits()) ? '可发送' : '先填手机号';
    });

    // 注册 tab 里的手机号注册
    var aSend = $('aSend');
    if (aSend) aSend.onclick = sendAuthCode;
    var aPhone = $('aPhone');
    if (aPhone) aPhone.addEventListener('input', function () {
      var hint = $('aHint');
      if (hint) hint.textContent = /^1[3-9]\d{9}$/.test(authPhone()) ? '可发送' : '先填手机号';
    });
    syncAuthMode();

    // 重置资金：默认 10 万，可改金额或点快捷额度
    var resetCancel = $('resetCancel');
    if (resetCancel) resetCancel.onclick = closeReset;
    var resetSubmit = $('resetSubmit');
    if (resetSubmit) resetSubmit.onclick = doReset;
    var resetModal = $('resetModal');
    if (resetModal) resetModal.addEventListener('click', function (e) {
      if (e.target === resetModal) closeReset();
    });
    var resetQuick = $('resetQuick');
    if (resetQuick) resetQuick.addEventListener('click', function (e) {
      var b = e.target && e.target.closest ? e.target.closest('button[data-amount]') : null;
      if (!b) return;
      if ($('resetAmount')) $('resetAmount').value = b.getAttribute('data-amount');
      if ($('resetErr')) $('resetErr').textContent = '';
    });
    var resetAmount = $('resetAmount');
    if (resetAmount) resetAmount.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); doReset(); }
    });

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') {
        closeModal();
        closePhone();
        closeReset();
        closeMenus();
      }
      if (e.key === 'Enter' && document.activeElement && /aUser|aPass|aPhone|aCode/.test(document.activeElement.id)) submitAuth();
      if (e.key === 'Enter' && document.activeElement && /pPhone|pCode|pNewPwd/.test(document.activeElement.id)) submitPhone();
    });

    // 页面可见性 / 网络切换：不依赖浏览器一定给我们 onclose。
    // 切到后台直接断掉（后台的定时器会被冻结，留着只会变成假死连接），
    // 回前台立刻重连并补 K 线，手机上不用等看门狗那 12 秒。
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) {
        wsAbort();
        stopPoll();
        stopSynthPoll();
        return;
      }
      WS.fails = 0;
      startPoll();   // 先把行情续上，WS 连上会自动停
      wsConnect();
      healBars();
    });

    window.addEventListener('online', function () {
      WS.fails = 0;
      startPoll();
      wsConnect();
      healBars();
    });

    window.addEventListener('offline', function () {
      setSource('down', '网络已断开，等待恢复…');
    });

    // iOS/安卓从 bfcache 回退时 JS 状态还在，但 socket 早断了
    window.addEventListener('pageshow', function (e) {
      if (!e.persisted) return;
      WS.fails = 0;
      wsConnect();
      healBars();
    });

    bindAppPane();
  }

  // ---------------------------------------------------------------- 燃灯页
  //
  // 顶部导航固定不动，行情 / 燃灯是并排的两整页，切换时整条轨道左右推拉。
  // iframe 里的页面会自己识别「被嵌入」并隐藏重复导航；站内首页链接则关掉
  // 燃灯页，避免在 iframe 里再套一层行情页。
  // 顶部四个菜单 = 一条横向轨道：交易练习 / 交易复盘 / 缠论读书会 / 大正藏经
  var PANES = [
    { key: 'trade', pane: 'tradePane', hash: '' },
    { key: 'review', pane: 'reviewPane', frame: 'reviewFrame', url: 'review/index.html?embed=1', hash: '#review' },
    { key: 'chan', pane: 'chanPane', frame: 'chanFrame', url: 'chan/index.html?embed=1', hash: '#chan' },
    { key: 'app', pane: 'appPane', frame: 'appFrame', url: 'app/index.html', hash: '#app' }
  ];
  var PaneView = { index: 0, loaded: {} };

  function paneIndex(key) {
    for (var i = 0; i < PANES.length; i++) {
      if (PANES[i].key === key) return i;
    }
    return 0;
  }

  function paneFromHash() {
    var h = '';
    try { h = location.hash || ''; } catch (e) { h = ''; }
    if (h === '#review') return 1;
    if (h === '#chan') return 2;
    if (h === '#app') return 3;
    return 0;
  }

  function setNavCurrent(key) {
    var links = document.querySelectorAll('.topnav__menu a[data-view]');
    Array.prototype.forEach.call(links, function (a) {
      var active = a.getAttribute('data-view') === key;
      if (active) {
        a.setAttribute('aria-current', 'page');
        a.classList.add('is-on');
      } else {
        a.removeAttribute('aria-current');
        a.classList.remove('is-on');
      }
    });
  }

  function loadPaneFrame(item) {
    if (!item.frame || PaneView.loaded[item.key]) return;
    var frame = $(item.frame);
    if (!frame) return;
    PaneView.loaded[item.key] = true;
    if (item.key === 'app') {
      var loading = $('appLoading');
      if (loading) loading.hidden = false;
      frame.addEventListener('load', cleanAppFrame);
    }
    if (item.key === 'chan') frame.addEventListener('load', cleanEmbedChrome);
    if (item.key === 'review') frame.addEventListener('load', cleanEmbedChrome);
    frame.src = (cfg.rel || '') + item.url;
  }

  function setPane(index, push) {
    index = Math.min(Math.max(index | 0, 0), PANES.length - 1);
    var item = PANES[index];
    loadPaneFrame(item);

    var track = $('pageTrack');
    if (track) track.setAttribute('data-pane', item.key);

    PANES.forEach(function (p, i) {
      var el = $(p.pane);
      if (!el) return;
      if (i === index) {
        el.removeAttribute('inert');
        el.setAttribute('aria-hidden', 'false');
      } else {
        el.setAttribute('inert', '');
        el.setAttribute('aria-hidden', 'true');
      }
    });

    PaneView.index = index;
    setNavCurrent(item.key);

    if (push && typeof history !== 'undefined') {
      var target = item.hash || location.pathname + location.search;
      if ((location.hash || '') !== (item.hash || '')) {
        history.pushState({ pane: item.key }, '', target);
      }
    }
  }

  // iframe 里的页面自己会标 is-embedded；这里再兜一层，防止旧缓存页面还带着顶栏
  function cleanEmbedChrome() {
    var ids = ['chanFrame', 'reviewFrame'];
    ids.forEach(function (id) {
      var frame = $(id);
      if (!frame) return;
      try {
        var doc = frame.contentDocument;
        if (!doc || doc.getElementById('embed-hide-nav')) return;
        var st = doc.createElement('style');
        st.id = 'embed-hide-nav';
        st.textContent = '.topnav,.skip-link{display:none!important}';
        (doc.head || doc.documentElement).appendChild(st);
        if (doc.documentElement) doc.documentElement.classList.add('is-embedded');
        // 笔记页里「去登录」这种链到 index.html 的入口，交给顶层跳转，
        // 别在 iframe 里再套一层行情页
        doc.addEventListener('click', function (ev) {
          var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;
          if (!a || a.target === '_blank' || a.hasAttribute('download')) return;
          var url;
          try { url = new URL(a.href, doc.baseURI); } catch (e) { return; }
          if (url.origin !== location.origin) return;
          var path = url.pathname.replace(/\/+$/, '') || '/';
          if (path === '/' || path === '/index.html' || path === location.pathname) {
            ev.preventDefault();
            location.href = url.href;
          }
        });
      } catch (e) {
        /* 跨域就不管 */
      }
    });
  }

  function cleanAppFrame() {
    var frame = $('appFrame');
    if (!frame) return;
    var loading = $('appLoading');
    if (loading) loading.hidden = true;
    try {
      var doc = frame.contentDocument;
      if (!doc) return;
      if (doc.documentElement) doc.documentElement.style.overscrollBehavior = 'contain';
      if (doc.getElementById('embed-hide-chrome')) return;
      var st = doc.createElement('style');
      st.id = 'embed-hide-chrome';
      st.textContent = '.nav,.topnav,.skip-link{display:none!important}';
      (doc.head || doc.documentElement).appendChild(st);
      // 站内首页＝行情页：点它只切回行情轨，不在 iframe 里再套一层行情页
      doc.addEventListener('click', function (ev) {
        var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;
        if (!a || a.target === '_blank' || a.hasAttribute('download')) return;
        var url;
        try { url = new URL(a.href, doc.baseURI); } catch (e) { return; }
        if (url.origin !== location.origin) return;
        var path = url.pathname.replace(/\/+$/, '') || '/';
        if (path === '/' || path === '/index.html' || path === location.pathname) {
          ev.preventDefault();
          setPane(0, true);
        }
      });
    } catch (e) {
      // 跨域页面（理论上不会有）就交给浏览器默认行为
    }
  }

  function bindAppPane() {
    var menu = document.querySelector('.topnav__menu');
    if (menu) {
      menu.addEventListener('click', function (e) {
        var a = e.target && e.target.closest ? e.target.closest('a[data-view]') : null;
        if (!a) return;
        e.preventDefault();
        var key = a.getAttribute('data-view');
        var idx = 0;
        for (var i = 0; i < PANES.length; i++) {
          if (PANES[i].key === key) { idx = i; break; }
        }
        setPane(idx, true);
      });
    }
    window.addEventListener('popstate', function () {
      setPane(paneFromHash(), false);
    });
    setPane(paneFromHash(), false);
  }

  /** 下单区：看多 / 看空 直接开仓，这里只负责底部提示和「平仓」按钮的可用状态。 */
  /** 下单区：胶囊选方向 + 一个「开仓」，这里管底部提示和两个按钮的可用状态。 */
  function updateOrderUI() {
    var open = $('btnOpen');
    if (open) open.disabled = placing || !isTradingSymbol();
    syncCloseAllBtn();
  }

  // ---------------------------------------------------------------- 加载 K 线
  function switchInterval(iv) {
    // 先记住当前视口（时间区间），新周期的数据到了原地还原。
    // 加载失败重试时 state.bars 已经清空，不会把刚记下的视口覆盖掉。
    if (state.bars.length > 2) {
      var keep = captureView();
      if (keep) state.view = keep;
    }
    state.iv = iv;
    applyChartTimeFormat(iv);
    state.seq += 1;
    var seq = state.seq;
    state.firstLoad = true;
    state.bars = []; // 旧周期的数据一律作废，否则时间轴会混
    showMsg('正在加载 ' + TF_LABEL[iv] + ' K 线…');
    loadBars(iv, seq).catch(function () {
      if (seq !== state.seq) return;
      showMsg('K 线加载失败，正在重试…');
      setTimeout(function () { if (seq === state.seq) switchInterval(iv); }, 3000);
    });
    wsConnect(); // 换周期要换 kline 流
  }

  // ---------------------------------------------------------------- 启动
  function start(options) {
    cfg = options || cfg;
    if (!$('chart')) return;

    // 可选自建反代：site.config.json 里配了 market.restBase / wsBase 就顶到最前面，
    // 没配（默认）就直连交易所。反代见 docs/BTC行情页稳定性优化.md。
    if (cfg.restBase) REST_HOSTS.unshift(String(cfg.restBase).replace(/\/+$/, ''));
    if (cfg.wsBase) WS_HOSTS.unshift(String(cfg.wsBase).replace(/\/+$/, ''));

    // 上次连通的 WS 源优先：这个判断已经收进 wsHost()，这里不用再摆弄索引。

    Account.data = loadGuest();
    restoreAuth();
    state.watch = loadWatch();
    state.watchOpen = false; // 自选默认折叠，点标题栏再展开

    // 指标偏好要在建图之前读，均线列表 / 成交量 / MACD 的初始状态才对
    loadIndPrefs();
    Draw.lines = loadDrawings();
    fillLegends();
    renderMaTools();
    chartInit();
    bind();
    renderAll();
    setSymbolUI();
    showMsg('正在连接行情源…');

    // 从交易笔记页跳过来登录时带 ?next=notes：登录成功后直接回笔记页。
    var nextParam = '';
    try {
      nextParam = new URLSearchParams(window.location.search).get('next') || '';
    } catch (e) {}
    if (nextParam === 'notes') pendingNotes = true;
    if (Account.mode !== 'cloud' && (pendingNotes || window.location.hash === '#login')) {
      openModal();
    }

    if (Account.mode === 'cloud') {
      loadCloudState(false);
    }

    // 先 REST 把首屏拿到，不等 WS 握手
    loadBars(state.iv, state.seq).catch(function () {
      showMsg('K 线加载失败，正在自动重试…');
      setTimeout(function () { switchInterval(state.iv); }, 3000);
    });
    restGet(tickerPath()).then(applyTicker).catch(function () {
      setSource('down', '行情源不可用，正在重试…');
    });

    wsConnect();
    startWatchdog();
    startClock();

    // WS 迟迟连不上就开轮询兜底，不让页面干等（连上后 startPoll 会被 stopPoll 关掉）
    setTimeout(function () {
      if (!WS.opened && !pollTimer) startPoll();
    }, 6000);
  }

  global.TradePage = {
    start: start,
    _state: state,
    _account: Account,
    _indicator: computeIndicators,
    // 给 tools/trade_page_test.js 用的口子，页面上不直接调用
    _ma: Ind,
    _addMa: addMa,
    _changeMa: changeMaPeriod,
    _removeMa: removeMa,
    _setVol: setVolVisible,
    _setMaColor: setMaColor,
    _switch: switchInterval,
    _switchSymbol: switchSymbol,
    _aggregate: aggregateKlines,
    _synth: TF_SYNTH,
    _tf: TF,
    _trips: roundTrips,
    _stats: tradeStats,
    _unrealized: unrealized,
    _normalizePositions: normalizePositions,
    _groupPositions: groupPositions,
    _localAddPosition: localAddPosition,
    _draw: Draw,
    _drawDev: DRAW_DEV,
    _scale: Scale,
    _fs: FS,
    _toggleFs: toggleChartFullscreen,
    _parseDrawings: parseDrawings,
    _serializeDrawings: serializeDrawings,
    _lineShown: lineShown,
    _chart: Chart,
    _updateHoverTag: updateHoverTag,
    _updatePriceTag: updatePriceTag
  };
})(window);
