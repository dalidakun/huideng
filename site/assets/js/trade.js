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
  var LIMIT = 1000;
  var TF = ['1m', '5m', '15m', '30m', '1h', '2h', '4h', '8h', '12h', '1d', '1w', '1M'];
  var TF_LABEL = {
    '1m': '1 分钟', '5m': '5 分钟', '15m': '15 分钟', '30m': '30 分钟',
    '1h': '1 小时', '2h': '2 小时', '4h': '4 小时', '8h': '8 小时', '12h': '12 小时',
    '1d': '1 天', '1w': '1 周', '1M': '1 月'
  };
  // 1M 用 28 天，只给「断档补齐」当阈值用，避免月末 31 天被误判成断档
  var TF_MS = {
    '1m': 60000, '5m': 300000, '15m': 900000, '30m': 1800000,
    '1h': 3600000, '2h': 7200000, '4h': 14400000, '8h': 28800000, '12h': 43200000,
    '1d': 86400000, '1w': 604800000, '1M': 2419200000
  };

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
    phone_not_bound: '这个手机号还没绑定账号'
  };

  var cfg = { api: '', key: '', rel: '' };
  var state = { iv: '1m', price: 0, ticker: null, bars: [], firstLoad: true, seq: 0, lastTick: 0 };
  var Account = { mode: 'guest', token: '', username: '', data: null };
  var orderMode = 'open'; // open=开仓 / close=平仓

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

  function klinePath(iv, limit) {
    return '/api/v3/klines?symbol=' + SYMBOL + '&interval=' + iv + '&limit=' + (limit || LIMIT);
  }
  function tickerPath() {
    return '/api/v3/ticker/24hr?symbol=' + SYMBOL;
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
    }, RENDER_MS);
  }

  /** 每秒刷新「更新于 / X 秒前」，行情停了要一眼看得出来。 */
  function startClock() {
    setInterval(function () {
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
      state.bars = bars.slice(-LIMIT);
      chartSet(state.bars);
      // 只有拿到成段的历史才自动缩放到全图；单根先别 fit，否则会放大成一根蜡烛
      if (state.firstLoad && Chart.chart && state.bars.length > 2) {
        Chart.chart.timeScale().fitContent();
        state.firstLoad = false;
      }
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
      if (state.bars.length > LIMIT) state.bars.shift();
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
    state.bars = Object.keys(map).map(function (k) { return map[k]; }).sort(byTime).slice(-LIMIT);
    chartSet(state.bars);
    if (state.firstLoad && Chart.chart) {
      Chart.chart.timeScale().fitContent();
      state.firstLoad = false;
    }
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
    restGet(klinePath(iv, full ? 300 : 60)).then(function (rows) {
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

  /** 拉整段历史（首次加载、切周期），seq 变了就丢弃结果。 */
  function loadBars(iv, seq) {
    return restGet(klinePath(iv, LIMIT)).then(function (rows) {
      if (iv !== state.iv || seq !== state.seq) return;
      var bars = mapKlines(rows);
      if (!bars.length) return;
      state.bars = bars.sort(byTime).slice(-LIMIT);
      chartSet(state.bars);
      hideMsg();
      refreshLegend();
      if (state.firstLoad && Chart.chart) {
        Chart.chart.timeScale().fitContent();
        state.firstLoad = false;
      }
    });
  }

  // ---------------------------------------------------------------- WebSocket
  var WS = {
    sock: null, host: '', idx: 0, fails: 0, opened: false,
    retry: null, guard: null, ping: null, lastMsg: 0
  };

  function wsHost() { return WS_HOSTS[WS.idx % WS_HOSTS.length]; }

  function wsUrl(iv) {
    var s = SYMBOL.toLowerCase();
    return wsHost() + '/stream?streams=' + s + '@ticker/' + s + '@kline_' + iv;
  }

  function wsConnect() {
    if (document.hidden) return; // 后台不连，回前台由 visibilitychange 拉起
    if (WS.retry) { clearTimeout(WS.retry); WS.retry = null; }
    wsAbort();

    var url;
    try { url = wsUrl(state.iv); } catch (e) { wsFail(); return; }
    var ws;
    try { ws = new WebSocket(url); } catch (e) { wsFail(); return; }

    WS.sock = ws;
    WS.opened = false;
    WS.host = wsHost();
    WS.lastMsg = Date.now();

    // 握手超时：被墙的源经常既不通也不报错，只能自己掐掉换下一个
    WS.guard = setTimeout(function () {
      if (WS.sock !== ws || WS.opened) return;
      wsAbort();
      wsFail();
    }, WS_OPEN_MS);

    ws.onopen = function () {
      if (WS.sock !== ws) return;
      WS.opened = true;
      WS.fails = 0;
      WS.lastMsg = Date.now();
      if (WS.guard) { clearTimeout(WS.guard); WS.guard = null; }
      writeLS(LS.ws, WS.host);
      stopPoll();
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
      WS.sock = null;
      WS.opened = false;
      if (WS.guard) { clearTimeout(WS.guard); WS.guard = null; }
      stopPing();
      wsFail();
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

  /** 失败后换源重连：0.8s→8s 退避 + 抖动，期间轻量轮询保着行情。 */
  function wsFail() {
    WS.fails += 1;
    WS.opened = false;
    startPoll();
    sourceText();
    WS.idx = (WS.idx + 1) % WS_HOSTS.length;
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
      wsFail();
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
    restGet(klinePath(iv, state.bars.length ? 3 : LIMIT)).then(function (rows) {
      if (iv !== state.iv) return;
      applyKlines(rows, !state.bars.length);
    }).catch(function () {});
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
    return (+v > 0 ? '+' : '') + group(+v, 2);
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
      cell.b.textContent = v == null || !Number.isFinite(v) ? '--' : fmtPrice(v);
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

  function buildMaLegend() {
    var box = $('maList');
    if (!box) return;
    box.innerHTML = '';
    Legend.ma = {};
    Ind.ma.forEach(function (m) {
      var row = document.createElement('button');
      row.type = 'button';
      row.className = 'ma-row' + (m.hidden ? ' is-off' : '');
      row.setAttribute('data-ma', String(m.p));
      row.title = m.hidden ? '点击显示 ' + maLabel(m.p) : '点击隐藏 ' + maLabel(m.p);
      var i = document.createElement('i');
      i.textContent = maLabel(m.p);
      i.style.color = m.c;
      var b = document.createElement('b');
      b.textContent = '--';
      row.appendChild(i);
      row.appendChild(b);
      row.onclick = function () { setMaHidden(m.p, !m.hidden); };
      row.oncontextmenu = function (e) {
        e.preventDefault();
        e.stopPropagation();
        openMaPop(m.p, row);
      };
      box.appendChild(row);
      Legend.ma[m.p] = { span: row, i: i, b: b };
    });

    var addRow = document.createElement('button');
    addRow.type = 'button';
    addRow.className = 'ma-row ma-row--add';
    addRow.textContent = '＋ 添加均线';
    addRow.onclick = function () { openMaPop(0, addRow); };
    box.appendChild(addRow);
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
      row.span.title = m.hidden ? '点击显示 ' + maLabel(m.p) : '点击隐藏 ' + maLabel(m.p);
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
    ['maPop', 'ctxMenu', 'acctMenu'].forEach(function (id) {
      var el = $(id);
      if (el && el !== except) el.hidden = true;
    });
    var openBtn = document.querySelector ? document.querySelector('.ma-row.is-open') : null;
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
    if (login) login.hidden = Account.mode === 'cloud';
    if (logout) logout.hidden = Account.mode !== 'cloud';
    if (phone) {
      phone.hidden = Account.mode !== 'cloud';
      var bound = (Account.data && Account.data.phone) || Phone.bound || '';
      phone.textContent = bound ? '手机已绑定 ' + bound : '绑定手机号';
    }
  }

  // ---------------------------------------------------------------- 图表
  var Chart = {
    chart: null, candle: null, vol: null,
    macd: null, hist: null, dif: null, dea: null,
    ma: {}, ready: false, hover: null
  };

  // ---------------------------------------------------------------- 画线
  // 覆盖在 K 线上的 canvas：存 (时间, 价格) 而不是像素，缩放/平移后能跟着走。
  var Draw = {
    canvas: null, ctx: null, lines: [], undo: [],
    active: false, drawing: null, raf: 0,
    showTrades: false, trades: [], flash: null, flashTimer: 0
  };

  // 历史开平仓点统一用黑色
  var TRADE_COLOR = '#1A1A1A';

  function drawPoint(e) {
    if (!Chart.chart || !Chart.candle || !Draw.canvas) return null;
    var r = Draw.canvas.getBoundingClientRect();
    var x = e.clientX - r.left;
    var y = e.clientY - r.top;
    var t = Chart.chart.timeScale().coordinateToTime(x);
    var p = Chart.candle.coordinateToPrice(y);
    if (t == null || p == null || !Number.isFinite(p)) return null;
    return { x: x, y: y, t: t, p: p };
  }

  function strokePath(ctx, pts) {
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
    ctx.strokeStyle = '#1E5AA8';
    ctx.lineWidth = 1.6;
    ctx.beginPath();
    pts.forEach(function (pt, i) {
      if (i === 0) ctx.moveTo(pt.x, pt.y);
      else ctx.lineTo(pt.x, pt.y);
    });
    ctx.stroke();
    ctx.restore();
  }

  function drawDot(ctx, x, y, color, r, ring) {
    if (ring) {
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
    var w = Draw.canvas.clientWidth || 0;
    var h = Draw.canvas.clientHeight || 0;
    Draw.ctx.clearRect(0, 0, w, h);
    var ts = Chart.chart.timeScale();
    Draw.lines.forEach(function (ln) {
      var pts = [];
      ln.points.forEach(function (pt) {
        var x = ts.timeToCoordinate(pt.t);
        var y = Chart.candle.priceToCoordinate(pt.p);
        if (x == null || y == null) return;
        pts.push({ x: x, y: y });
      });
      if (pts.length > 1) strokePath(Draw.ctx, pts);
    });
    if (Draw.drawing && Draw.drawing.points.length > 1) {
      strokePath(Draw.ctx, Draw.drawing.points);
    }
    if (Draw.showTrades && Draw.trades.length) drawTradesOn(Draw.trades, false);
    if (Draw.flash) drawTradesOn([Draw.flash.trip], true);
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

  function setDrawActive(on) {
    Draw.active = !!on;
    if (!on) Draw.drawing = null;
    var btn = $('btnDraw');
    if (btn) {
      btn.classList.toggle('is-active', Draw.active);
      btn.setAttribute('aria-pressed', Draw.active ? 'true' : 'false');
    }
    var pane = document.querySelector ? document.querySelector('.pane--main') : null;
    if (pane) pane.classList.toggle('is-drawing', Draw.active);
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
    var pt = drawPoint(e);
    if (!pt) return;
    e.preventDefault();
    Draw.drawing = { points: [pt] };
    if (Draw.canvas.setPointerCapture) {
      try { Draw.canvas.setPointerCapture(e.pointerId); } catch (err) {}
    }
    drawRedraw();
  }

  function onDrawMove(e) {
    if (!Draw.drawing) return;
    var pt = drawPoint(e);
    if (!pt) return;
    var pts = Draw.drawing.points;
    if (e.shiftKey) {
      // 按住 Shift：只留起点和当前点，画直线
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
    if (!Draw.drawing) return;
    var pts = Draw.drawing.points;
    var first = pts[0];
    var last = pts[pts.length - 1];
    var pt = drawPoint(e) || last;
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
      var line = { points: pts.map(function (p) { return { t: p.t, p: p.p }; }) };
      Draw.lines.push(line);
      Draw.undo.push({ type: 'add', line: line });
      if (Draw.undo.length > 200) Draw.undo.shift();
      setDrawActive(false); // 画完一笔自动退出，下一次要重新点
    }
    drawRedraw();
  }

  function onDrawCancel() {
    if (!Draw.drawing) return;
    Draw.drawing = null;
    drawRedraw();
  }

  function eraseDrawings() {
    if (!Draw.lines.length) {
      toast('还没有画线');
      return;
    }
    Draw.undo.push({ type: 'clear', lines: Draw.lines.slice() });
    Draw.lines = [];
    drawRedraw();
    toast('已擦除全部画线');
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
      Draw.lines = act.lines.slice();
    }
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
    window.addEventListener('pointermove', onDrawMove);
    window.addEventListener('pointerup', onDrawUp);
    window.addEventListener('pointercancel', onDrawCancel);
    document.addEventListener('keydown', onDrawKey);
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
    set('lgO', fmtPrice(bar.open), cls);
    set('lgH', fmtPrice(bar.high), cls);
    set('lgL', fmtPrice(bar.low), cls);
    set('lgC', fmtPrice(bar.close), cls);
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
    var fontFamily = getComputedStyle(document.body).fontFamily;
    // 主图和副图的右轴取同一个最小宽度，绘图区才会左右对齐
    var psMin = (window.innerWidth || 1024) < 520 ? 74 : 88;
    var tickFmt = function (time) {
      var d = new Date(time * 1000);
      if (state.iv === '1M') return (d.getFullYear() % 100) + '/' + (d.getMonth() + 1);
      if (state.iv === '1w' || state.iv === '1d') return (d.getMonth() + 1) + '/' + d.getDate();
      return pad(d.getHours()) + ':' + pad(d.getMinutes());
    };
    // 十字线的时间标签：月线只到年月，周线只到月日
    var crossTime = function (t) {
      var d = new Date(t * 1000);
      if (state.iv === '1M') return d.getFullYear() + '/' + (d.getMonth() + 1);
      if (state.iv === '1w') return (d.getMonth() + 1) + '/' + d.getDate();
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
        // 只有横向虚线，竖向网格线去掉
        grid: {
          vertLines: { color: 'rgba(0, 0, 0, 0)' },
          horzLines: { color: '#E7DCC3', style: (LightweightCharts.LineStyle && LightweightCharts.LineStyle.Dashed) || 2 }
        },
        rightPriceScale: { borderColor: 'rgba(0, 0, 0, 0)', minimumWidth: psMin, scaleMargins: { top: 0.08, bottom: 0.26 } },
        timeScale: {
          borderColor: '#E1D5B9',
          timeVisible: true,
          secondsVisible: false,
          rightOffset: 6,
          // 有副图时时间轴只画在副图上，两个图共用一条
          visible: !Ind.macd,
          tickMarkFormatter: tickFmt
        },
        crosshair: {
          mode: (LightweightCharts.CrosshairMode && LightweightCharts.CrosshairMode.Magnet) || 1,
          vertLine: { color: '#B8B8B8', width: 1, style: 3, labelBackgroundColor: '#1C1C1C' },
          horzLine: { color: '#B8B8B8', width: 1, style: 3, labelBackgroundColor: '#1C1C1C' }
        },
        localization: {
          locale: 'zh-CN',
          priceFormatter: function (p) { return group(p, 2); },
          // 图表库传进来的是秒；月/周线只显示到月或日
          timeFormatter: crossTime
        },
        handleScroll: { mouseWheel: true, pressedMouseMove: true, horzTouchDrag: true, vertTouchDrag: false },
        handleScale: { axisPressedMouseMove: true }
      });

      Chart.candle = Chart.chart.addCandlestickSeries({
        upColor: UP,
        downColor: DOWN,
        borderUpColor: UP,
        borderDownColor: DOWN,
        wickUpColor: UP,
        wickDownColor: DOWN,
        // 当前实时价：一条虚线横穿图表，右轴同时给出价格标签
        priceLineVisible: true,
        priceLineWidth: 1,
        priceLineStyle: (LightweightCharts.LineStyle && LightweightCharts.LineStyle.Dashed) || 2,
        priceLineColor: '#8A7F68',
        lastValueVisible: true
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
        rightPriceScale: { borderColor: 'rgba(0, 0, 0, 0)', minimumWidth: psMin, scaleMargins: { top: 0.16, bottom: 0.12 } },
        timeScale: {
          borderColor: '#E1D5B9',
          timeVisible: true,
          secondsVisible: false,
          rightOffset: 6,
          tickMarkFormatter: tickFmt
        },
        crosshair: {
          mode: (LightweightCharts.CrosshairMode && LightweightCharts.CrosshairMode.Magnet) || 1,
          // 副图不显示横向价格线，只借它的竖向准星和时间标签
          vertLine: { color: '#B8B8B8', width: 1, style: 3, labelBackgroundColor: '#1C1C1C' },
          horzLine: { visible: false, labelVisible: false }
        },
        localization: {
          locale: 'zh-CN',
          priceFormatter: function (p) { return group(p, 2); },
          timeFormatter: crossTime
        },
        handleScroll: { mouseWheel: true, pressedMouseMove: true, horzTouchDrag: true, vertTouchDrag: false },
        handleScale: { axisPressedMouseMove: true }
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
      handleCrosshair(param);
      mirrorCrosshair(Chart.macd, param && param.time, 0, Chart.dif);
    });
    if (Chart.macd) {
      Chart.macd.subscribeCrosshairMove(function (param) {
        if (Ind.syncing) return;
        handleCrosshair(param);
        var t = param && param.time;
        var i = t == null ? -1 : indexOfTime(t);
        mirrorCrosshair(Chart.chart, t, i >= 0 ? state.bars[i].close : 0, Chart.candle);
      });
    }

    linkCharts();
    applyChartTimeFormat(state.iv);

    Chart.ready = true;
    // 分界线（已走 / 未走区域）要跟着最后一根 K 线走
    var scaleApi = Chart.chart.timeScale();
    if (scaleApi && typeof scaleApi.subscribeVisibleLogicalRangeChange === 'function') {
      scaleApi.subscribeVisibleLogicalRangeChange(paintChartBg);
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
    var tick = function (time) {
      var d = new Date(time * 1000);
      if (iv === '1M') return (d.getFullYear() % 100) + '/' + (d.getMonth() + 1);
      if (iv === '1w' || iv === '1d') return (d.getMonth() + 1) + '/' + d.getDate();
      return pad(d.getHours()) + ':' + pad(d.getMinutes());
    };
    var cross = function (t) {
      var d = new Date(t * 1000);
      if (iv === '1M') return d.getFullYear() + '/' + (d.getMonth() + 1);
      if (iv === '1w') return (d.getMonth() + 1) + '/' + d.getDate();
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

  function handleCrosshair(param) {
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
        if (lock || !range) return;
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

  /** 成交量筒收起时，把主图下方空出来的位置还给 K 线。 */
  function applyChartMargins() {
    if (!Chart.chart) return;
    try {
      Chart.chart.applyOptions({
        rightPriceScale: { scaleMargins: { top: 0.08, bottom: Ind.vol ? 0.26 : 0.06 } }
      });
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
        openCtx(e.clientX, e.clientY, null);
      });
    }

    var apply = $('maApply');
    if (apply) apply.addEventListener('click', applyMaInput);

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

    // 均线数值下拉：默认收起，点箭头展开；每行点一下隐藏 / 显示
    var maToggle = $('maToggle');
    var maList = $('maList');
    if (maToggle && maList) {
      maToggle.addEventListener('click', function (e) {
        e.stopPropagation();
        var open = maList.hidden;
        maList.hidden = !open;
        maToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
        maToggle.textContent = open ? '均线 ▴' : '均线 ▾';
      });
    }

    // 历史开平仓点 / 画线 / 擦除
    var histBtn = $('btnHist');
    if (histBtn) histBtn.addEventListener('click', function () { setHistActive(!Draw.showTrades); });
    var drawBtn = $('btnDraw');
    if (drawBtn) drawBtn.addEventListener('click', function () { setDrawActive(!Draw.active); });
    var eraseBtn = $('btnErase');
    if (eraseBtn) eraseBtn.addEventListener('click', eraseDrawings);
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
    if (!Chart.dif) return;
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
  }

  /**
   * 图表底色：已走出 K 线的区域 #EEE7D4，右侧还没有走势的空区用页面底 #F4ECD9，
   * 分界就是最后一根（正在走的那根）K 线的右边缘。
   * 主图和副图各画一条，两张图的横坐标一致，分界线也就对得上。
   */
  function paintChartBg() {
    paintPaneBg('chart', Chart.chart);
    paintPaneBg('chartMacd', Chart.macd);
    drawSchedule();
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
  }

  // ---------------------------------------------------------------- 账户
  function newGuest() {
    return { cash: INITIAL_CASH, positions: [], orders: [], history: [], lastPrice: 0 };
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
    toast(msgOf(code));
  }

  // ---------------------------------------------------------------- 认证
  function restoreAuth() {
    var token = readLS(LS.token);
    if (!token) return false;
    Account.token = token;
    Account.username = readLS(LS.user) || '';
    Account.mode = 'cloud';
    return true;
  }

  /** 重置资金：现金回到 10 万、清掉持仓/挂单，但历史成交和胜率保留。 */
  function resetFunds() {
    if (!window.confirm('重置资金：现金回到 100,000 USDT，清空持仓和挂单；历史成交与胜率保留。继续？')) return;
    if (Account.mode === 'guest') {
      var a = Account.data;
      a.cash = INITIAL_CASH;
      a.positions = [];
      a.orders = [];
      a.lastPrice = 0;
      saveAccount();
      renderAll();
      toast('资金已重置，历史与胜率保留');
      return;
    }
    api('tradeReset', {}).then(function (j) {
      Account.data = j.account;
      renderAll();
      toast('资金已重置，历史与胜率保留');
    }).catch(showErr);
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
      return api('tradeState', {});
    }).then(function (j) {
      Account.data = j.account;
      closeModal();
      renderAll();
      toast('已登录，模拟账户跨设备同步');
    });
  }

  // ---------------------------------------------------------------- 渲染
  function renderAll() {
    renderAcct();
    renderTables();
    renderSummary();
    renderEst();
    updateOrderUI();
    renderAccountMenu();
  }

  /**
   * 开仓/平仓配成「一单」：历史是新的在前，这里按时间正序用栈配对，
   * 同方向、同数量的最近一笔开仓优先；没配上的平仓也单独成单。
   */
  function roundTrips() {
    var list = (Account.data && Account.data.history) || [];
    var chrono = list.slice().reverse();
    var opens = [];
    var out = [];

    chrono.forEach(function (h) {
      if (!h) return;
      if (h.type === 'open') {
        opens.push(h);
        return;
      }
      if (h.type !== 'close' && h.type !== 'liquidated') return;

      var open = null;
      var i;
      if (h.posId) {
        // 新数据带持仓 id：部分平仓也能对上同一笔开仓
        for (i = 0; i < opens.length; i += 1) {
          if (opens[i].posId === h.posId) {
            open = opens[i];
            break;
          }
        }
      } else {
        // 旧数据没有 posId：退回按方向 + 数量配对
        for (i = opens.length - 1; i >= 0; i -= 1) {
          if (opens[i].side === h.side && Math.abs(opens[i].qty - h.qty) < 1e-9) {
            open = opens.splice(i, 1)[0];
            break;
          }
        }
      }

      out.push({
        at: h.at,
        openAt: open ? open.at : 0,
        side: h.side,
        qty: h.qty,
        entry: open ? open.price : null,
        exit: h.price,
        pnl: h.pnl || 0,
        liquidated: h.type === 'liquidated'
      });
    });

    return out.reverse(); // 新的在前，和原来的记录顺序一致
  }

  /** 胜率 = 盈利单数 / 完成的单数；当日单数 = 最近 24 小时平掉的单数。 */
  function tradeStats() {
    var trips = roundTrips();
    var dayAgo = Date.now() - 24 * 3600 * 1000;
    var wins = 0;
    var today = 0;
    trips.forEach(function (t) {
      if (t.pnl > 0) wins += 1;
      if (t.at >= dayAgo) today += 1;
    });
    return {
      total: trips.length,
      today: today,
      winRate: trips.length ? (wins / trips.length) * 100 : null
    };
  }

  function renderAcct() {
    var a = Account.data;
    if (!a) return;
    var mark = state.price;
    var eq = equity(mark);
    var pnl = eq - INITIAL_CASH;
    var pct = INITIAL_CASH ? (pnl / INITIAL_CASH) * 100 : 0;
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
    if ($('statToday')) $('statToday').textContent = String(st.today);
    if ($('statWin')) $('statWin').textContent = st.winRate == null ? '--' : st.winRate.toFixed(1) + '%';
  }

  function setNum(id, v, digits) {
    var e = $(id);
    if (e) e.textContent = Number.isFinite(+v) ? group(+v, digits) : '--';
  }

  function renderTables() {
    var a = Account.data;
    if (!a) return;
    var mark = state.price;

    // 持仓：同方向合并成一单展示，未实现盈亏按合并后的总量计算
    var posBody = $('tblPos');
    var grouped = groupPositions(a.positions);
    if (posBody) {
      posBody.innerHTML = '';
      grouped.forEach(function (p) {
        var pnl = unrealized(p, mark);
        var pct = p.margin ? (pnl / p.margin) * 100 : 0;
        posBody.appendChild(row([
          cell(p.side === 'long' ? '看多' : '看空', p.side === 'long' ? 'is-up' : 'is-down'),
          cell(fmtQty(p.qty), 'num'),
          cell((pnl >= 0 ? '+' : '') + group(pnl, 2) + ' (' + fmtPct(pct) + ')', 'num ' + (pnl >= 0 ? 'is-up' : 'is-down')),
          cell(fmtPrice(p.entry), 'num')
        ]));
      });
    }

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

    // 历史记录：一开一平合成一条；全部渲染，行多了在下面的表内滚动
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
    if (Draw.showTrades) drawSchedule();

    var nPos = grouped.length;
    var nOrd = (a.orders || []).length;
    if ($('cntPos')) $('cntPos').textContent = nPos ? '(' + nPos + ')' : '';
    if ($('cntOrd')) $('cntOrd').textContent = nOrd ? '(' + nOrd + ')' : '';

    var activeTab = currentTab();
    var empty = $('tblEmpty');
    if (empty) {
      var n = activeTab === 'pos' ? nPos : activeTab === 'ord' ? nOrd : trips.length;
      empty.hidden = n > 0;
      empty.textContent = activeTab === 'pos'
        ? '暂无持仓。在上方选择开仓方向与数量，下一单试试。'
        : activeTab === 'ord' ? '暂无挂单。' : '暂无历史记录。';
    }
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
    var notional = 0;
    var pnl = 0;
    var margin = 0;

    list.forEach(function (p) {
      notional += ((mark || p.entry || 0) * (+p.qty || 0));
      pnl += unrealized(p, mark);
      margin += +p.margin || 0;
    });

    setNum('sumNotional', notional, 2);
    setNum('sumMargin', margin, 2);
    setNum('sumCash', a.cash, 2);

    var pnlEl = $('sumPnl');
    if (pnlEl) {
      pnlEl.textContent = (pnl >= 0 ? '+' : '') + group(pnl, 2);
      pnlEl.style.color = pnl > 0 ? UP : pnl < 0 ? DOWN : '';
    }

    if ($('sumCount')) $('sumCount').textContent = list.length + ' 笔';

    var box = $('sidePos');
    if (box) {
      box.innerHTML = '';
      list.forEach(function (p) { box.appendChild(sidePosRow(p, mark)); });
    }
    if ($('sideEmpty')) $('sideEmpty').hidden = list.length > 0;
  }

  function sidePosRow(p, mark) {
    var row = document.createElement('div');
    row.className = 'side-pos';

    var tag = document.createElement('span');
    tag.className = 'side-pos__tag ' + (p.side === 'long' ? 'is-up' : 'is-down');
    tag.textContent = p.side === 'long' ? '多' : '空';

    var main = document.createElement('div');
    main.className = 'side-pos__main';
    var qty = document.createElement('b');
    qty.textContent = fmtQty(p.qty) + ' BTC';
    var entry = document.createElement('em');
    entry.textContent = '成本 ' + fmtPrice(p.entry);
    main.appendChild(qty);
    main.appendChild(entry);

    var value = unrealized(p, mark);
    var pnl = document.createElement('b');
    pnl.className = 'side-pos__pnl ' + (value > 0 ? 'is-up' : value < 0 ? 'is-down' : '');
    pnl.textContent = (value >= 0 ? '+' : '') + group(value, 2);

    row.appendChild(tag);
    row.appendChild(main);
    row.appendChild(pnl);
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

  function currentTab() {
    var on = document.querySelector('#tabs button.is-on');
    return on ? on.getAttribute('data-tab') : 'pos';
  }

  function maxQty() {
    var price = orderPrice();
    var a = Account.data;
    if (!a || !price || price <= 0) return 0;
    // 向下取到 6 位，避免四舍五入后正好比可用余额多一点点
    return Math.max(0, Math.floor((a.cash / (price * (1 + FEE))) * 1e6) / 1e6);
  }

  function orderPrice() {
    return state.price;
  }

  function renderEst() {
    var a = Account.data;
    if (!a) return;
    var price = orderPrice();
    var qty = parseFloat($('fQty') && $('fQty').value) || 0;
    var notional = price && qty ? price * qty : 0;
    setNum('estNotional', notional, 2);
    setNum('estMargin', notional, 2);
    var hint = $('priceHint');
    if (hint) hint.textContent = '当前 ' + fmtPrice(state.price);
  }

  // ---------------------------------------------------------------- 下单交互
  function sideLabel(side) {
    return side === 'long' ? '多' : '空';
  }

  function positionsOf(side) {
    return ((Account.data && Account.data.positions) || []).filter(function (p) {
      return p.side === side;
    });
  }

  function doOpen(side, btn) {
    var qty = parseFloat($('fQty').value);
    var price = state.price;

    if (!Number.isFinite(price) || price <= 0) {
      toast('行情还没连上，稍等一下再下单');
      return;
    }
    if (!Number.isFinite(qty) || qty <= 0) {
      toast('请填写数量');
      $('fQty').focus();
      return;
    }

    if (btn) btn.disabled = true;
    place({ kind: 'market', side: side, qty: qty, price: price }).then(function () {
      toast('已开仓 ' + fmtQty(qty) + ' BTC');
      $('fQty').value = '';
      renderEst();
    }).catch(showErr).then(function () { if (btn) btn.disabled = false; });
  }

  var Close = { side: '', pct: 1 };

  function positionById(id) {
    var list = (Account.data && Account.data.positions) || [];
    for (var i = 0; i < list.length; i += 1) {
      if (list[i].id === id) return list[i];
    }
    return null;
  }

  /** 同步平仓比例按钮的选中态与右上角百分比文字。 */
  function updateClosePctUI() {
    var pct = Close.pct > 0 ? Close.pct : 1;
    if ($('closePctText')) $('closePctText').textContent = Math.round(pct * 100) + '%';
    var box = $('closePctBtns');
    if (!box || !box.querySelectorAll) return;
    Array.prototype.forEach.call(box.querySelectorAll('button[data-close-pct]'), function (b) {
      var on = Math.abs((parseFloat(b.getAttribute('data-close-pct')) || 0) - pct) < 1e-9;
      b.classList.toggle('is-on', on);
      b.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
  }

  /**
   * 平仓模式点「平多 / 平空」：按选中的比例（25/50/75/100%）直接平掉该方向持仓。
   * 同方向的多笔持仓已在开仓时合并，这里正常只有一笔；老数据有多笔时按同一比例逐笔平。
   */
  function openCloseSide(side, btn) {
    var list = positionsOf(side);
    if (!list.length) { toast('暂无' + sideLabel(side) + '头持仓'); return; }
    if (!state.price) { toast('行情还没连上'); return; }

    var pct = Close.pct > 0 ? Close.pct : 1;
    var total = 0;
    list.forEach(function (p) { total += p.qty; });
    if (total * pct < 1e-9) { toast('可平数量不足'); return; }

    closeMenus();
    var price = state.price;
    if (btn) btn.disabled = true;
    var chain = Promise.resolve();
    list.forEach(function (p) {
      chain = chain.then(function () { return closePos(p.id, price, pct); });
    });
    chain.then(function () {
      toast(pct >= 1
        ? '已平' + sideLabel(side) + ' ' + fmtQty(total) + ' BTC'
        : '已平' + sideLabel(side) + ' ' + Math.round(pct * 100) + '%（' + fmtQty(total * pct) + ' BTC）');
      if (btn) btn.disabled = false;
    }).catch(function (e) {
      if (btn) btn.disabled = false;
      showErr(e);
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
    if (Phone.timer) { clearInterval(Phone.timer); Phone.timer = 0; }
    $('phoneTitle').textContent = Phone.scene === 'reset' ? '找回密码' : '绑定手机号';
    $('phoneIntro').textContent = Phone.scene === 'reset'
      ? '用绑定过的手机号收验证码；验证通过后直接设置新密码，再用新密码登录。'
      : '绑定后可以用短信验证码重置密码，忘了密码不至于找不回来。';
    $('pPwdField').hidden = Phone.scene !== 'reset';
    $('pErr').textContent = '';
    $('pPhone').value = '';
    $('pCode').value = '';
    $('pNewPwd').value = '';
    $('pHint').textContent = '先填手机号';
    $('pSend').disabled = false;
    $('pSend').textContent = '获取验证码';
    $('pSubmit').textContent = Phone.scene === 'reset' ? '重置密码' : '绑定';
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
        toast(boundPhone ? '已绑定 ' + boundPhone : '手机号已绑定');
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

  function bind() {
    // 图表工具条：均线增删改、成交量 / MACD 开关、右键菜单
    bindChartTools();

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

    // 开仓 / 平仓模式（顶部），底部按钮随模式切换成看多/看空或平空/平多
    bindSeg('segMode', function (b) {
      orderMode = b && b.getAttribute('data-mode') === 'close' ? 'close' : 'open';
      updateOrderUI();
      renderEst();
    });
    updateOrderUI();

    var orderActions = $('orderActions');
    if (orderActions) {
      orderActions.addEventListener('click', function (e) {
        var b = e.target && e.target.closest ? e.target.closest('button[data-side]') : null;
        if (!b) return;
        var side = b.getAttribute('data-side');
        if (orderMode === 'close') openCloseSide(side, b);
        else doOpen(side, b);
      });
    }

    // 数量
    var fQty = $('fQty');
    if (fQty) fQty.addEventListener('input', renderEst);

    var pct = document.querySelector('#qtyRow .pct');
    if (pct) {
      pct.addEventListener('click', function (e) {
        var b = e.target.closest('button[data-pct]');
        if (!b) return;
        var pctVal = parseFloat(b.getAttribute('data-pct'));
        var price = orderPrice();
        if (!price) { toast('行情还没连上'); return; }
        var q = (Account.data.cash * pctVal) / (price * (1 + FEE));
        // 一律向下取整，100% 时不会因为四舍五入而超出余额
        q = Math.floor(q * 1e6) / 1e6;
        $('fQty').value = q > 0 ? q.toFixed(6) : '0';
        renderEst();
      });
    }

    // 平仓比例：只记录选择，点「平多 / 平空」时才按当前价成交
    var closePct = $('closePctBtns');
    if (closePct) {
      closePct.addEventListener('click', function (e) {
        var b = e.target.closest('button[data-close-pct]');
        if (!b) return;
        Close.pct = parseFloat(b.getAttribute('data-close-pct')) || 1;
        updateClosePctUI();
      });
    }

    // 标签页
    var tabs = $('tabs');
    if (tabs) {
      tabs.addEventListener('click', function (e) {
        var b = e.target.closest('button[data-tab]');
        if (!b) return;
        Array.prototype.forEach.call(tabs.querySelectorAll('button'), function (x) { x.classList.remove('is-on'); });
        b.classList.add('is-on');
        var t = b.getAttribute('data-tab');
        var show = { pos: 'wrapPos', ord: 'wrapOrd', his: 'wrapHis' };
        Object.keys(show).forEach(function (key) {
          var box = $(show[key]);
          if (box) box.hidden = key !== t;
        });
        renderTables();
      });
    }

    // 开仓区折叠 / 展开（TRADE 竖条）
    var tradeTab = $('tradeTab');
    if (tradeTab) {
      tradeTab.addEventListener('click', function () {
        var side = $('deskSide');
        if (!side) return;
        var hidden = side.classList.toggle('is-hidden');
        tradeTab.setAttribute('aria-expanded', hidden ? 'false' : 'true');
        var split = $('deskSplit');
        if (split) split.hidden = hidden;
        paintChartBg();
      });
    }

    initSplit();

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

    var acctMenu = $('acctMenu');
    if (acctMenu) {
      acctMenu.addEventListener('click', function (e) {
        var b = e.target && e.target.closest ? e.target.closest('button[data-act]') : null;
        if (!b) return;
        var act = b.getAttribute('data-act');
        closeMenus();
        if (act === 'login') openModal();
        else if (act === 'phone') openPhone('bind');
        else if (act === 'reset') resetFunds();
        else if (act === 'logout') {
          dropAuth();
          toast('已退出，回到本机账户');
        }
      });
    }

    // 滚动/缩放后浮层还停在原地就错位了，直接收起
    window.addEventListener('resize', function () { closeMenus(); });
    window.addEventListener('scroll', function () { closeMenus(); }, true);

    // 点空白处关掉浮层；点工具条按钮本身不关（否则刚开就被关）
    document.addEventListener('click', function (e) {
      var t = e.target;
      if (t && t.closest) {
        var list = $('maList');
        if (list && !list.hidden && !t.closest('#chartInds')) {
          list.hidden = true;
          var mt = $('maToggle');
          if (mt) {
            mt.setAttribute('aria-expanded', 'false');
            mt.textContent = '均线 ▾';
          }
        }
        if (
          t.closest('#maPop') || t.closest('#ctxMenu') || t.closest('#acctMenu') ||
          t.closest('#btnMenu') || t.closest('#maTools') ||
          t.closest('#orderActions') || t.closest('#tblPos')
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

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') {
        closeModal();
        closePhone();
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
  }

  function bindSeg(id, cb) {
    var seg = $(id);
    if (!seg) return;
    seg.addEventListener('click', function (e) {
      var b = e.target.closest('button');
      if (!b) return;
      Array.prototype.forEach.call(seg.querySelectorAll('button'), function (x) { x.classList.remove('is-on'); });
      b.classList.add('is-on');
      if (cb) cb(b);
    });
  }

  /** 顶部切到开仓/平仓后，底部两个按钮的文案、颜色、数量区跟着换。 */
  function updateOrderUI() {
    var isClose = orderMode === 'close';
    var form = $('orderForm');
    if (form && form.classList) form.classList.toggle('is-close', isClose);

    var qtyRow = $('qtyRow');
    if (qtyRow) qtyRow.hidden = isClose;

    var pctRow = $('closePctRow');
    if (pctRow) pctRow.hidden = !isClose;
    if (isClose) updateClosePctUI();

    var hint = $('closeHint');
    if (hint) {
      hint.hidden = false;
      if (isClose) {
        var longQty = 0;
        var shortQty = 0;
        positionsOf('long').forEach(function (p) { longQty += p.qty; });
        positionsOf('short').forEach(function (p) { shortQty += p.qty; });
        hint.textContent = longQty || shortQty
          ? '可平空 ' + fmtQty(shortQty) + ' BTC · 可平多 ' + fmtQty(longQty) + ' BTC'
          : '暂无可平持仓';
      } else {
        hint.textContent = '按当前价成交 · 可用 ' + fmtPrice(Account.data ? Account.data.cash : 0) + ' USDT';
      }
    }

    var acts = $('orderActions');
    if (!acts || !acts.querySelector) return;
    setActionText(acts, 'long', isClose ? '平多' : '看多');
    setActionText(acts, 'short', isClose ? '平空' : '看空');
  }

  function setActionText(acts, side, label) {
    var b = acts.querySelector('button[data-side="' + side + '"]');
    if (!b) return;
    var txt = b.querySelector ? b.querySelector('.ord-act__text') : null;
    if (txt) txt.textContent = label;
    b.setAttribute('aria-label', label);
  }

  // ---------------------------------------------------------------- 加载 K 线
  function switchInterval(iv) {
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

    // 上次连通的 WS 源直接优先，别每次刷新都先去撞被墙的那个
    var lastWs = readLS(LS.ws);
    if (lastWs) {
      var wi = WS_HOSTS.indexOf(lastWs);
      if (wi > 0) WS.idx = wi;
    }

    Account.data = loadGuest();
    restoreAuth();

    // 指标偏好要在建图之前读，均线列表 / 成交量 / MACD 的初始状态才对
    loadIndPrefs();
    fillLegends();
    renderMaTools();
    chartInit();
    bind();
    renderAll();
    showMsg('正在连接行情源…');

    if (Account.mode === 'cloud') {
      api('tradeState', {}).then(function (j) {
        Account.data = j.account;
        renderAll();
      }).catch(function (e) {
        if (e && e.code === 'unauthorized') dropAuth();
        else toast(msgOf(e && e.code));
      });
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
    _tf: TF,
    _trips: roundTrips,
    _stats: tradeStats,
    _unrealized: unrealized,
    _normalizePositions: normalizePositions,
    _groupPositions: groupPositions,
    _localAddPosition: localAddPosition,
    _draw: Draw,
    _chart: Chart
  };
})(window);
