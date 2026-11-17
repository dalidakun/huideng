/* 行情页网络层回归测试（Node，不需要浏览器）
 *
 * 用法：node tools/trade_page_test.js
 *
 * 用假的 fetch / WebSocket / 时钟把 site/assets/js/trade.js 跑起来，验证：
 *   1. 首屏只打可用的源，不去撞被墙的 api.binance.com；
 *   2. WS 连上后实时价、K 线都能更新；
 *   3. WS 断开后自动降级轮询（K 线只取 3 根），随后自动重连回可用源；
 *   4. 连接假死（连着但不来数据）12 秒内会被看门狗踢掉重连；
 *   5. 发现断档会去 REST 补数据（limit=300）；
 *   6. 切到后台断连、回前台重连并补数据。
 *
 * 改 trade.js 的数据层之后跑一遍，比手点浏览器可靠。
 */

'use strict';

const path = require('path');

let failures = 0;
let checks = 0;

function assert(cond, msg) {
  checks += 1;
  if (!cond) {
    failures += 1;
    console.error('  x ' + msg);
  } else {
    console.log('  + ' + msg);
  }
}

// ---------------------------------------------------------------- 假时钟
let clock = Date.parse('2026-10-25T00:00:00Z');
let timerSeq = 1;
const timers = new Map();

function fakeSetTimeout(fn, ms) {
  const id = timerSeq++;
  timers.set(id, { at: clock + Math.max(0, ms | 0), fn, every: 0 });
  return id;
}
function fakeClearTimeout(id) { timers.delete(id); }
function fakeSetInterval(fn, ms) {
  const id = timerSeq++;
  const every = Math.max(1, ms | 0);
  timers.set(id, { at: clock + every, fn, every });
  return id;
}

async function flush() {
  for (let i = 0; i < 40; i += 1) await Promise.resolve();
}

async function advance(ms) {
  const target = clock + ms;
  for (;;) {
    let pickId = 0;
    let pick = null;
    for (const [id, t] of timers) {
      if (t.at > target) continue;
      if (!pick || t.at < pick.at) { pick = t; pickId = id; }
    }
    if (!pick) break;
    clock = pick.at;
    if (pick.every) pick.at = clock + pick.every;
    else timers.delete(pickId);
    try { pick.fn(); } catch (e) { console.error('  ! timer callback threw: ' + e.stack); failures += 1; }
    await flush();
  }
  clock = target;
  await flush();
}

const RealDate = Date;
class FakeDate extends RealDate {
  constructor(...args) { super(...(args.length ? args : [clock])); }
  static now() { return clock; }
}

global.setTimeout = fakeSetTimeout;
global.clearTimeout = fakeClearTimeout;
global.setInterval = fakeSetInterval;
global.clearInterval = fakeClearTimeout;
global.Date = FakeDate;

// ---------------------------------------------------------------- 假 DOM
const els = new Map();
const docListeners = {};
const winListeners = {};

function makeEl(id) {
  const classes = new Set();
  const attrs = {};
  const e = {
    id,
    textContent: '',
    innerHTML: '',
    className: '',
    hidden: false,
    clientHeight: 240,
    clientWidth: 640,
    value: '',
    disabled: false,
    style: {},
    children: [],
    classList: {
      add(c) { classes.add(c); },
      remove(c) { classes.delete(c); },
      toggle(c, force) {
        if (force === undefined) { if (classes.has(c)) classes.delete(c); else classes.add(c); }
        else if (force) classes.add(c);
        else classes.delete(c);
      },
      contains(c) { return classes.has(c); }
    },
    appendChild(c) { e.children.push(c); return c; },
    addEventListener() {},
    focus() {},
    setAttribute(k, v) { attrs[k] = String(v); },
    getAttribute(k) { return attrs[k] === undefined ? null : attrs[k]; },
    querySelectorAll() { return []; }
  };
  return e;
}

function byId(id) {
  if (!els.has(id)) els.set(id, makeEl(id));
  return els.get(id);
}

const documentStub = {
  hidden: false,
  body: makeEl('body'),
  getElementById: byId,
  createElement: () => makeEl('_el'),
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); }
};

global.document = documentStub;
global.getComputedStyle = () => ({ fontFamily: 'sans-serif' });

// ---------------------------------------------------------------- 假存储
const store = new Map();
global.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k)
};

// ---------------------------------------------------------------- 假网络
const net = {
  calls: [],
  failHosts: new Set(['https://api.binance.com', 'https://api1.binance.com', 'https://api2.binance.com']),
  hangHosts: new Set(),
  wsFailHosts: ['wss://stream.binance.com:9443', 'wss://stream.binance.com:443'],
  price: 100000,
  klineStep: 60
};

// 各周期的秒数，和 trade.js 的 TF_MS 对齐，保证换周期后时间轴能对上
const TF_SEC = {
  '1m': 60, '3m': 180, '5m': 300, '15m': 900, '30m': 1800,
  '1h': 3600, '2h': 7200, '4h': 14400, '6h': 21600,
  '8h': 28800, '10h': 36000, '12h': 43200,
  '1d': 86400, '3d': 259200, '5d': 432000,
  '1w': 604800, '1M': 2419200
};

function klineRows(limit, stepSec, endSec) {
  const step = stepSec || net.klineStep;
  const rows = [];
  const base = endSec != null ? Math.floor(endSec / step) * step : Math.floor(clock / 60000) * 60;
  const start = base - (limit - 1) * step;
  for (let i = 0; i < limit; i += 1) {
    const t = start + i * step;
    const open = net.price - 50 + (i % 7);
    rows.push([t * 1000, String(open), String(open + 120), String(open - 80), String(open + 40), String(10 + i)]);
  }
  return rows;
}

function tickerObj() {
  return {
    symbol: 'BTCUSDT',
    lastPrice: String(net.price),
    priceChangePercent: '1.23',
    highPrice: '101500',
    lowPrice: '98000',
    quoteVolume: '123456789'
  };
}

global.fetch = function fakeFetch(url, init) {
  const u = new URL(url);
  const host = u.origin;
  net.calls.push({ host, path: u.pathname + u.search, t: clock });
  const limit = Number(u.searchParams.get('limit') || '0');
  return new Promise((resolve, reject) => {
    let done = false;
    if (init && init.signal) {
      init.signal.addEventListener('abort', () => {
        if (done) return;
        done = true;
        const e = new Error('aborted');
        e.name = 'AbortError';
        reject(e);
      });
    }
    if (net.hangHosts.has(host)) return; // 永不返回，模拟被墙的握手
    if (net.failHosts.has(host)) {
      fakeSetTimeout(() => {
        if (done) return;
        done = true;
        reject(new TypeError('Failed to fetch'));
      }, 15);
      return;
    }
    fakeSetTimeout(() => {
      if (done) return;
      done = true;
      const iv = u.searchParams.get('interval') || '1m';
      const endParam = u.searchParams.get('endTime');
      const endSec = endParam ? Number(endParam) / 1000 : null;
      const body = u.pathname.indexOf('/klines') >= 0
        ? klineRows(limit || 1000, TF_SEC[iv] || 60, endSec)
        : tickerObj();
      resolve({ ok: true, status: 200, json: () => Promise.resolve(body) });
    }, 40);
  });
};

// ---------------------------------------------------------------- 假 WebSocket
const sockets = [];

class FakeWebSocket {
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.sent = [];
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    this.onclose = null;
    sockets.push(this);
    if (net.wsFailHosts.some((h) => url.indexOf(h) === 0)) {
      fakeSetTimeout(() => this._close(), 20);
    } else {
      fakeSetTimeout(() => {
        if (this.readyState !== 0) return;
        this.readyState = 1;
        if (this.onopen) this.onopen();
      }, 30);
    }
  }
  send(d) { this.sent.push(d); }
  close() { this.readyState = 3; }
  _close() {
    if (this.readyState === 3) return;
    this.readyState = 3;
    if (this.onclose) this.onclose();
  }
  emit(data) {
    if (this.readyState !== 1) return;
    if (this.onmessage) this.onmessage({ data: JSON.stringify(data) });
  }
}

global.WebSocket = FakeWebSocket;
global.WebSocket.OPEN = 1;

// window === globalThis；trade.js 是 (function(global){...})(window)
global.window = global;
global.addEventListener = (type, fn) => { (winListeners[type] = winListeners[type] || []).push(fn); };

function dispatchDoc(type) { (docListeners[type] || []).forEach((f) => f({ type })); }
function dispatchWin(type, extra) { (winListeners[type] || []).forEach((f) => f(Object.assign({ type }, extra || {}))); }

// ---------------------------------------------------------------- 假图表
// 只实现 trade.js 用到的接口：K 线、成交量、4 条均线、MACD 柱 + DIF/DEA，
// 以及双图联动需要的 timeScale / crosshair 桩。
const chart = {
  candle: null, vol: null, fits: 0,
  setDataCount: 0, updateCount: 0, updates: [],
  lines: [], hists: [], instances: [], ranges: []
};

function series(kind, options) {
  const rec = {
    kind,
    options: Object.assign({}, options || {}),
    data: [],
    updateCount: 0,
    setData(data) {
      this.data = data.slice();
      chart.setDataCount += 1;
      if (kind === 'candle') chart.candle = this.data;
      if (kind === 'vol') chart.vol = this.data;
    },
    update(d) {
      this.updateCount += 1;
      chart.updateCount += 1;
      chart.updates.push(d);
      this.data.push(d);
      if (kind === 'candle') chart.candle = this.data;
    },
    applyOptions(o) { Object.assign(this.options, o); },
    coordinateToPrice(y) { return 100000 - y; },
    createPriceLine() { return { applyOptions() {} }; }
  };
  return rec;
}

global.LightweightCharts = {
  CrosshairMode: { Normal: 0, Magnet: 1 },
  LineStyle: { Dashed: 2 },
  createChart(box, opts) {
    const inst = {
      _options: opts || {},
      // 视口就存在实例上，切周期时 trade.js 会先读再写，测试才能验证还原结果
      _range: { from: 0, to: 100 },
      _fits: 0,
      addCandlestickSeries(opts) {
        const s = series('candle', opts);
        inst._candleSeries = s;
        return s;
      },
      addHistogramSeries(opts) {
        const s = series('hist', opts);
        chart.hists.push(s);
        return s;
      },
      addLineSeries(opts) {
        const s = series('line', opts);
        chart.lines.push(s);
        return s;
      },
      removeSeries(s) {
        chart.lines = chart.lines.filter((x) => x !== s);
        chart.hists = chart.hists.filter((x) => x !== s);
      },
      priceScale: () => ({ applyOptions() {}, width: () => 88 }),
      subscribeCrosshairMove(fn) { inst._crosshair = fn; },
      timeScale: () => {
        if (!inst._timescale) {
          inst._timescale = {
            fitContent() { chart.fits += 1; inst._fits += 1; },
            getVisibleLogicalRange() { return Object.assign({}, inst._range); },
            setVisibleLogicalRange(r) {
              inst._range = { from: r.from, to: r.to };
              chart.ranges.push({ from: r.from, to: r.to });
            },
            subscribeVisibleLogicalRangeChange() {},
            options() { return { barSpacing: 6 }; },
            timeToCoordinate() { return 100; },
            coordinateToTime() { return null; },
            height() { return 0; }
          };
        }
        return inst._timescale;
      },
      applyOptions() {},
      setCrosshairPosition() {},
      clearCrosshairPosition() {}
    };
    chart.instances.push(inst);
    return inst;
  }
};

// ---------------------------------------------------------------- 加载被测脚本
require(path.join(__dirname, '..', 'site', 'assets', 'js', 'trade.js'));

const TradePage = global.TradePage;
const state = TradePage._state;

function srcText() { return byId('srcText').textContent; }
function lastPrice() { return byId('lastPrice').textContent; }
function latestSocket() { return sockets[sockets.length - 1]; }

(async function run() {
  console.log('\n[1] first load: healthy source only + chart data');
  TradePage.start({ api: '', key: '', rel: '' });
  await advance(500);

  assert(state.bars.length === 1000, 'first load pulls 1000 candles');
  assert(chart.candle && chart.candle.length === 1000, 'candles written into chart');
  assert(lastPrice() === '100,000.00', 'last price rendered (' + lastPrice() + ')');
  assert(/实时/.test(srcText()), 'status switches to live (' + srcText() + ')');

  const apiHits = net.calls.filter((c) => c.host === 'https://api.binance.com');
  assert(apiHits.length === 0, 'never hits api.binance.com (' + apiHits.length + ')');
  const firstHost = net.calls[0].host;
  assert(firstHost === 'https://data-api.binance.vision', 'prefers .vision host (' + firstHost + ')');

  console.log('\n[1b] indicators: 3 MAs on the main chart, MACD below');
  assert(chart.lines.length === 5, 'MA5/10/20 + DIF + DEA series (' + chart.lines.length + ')');
  assert(chart.hists.length === 2, 'volume + MACD histogram series (' + chart.hists.length + ')');
  assert(chart.hists[1].data.length === 1000, 'MACD histogram covers every bar');

  const ma5 = chart.lines[0];
  assert(ma5.data.length === 996, 'MA5 starts at the 5th candle (' + ma5.data.length + ')');
  const closes = klineRows(1000).map((r) => Number(r[4]));
  const expectMa5 = (closes[0] + closes[1] + closes[2] + closes[3] + closes[4]) / 5;
  assert(Math.abs(ma5.data[0].value - expectMa5) < 1e-6, 'MA5 equals the 5-close average');
  assert(ma5.data[0].time === Math.floor(clock / 60000) * 60 - 999 * 60 + 4 * 60,
    'MA5 timestamps stay aligned with the candles');

  const dif = chart.lines[3].data;
  const dea = chart.lines[4].data;
  assert(dif.length === 1000 && dea.length === 1000, 'DIF/DEA have one point per candle');
  assert(Math.abs(dif[0].value) < 1e-9, 'DIF starts at zero (both EMAs seeded with the first close)');
  // 用一条固定序列直接验算 MACD，避免公式被改坏却没人发现
  const ind = TradePage._indicator([
    { close: 1 }, { close: 2 }, { close: 3 }, { close: 4 }, { close: 5 }
  ]);
  function emaSeq(vals, n) {
    const k = 2 / (n + 1);
    const out = [vals[0]];
    for (let i = 1; i < vals.length; i += 1) out[i] = vals[i] * k + out[i - 1] * (1 - k);
    return out;
  }
  const e12 = emaSeq([1, 2, 3, 4, 5], 12);
  const e26 = emaSeq([1, 2, 3, 4, 5], 26);
  assert(Math.abs(ind.dif[4] - (e12[4] - e26[4])) < 1e-12, 'DIF = EMA12 - EMA26');
  assert(Math.abs(ind.hist[4] - (ind.dif[4] - ind.dea[4]) * 2) < 1e-12, 'histogram = 2 x (DIF - DEA)');

  console.log('\n[1b2] crosshair tracks the pointer; price tag also works in the future zone');
  const mainInst = chart.instances[0];
  const macdInst = chart.instances[1];
  assert(mainInst._options.crosshair.mode === 0, 'main chart uses CrosshairMode.Normal');
  assert(macdInst._options.crosshair.mode === 0, 'MACD chart uses CrosshairMode.Normal');

  const hoverTag = byId('hoverTag');
  TradePage._updateHoverTag({ point: { y: 100 } }, true);
  assert(hoverTag.hidden === false, 'price tag shows with pointer position only (no bar under cursor)');
  assert(hoverTag.textContent === '99,900.00', 'price comes from coordinateToPrice (' + hoverTag.textContent + ')');
  assert(hoverTag.style.top === '100px', 'tag sits exactly on the pointer y (' + hoverTag.style.top + ')');
  TradePage._updateHoverTag({}, true);
  assert(hoverTag.hidden === true, 'leaving the chart hides the tag');
  TradePage._updateHoverTag({ point: { y: 100 } }, false);
  assert(hoverTag.hidden === true, 'no price tag over the MACD pane');

  console.log('\n[1d] MA add / change / remove, volume toggle');
  const beforeLines = chart.lines.length;
  TradePage._addMa(30);
  assert(chart.lines.length === beforeLines + 1, 'adding MA30 creates a line');
  assert(TradePage._ma.ma.some((m) => m.p === 30 && m.c), 'MA30 is in the list with a colour');
  assert(chart.lines[chart.lines.length - 1].data.length === 971, 'MA30 has 1000-30+1 points');
  TradePage._changeMa(30, 60);
  assert(TradePage._ma.ma.some((m) => m.p === 60), 'MA30 is changed to MA60');
  assert(!TradePage._ma.ma.some((m) => m.p === 30), 'the old period is gone');
  assert(chart.lines.some((s) => s.data.length === 941), 'MA60 series has 1000-60+1 points');
  TradePage._removeMa(60);
  assert(!TradePage._ma.ma.some((m) => m.p === 60), 'MA60 is removed');
  assert(chart.lines.length === beforeLines, 'the series is removed with the line');
  TradePage._setVol(false);
  assert(chart.hists[0].options.visible === false, 'volume series hidden');
  TradePage._setVol(true);
  assert(chart.hists[0].options.visible === true, 'volume series shown again');

  TradePage._setMaColor(10, '#123456');
  assert(TradePage._ma.ma.find((m) => m.p === 10).c === '#123456', 'MA colour updates the model');
  assert(TradePage._chart.ma[10].options.color === '#123456', 'MA colour updates the series');
  assert(localStorage.getItem('huideng.trade.ind').indexOf('#123456') >= 0, 'MA colour is persisted');
  TradePage._setMaColor(10, '#2F6F8F');
  assert(TradePage._chart.ma[10].options.color.toLowerCase() === '#2f6f8f', 'MA colour can be changed again');

  const newTfs = ['3m', '30m', '2h', '6h', '8h', '10h', '12h', '3d', '5d', '1w', '1M'];
  assert(newTfs.every((iv) => TradePage._tf.indexOf(iv) >= 0), '3m/30m/2h/6h/8h/10h/12h/3d/5d/1w/1M are registered');

  console.log('\n[1e] round trips: open+close = one record, win rate / today');
  const hist = TradePage._account.data.history;
  hist.length = 0;
  hist.push(
    { type: 'close', side: 'long', qty: 1, price: 110, pnl: 10, at: clock },
    { type: 'open', side: 'long', qty: 1, price: 100, pnl: 0, at: clock - 60000 },
    { type: 'close', side: 'short', qty: 1, price: 105, pnl: -5, at: clock - 120000 },
    { type: 'open', side: 'short', qty: 1, price: 100, pnl: 0, at: clock - 180000 }
  );
  const tripsNow = TradePage._trips();
  assert(tripsNow.length === 2, 'two opens + two closes = two round trips');
  assert(tripsNow[0].entry === 100 && tripsNow[0].exit === 110 && tripsNow[0].pnl === 10,
    'the newest trip pairs the matching open');
  const statsNow = TradePage._stats();
  assert(statsNow.today === 2, 'both trips count towards today');
  assert(statsNow.winRate === 50, 'win rate = 1 win out of 2 trades');
  hist.length = 0;

  // 部分平仓：同一笔开仓分两次平，按持仓 id 配对
  const nowMs = Date.now();
  hist.push(
    { type: 'close', side: 'long', qty: 0.5, price: 110, pnl: 50, at: nowMs, posId: 'p1' },
    { type: 'close', side: 'long', qty: 0.5, price: 108, pnl: 40, at: nowMs - 1000, posId: 'p1' },
    { type: 'open', side: 'long', qty: 1, price: 100, pnl: 0, at: nowMs - 2000, posId: 'p1' }
  );
  const partial = TradePage._trips();
  assert(partial.length === 2, 'two partial closes make two trips');
  assert(partial.every((t) => t.entry === 100 && t.qty === 0.5), 'both partial closes pair with the open');

  // 同方向多次开仓合并后，历史里的开仓价也要用加权成本均价
  hist.push(
    { type: 'close', side: 'long', qty: 2, price: 120, pnl: 300, at: nowMs + 1000, posId: 'p2' },
    { type: 'open', side: 'long', qty: 1, price: 110, pnl: 0, at: nowMs - 1000, posId: 'p2' },
    { type: 'open', side: 'long', qty: 1, price: 100, pnl: 0, at: nowMs - 2000, posId: 'p2' }
  );
  const mergedTrip = TradePage._trips().find((t) => Math.abs(t.entry - 105) < 1e-9);
  assert(mergedTrip && mergedTrip.qty === 2,
    'merged opens use the weighted cost in history (' + (mergedTrip && mergedTrip.entry) + ')');
  hist.length = 0;

  assert(TradePage._unrealized({ side: 'long', entry: 100, qty: 2 }, 110) === 200,
    'long PnL is multiplied by 10');
  assert(TradePage._unrealized({ side: 'short', entry: 100, qty: 1 }, 90) === 100,
    'short PnL is multiplied by 10');

  console.log('\n[1f] same-side opens merge into one position with weighted entry');
  const book = { positions: [] };
  TradePage._localAddPosition(book, 'long', 1, 100, 100, 0);
  TradePage._localAddPosition(book, 'long', 2, 130, 260, 0);
  assert(book.positions.length === 1, 'two long opens stay one position');
  assert(book.positions[0].qty === 3, 'quantities add up (' + book.positions[0].qty + ')');
  assert(Math.abs(book.positions[0].entry - 120) < 1e-9,
    'entry is the weighted cost (' + book.positions[0].entry + ')');
  assert(book.positions[0].margin === 360, 'margin adds up (' + book.positions[0].margin + ')');
  assert(Math.abs(TradePage._unrealized(book.positions[0], 140) - 600) < 1e-9,
    'unrealized PnL covers the merged quantity');
  TradePage._localAddPosition(book, 'short', 1, 140, 140, 0);
  assert(book.positions.length === 2, 'the opposite side stays separate');

  const legacy = {
    positions: [
      { id: 'a', side: 'long', qty: 1, entry: 100, margin: 100, openFee: 0 },
      { id: 'b', side: 'long', qty: 2, entry: 130, margin: 260, openFee: 0 }
    ]
  };
  TradePage._normalizePositions(legacy);
  assert(legacy.positions.length === 1, 'legacy duplicates are merged on load');
  assert(legacy.positions[0].qty === 3 && Math.abs(legacy.positions[0].entry - 120) < 1e-9,
    'legacy merge keeps quantity and weighted cost');

  const cloud = TradePage._groupPositions([
    { id: 'c1', side: 'long', qty: 1, entry: 100, margin: 100 },
    { id: 'c2', side: 'long', qty: 2, entry: 130, margin: 260 },
    { id: 's1', side: 'short', qty: 1, entry: 150, margin: 150 }
  ]);
  assert(cloud.length === 2, 'cloud rows group by side');
  assert(cloud[0].qty === 3 && Math.abs(cloud[0].entry - 120) < 1e-9,
    'cloud display uses the weighted cost');

  console.log('\n[1c] hover: a live tick must not clobber the hovered readout');
  const mainChart = chart.instances[0];
  const hoverBar = state.bars[100];
  mainChart._crosshair({
    time: hoverBar.time,
    seriesData: new Map([[mainChart._candleSeries, {
      time: hoverBar.time,
      open: hoverBar.open,
      high: hoverBar.high,
      low: hoverBar.low,
      close: hoverBar.close
    }]])
  });
  const hoveredChg = byId('lgChg').textContent;
  assert(hoveredChg !== '--', 'hover writes the readout into the legend (' + hoveredChg + ')');
  const hoveredMa = byId('maLegend').textContent;
  const lastBarNow = state.bars[state.bars.length - 1];
  latestSocket().emit({
    stream: 'btcusdt@kline_1m',
    data: {
      e: 'kline',
      k: { t: lastBarNow.time * 1000, i: '1m', o: lastBarNow.open, h: lastBarNow.high, l: lastBarNow.low, c: lastBarNow.close, v: lastBarNow.volume }
    }
  });
  assert(byId('lgChg').textContent === hoveredChg, 'live tick keeps the hovered readout');
  assert(byId('maLegend').textContent === hoveredMa, 'live tick keeps the hovered MA values');
  mainChart._crosshair({ time: null });

  console.log('\n[2] WS push: price and candle update');
  const ws = latestSocket();
  assert(/data-stream\.binance\.vision/.test(ws.url), 'WS goes to data-stream');
  assert(ws.readyState === 1, 'WS is open');

  net.price = 101234.5;
  ws.emit({ stream: 'btcusdt@ticker', data: Object.assign({ e: '24hrTicker' }, tickerObj()) });
  assert(lastPrice() === '101,234.50', 'price updates on push (' + lastPrice() + ')');

  const updatesBefore = chart.updateCount;
  const lastBar = state.bars[state.bars.length - 1];
  ws.emit({
    stream: 'btcusdt@kline_1m',
    data: { e: 'kline', k: { t: (lastBar.time + 60) * 1000, i: '1m', o: 101000, h: 101300, l: 100900, c: 101200, v: 12 } }
  });
  assert(chart.updateCount > updatesBefore, 'candle update called');
  assert(chart.lines[0].updateCount > 0, 'MA lines update on every tick');
  assert(chart.lines[4].updateCount > 0, 'MACD updates on every tick');
  assert(state.bars[state.bars.length - 1].time === lastBar.time + 60, 'new candle appended');

  console.log('\n[3] gap: missing candles backfilled over REST');
  const tail = state.bars[state.bars.length - 1];
  ws.emit({
    stream: 'btcusdt@kline_1m',
    data: { e: 'kline', k: { t: (tail.time + 5 * 60) * 1000, i: '1m', o: 101200, h: 101400, l: 101000, c: 101300, v: 3 } }
  });
  await advance(4000);
  const healCall = net.calls.filter((c) => c.path.indexOf('/klines') >= 0 && /limit=300/.test(c.path));
  assert(healCall.length > 0, 'gap triggers limit=300 backfill (' + healCall.length + ')');
  assert(chart.setDataCount > 1, 'backfill redraws the series, no holes left');

  console.log('\n[4] WS drop: polling fallback + auto reconnect');
  const dropTime = clock;
  ws._close();
  await advance(1200);
  assert(/轮询模式/.test(srcText()), 'falls back to polling (' + srcText() + ')');
  const pollKlines = net.calls.filter((c) => c.t >= dropTime && c.path.indexOf('/klines') >= 0 && /limit=3(&|$)/.test(c.path));
  assert(pollKlines.length > 0, 'polling only asks for 3 candles');

  await advance(12000);
  const latest = latestSocket();
  assert(/data-stream/.test(latest.url) && latest.readyState === 1, 'reconnects to data-stream after backoff');
  assert(/实时/.test(srcText()), 'status back to live (' + srcText() + ')');
  assert(sockets.length >= 3, 'blocked hosts were skipped (sockets=' + sockets.length + ')');

  console.log('\n[5] dead socket: watchdog kicks in after 12s of silence');
  const beforeStall = sockets.length;
  await advance(17000);
  assert(sockets.length > beforeStall, 'watchdog reconnected (' + beforeStall + ' -> ' + sockets.length + ')');
  assert(/实时|轮询/.test(srcText()), 'status never lies about being live (' + srcText() + ')');

  console.log('\n[6] background: disconnect, then reconnect + backfill on return');
  documentStub.hidden = true;
  dispatchDoc('visibilitychange');
  await advance(100);
  assert(latestSocket().readyState === 3, 'disconnects immediately when hidden');

  documentStub.hidden = false;
  dispatchDoc('visibilitychange');
  await advance(500);
  const afterShow = latestSocket();
  assert(afterShow.readyState === 1 && /data-stream/.test(afterShow.url), 'reconnects on return');
  assert(chart.setDataCount > 0 && state.bars.length > 0, 'backfills data on return');

  console.log('\n[7] switching period keeps the bar count (candle width) and right-edge time');
  // 模拟用户放大到 100 根的一段历史，右边界停在 100 根之前，再切到 5 分钟线
  const mainTs = chart.instances[0];
  const keepLast = state.bars.length - 1;
  const viewFrom = keepLast - 200;
  const viewTo = keepLast - 100;
  const toTime = state.bars[viewTo].time;
  mainTs._range = { from: viewFrom, to: viewTo };
  const fitsBefore = chart.fits;

  TradePage._switch('5m');
  await advance(500);

  const bars5m = state.bars;
  assert(state.iv === '5m' && bars5m.length === 1000, '5m candles loaded (' + state.iv + '/' + bars5m.length + ')');
  assert(chart.fits === fitsBefore, 'no fitContent on switch, the zoom is kept');
  const r5 = mainTs._range;
  assert(Math.abs((r5.to - r5.from) - 100) < 0.001,
    'same number of candles, same candle width (' + (r5.to - r5.from).toFixed(2) + ' bars)');
  // 右边界时间不变（换周期后时间轴刻度变了，所以从下标反算）
  const at5 = (idx) => {
    const i = Math.floor(idx);
    return bars5m[i].time + (idx - i) * 300;
  };
  assert(Math.abs(at5(r5.to) - toTime) < 1.5, 'right edge stays on the same bar time');
  assert(r5.from >= 0 && r5.to <= bars5m.length - 1 + 6, 'restored range stays inside the loaded data');
  const span5m = (r5.to - r5.from) * 5;
  assert(span5m > 100, 'the view now covers 100 x 5m = ' + span5m + ' minutes');

  console.log('\n[7b] a huge timeframe jump keeps the same bar count (no giant candle)');
  TradePage._switch('1d');
  await advance(500);
  const r1d = mainTs._range;
  assert(state.iv === '1d' && state.bars.length === 1000, '1d candles loaded');
  assert(chart.fits === fitsBefore, 'still no fitContent on switch');
  assert(Math.abs((r1d.to - r1d.from) - 100) < 0.001,
    'still 100 daily bars on screen (' + (r1d.to - r1d.from).toFixed(2) + ')');
  assert(r1d.from >= 0 && r1d.to <= state.bars.length - 1 + 6, '1d range also stays inside the data');

  console.log('\n[7c] at the live edge the right-hand gutter is kept');
  const last1d = state.bars.length - 1;
  const rBeforeEdge = { from: last1d - 99, to: last1d + 6 };
  mainTs._range = rBeforeEdge;
  TradePage._switch('1h');
  await advance(500);
  const bars1h = state.bars;
  const r1h = mainTs._range;
  assert(state.iv === '1h' && bars1h.length === 1000, '1h candles loaded');
  assert(Math.abs((r1h.to - r1h.from) - 105) < 0.001,
    'same 100 candles + 6-bar gutter (' + (r1h.to - r1h.from).toFixed(2) + ')');
  assert(Math.abs(r1h.to - (bars1h.length - 1 + 6)) < 0.001,
    'right edge sits 6 bars after the newest candle');
  assert(chart.fits === fitsBefore, 'still no fitContent at the live edge');

  console.log('\n[7d] a small right-hand gap survives even when the left edge is in whitespace');
  // 用户把最后一根拖到离右边界 1 根的位置（左侧已经进入数据外留白），切周期后
  // 这根 K 线的位置不能被「左边界夹回 0」的兜底推走
  const last1h = state.bars.length - 1;
  mainTs._range = { from: -5, to: last1h + 1 };
  TradePage._switch('30m');
  await advance(500);
  const bars30m = state.bars;
  const r30 = mainTs._range;
  assert(state.iv === '30m' && bars30m.length === 1000, '30m candles loaded');
  assert(Math.abs(r30.to - (bars30m.length - 1 + 1)) < 0.001,
    'newest candle still sits 1 bar from the right edge (' + r30.to + ')');
  assert(Math.abs((r30.to - r30.from) - 1005) < 0.001,
    'bar count / candle width unchanged (' + (r30.to - r30.from).toFixed(2) + ')');
  assert(r30.from < 0, 'left whitespace is kept instead of being clamped to 0 (' + r30.from.toFixed(2) + ')');
  assert(chart.fits === fitsBefore, 'still no fitContent in the whitespace case');

  console.log('\n[7e] a large right-hand gutter (dragged far) is preserved too');
  // 用户可以把图往右拖出几十根留白，切周期后这段留白不能缩回 rightOffset（6 根）
  const last30 = state.bars.length - 1;
  mainTs._range = { from: last30 + 62 - 100, to: last30 + 62 };
  TradePage._switch('5m');
  await advance(500);
  const bars5b = state.bars;
  const r5b = mainTs._range;
  assert(state.iv === '5m' && bars5b.length === 1000, '5m candles loaded again');
  assert(Math.abs(r5b.to - (bars5b.length - 1 + 62)) < 0.001,
    'the 62-bar gutter is kept (' + (r5b.to - (bars5b.length - 1)).toFixed(2) + ' bars)');
  assert(Math.abs((r5b.to - r5b.from) - 100) < 0.001,
    'bar count / candle width unchanged (' + (r5b.to - r5b.from).toFixed(2) + ')');
  assert(chart.fits === fitsBefore, 'still no fitContent with a large gutter');

  console.log('\n[8] 10h / 5d are synthesized from 2h / 1d, 6h / 3d are native');
  const b0 = 36000 * 100;
  const agg = TradePage._aggregate([
    [b0 * 1000, '100', '110', '90', '105', '1'],
    [(b0 + 7200) * 1000, '105', '120', '100', '118', '2'],
    [(b0 + 14400) * 1000, '118', '119', '80', '85', '3'],
    [(b0 + 21600) * 1000, '85', '90', '70', '75', '4'],
    [(b0 + 28800) * 1000, '75', '95', '60', '90', '5'],
    [(b0 + 36000) * 1000, '90', '92', '88', '91', '6']
  ], 36000);
  assert(agg.length === 2, 'five 2h candles merge into one 10h candle (' + agg.length + ')');
  assert(+agg[0][1] === 100 && +agg[0][2] === 120 && +agg[0][3] === 60 && +agg[0][4] === 90,
    'merged OHLC keeps first open / max high / min low / last close');
  assert(+agg[0][5] === 15, 'merged volume adds up (' + agg[0][5] + ')');
  const partialAgg = TradePage._aggregate([
    [(b0 + 7200) * 1000, '1', '1', '1', '1', '1'],
    [(b0 + 14400) * 1000, '1', '1', '1', '1', '1']
  ], 36000);
  assert(partialAgg.length === 0, 'a bucket cut by the page edge is dropped, not emitted half-formed');

  let callsMark = net.calls.length;
  TradePage._switch('10h');
  await advance(500);
  assert(state.iv === '10h' && state.bars.length >= 900, '10h candles loaded (' + state.bars.length + ')');
  assert(state.bars[1].time - state.bars[0].time === 36000, '10h candles are exactly 10 hours apart');
  const calls10 = net.calls.slice(callsMark).filter((c) => c.path.indexOf('/klines') >= 0);
  assert(calls10.filter((c) => /interval=2h/.test(c.path)).length >= 5,
    '10h is built from 5 pages of 2h candles (' + calls10.length + ' requests)');

  callsMark = net.calls.length;
  TradePage._switch('5d');
  await advance(500);
  assert(state.iv === '5d' && state.bars.length >= 900, '5d candles loaded (' + state.bars.length + ')');
  assert(state.bars[1].time - state.bars[0].time === 432000, '5d candles are exactly 5 days apart');
  assert(net.calls.slice(callsMark).some((c) => /interval=1d/.test(c.path)),
    '5d is built from 1d candles');

  callsMark = net.calls.length;
  TradePage._switch('6h');
  await advance(500);
  assert(state.iv === '6h' && state.bars.length === 1000, '6h candles load natively');
  assert(net.calls.slice(callsMark).some((c) => /interval=6h/.test(c.path)), '6h uses the native 6h interval');

  callsMark = net.calls.length;
  TradePage._switch('3d');
  await advance(500);
  assert(state.iv === '3d' && state.bars.length === 1000, '3d candles load natively');
  assert(net.calls.slice(callsMark).some((c) => /interval=3d/.test(c.path)), '3d uses the native 3d interval');

  console.log('\n[9] symbol search switches the chart without touching the BTC account');
  callsMark = net.calls.length;
  TradePage._switchSymbol('ETHUSDT');
  await advance(500);
  assert(state.symbol === 'ETHUSDT', 'chart symbol switched to ETHUSDT (' + state.symbol + ')');
  assert(state.bars.length === 1000, 'ETHUSDT candles loaded (' + state.bars.length + ')');
  assert(net.calls.slice(callsMark).some((c) => /symbol=ETHUSDT/.test(c.path)),
    'klines are requested for the new symbol');
  const ethSocket = latestSocket();
  assert(/ethusdt@kline_3d/.test(ethSocket.url), 'kline stream follows the chart symbol (' + ethSocket.url + ')');
  assert(/btcusdt@ticker/.test(ethSocket.url), 'ticker stays on BTC for the simulated account');
  assert(TradePage._state.price > 0 && state.ticker && state.ticker.price > 0,
    'BTC mark price is untouched by the chart shift');

  TradePage._switchSymbol('BTCUSDT');
  await advance(500);
  assert(state.symbol === 'BTCUSDT', 'can switch back to BTCUSDT');
  assert(net.calls.slice(callsMark).some((c) => /symbol=BTCUSDT/.test(c.path)),
    'klines are requested for BTC again');

  console.log('\n[10] 画线按设备分开存：手机只显示手机画的，电脑只显示电脑画的');
  const devLines = TradePage._parseDrawings([
    { infinite: true, points: [{ t: 1700000000, p: 100 }, { t: 1700000600, p: 120 }], dev: 'm' },
    { infinite: true, points: [{ t: 1700000000, p: 100 }, { t: 1700000600, p: 120 }], dev: 'd' },
    { infinite: true, points: [{ t: 1700000000, p: 100 }, { t: 1700000600, p: 120 }] }
  ]);
  assert(devLines.length === 3, 'three saved lines are parsed (' + devLines.length + ')');
  assert(devLines[0].dev === 'm', 'a mobile line keeps dev=m');
  assert(devLines[1].dev === 'd' && devLines[2].dev === 'd',
    'desktop lines and legacy data (no dev) count as desktop');
  const myDev = TradePage._drawDev === 'm' ? 'm' : 'd';
  assert(devLines.filter(TradePage._lineShown).length === (myDev === 'd' ? 2 : 1),
    'only this device\'s lines are drawn (' + myDev + ')');
  TradePage._draw.lines = devLines;
  const devSaved = TradePage._serializeDrawings();
  assert(devSaved.length === 3, 'serializing keeps the other device\'s lines too (' + devSaved.length + ')');
  assert(devSaved.filter((o) => o.dev === 'm').length === 1 && devSaved.filter((o) => o.dev === 'd').length === 2,
    'every serialized line carries its device tag');

  console.log('\n----------------------------------------');
  if (failures) {
    console.error(`FAILED ${failures} / ${checks}`);
    process.exit(1);
  }
  console.log(`all passed (${checks} checks)`);
  process.exit(0);
})().catch((e) => {
  console.error('test script crashed:', e);
  process.exit(1);
});
