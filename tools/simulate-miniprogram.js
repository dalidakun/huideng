/**
 * 无开发者工具时的最小运行模拟：用 mock wx 跑一遍页面生命周期，
 * 主要用来抓 JS 运行时错误（不校验 WXML/WXSS 渲染）。
 * 用法：node tools/simulate-miniprogram.js
 */
const path = require('path');

const ROOT = path.resolve(__dirname, '..', 'miniprogram');
const mem = {};

global.wx = {
  getStorageSync: (k) => mem[k],
  setStorageSync: (k, v) => {
    mem[k] = v;
  },
  removeStorageSync: (k) => {
    delete mem[k];
  },
  setNavigationBarTitle: () => {},
  setNavigationBarColor: () => {},
  setBackgroundColor: () => {},
  pageScrollTo: () => {},
  nextTick: (fn) => fn(),
  createSelectorQuery: () => ({
    select: () => ({ boundingClientRect: () => {} }),
    exec: (cb) => cb([null]),
  }),
  getWindowInfo: () => ({ windowHeight: 667 }),
  showToast: () => {},
  navigateTo: () => {},
  navigateBack: () => {},
  showActionSheet: (opt) => opt.success && opt.success({ tapIndex: 1 }),
  showModal: (opt) => opt.success && opt.success({ confirm: false }),
  setClipboardData: () => {},
};

let lastDef = null;
global.Page = (def) => {
  lastDef = def;
};
global.App = () => {};
global.getApp = () => ({ globalData: { config: {} } });

function loadPage(rel, options) {
  const file = path.join(ROOT, rel);
  delete require.cache[require.resolve(file)];
  require(file);
  const def = lastDef;
  const inst = Object.create(def);
  inst.data = JSON.parse(JSON.stringify(def.data || {}));
  inst.setData = function (patch, cb) {
    Object.keys(patch).forEach((k) => {
      const m = k.match(/^(\w+)\[(\d+)\]\.(\w+)$/);
      if (m) {
        this.data[m[1]][Number(m[2])][m[3]] = patch[k];
      } else {
        this.data[k] = patch[k];
      }
    });
    if (cb) cb();
  };
  if (def.onLoad) def.onLoad.call(inst, options || {});
  if (def.onShow) def.onShow.call(inst);
  return inst;
}

function assert(cond, msg) {
  if (!cond) {
    console.log('  ✗ ' + msg);
    process.exitCode = 1;
  } else {
    console.log('  ✓ ' + msg);
  }
}

console.log('[shelf]');
const shelf = loadPage('pages/shelf/shelf.js');
assert(shelf.data.books.length === 8, '书目 8 部');
assert(shelf.data.filtered.length === 8, '默认列表 8 部');
shelf.onSearch({ detail: { value: '心经' } });
assert(shelf.data.filtered.length === 1, '搜索「心经」命中 1 部');
shelf.clearSearch();
assert(shelf.data.filtered.length === 8, '清空搜索恢复 8 部');

console.log('[reader]');
const reader = loadPage('pages/reader/reader.js', { id: 'T08n0251_001' });
assert(reader.data.total === 23, '心经 23 段（实际 ' + reader.data.total + '）');
assert(reader.data.paras.length === 23, '首屏渲染 23 段');
assert(reader.data.book.title === '般若波罗蜜多心经', '标题正确');
reader.onPageScroll({ detail: { scrollTop: 120 } });
reader.data.keyword = '空';
reader.doSearch();
assert(reader.data.matchCount > 0, '书内检索「空」有结果');
reader.changeFont({ currentTarget: { dataset: { delta: 1 } } });
assert(reader.data.fsIndex === 3, '字号 +1');
reader.switchTheme();
assert(reader.data.theme === 'white', '背景切换');

console.log('[reader 长文]');
const big = loadPage('pages/reader/reader.js', { id: 'T48n2008_001' });
assert(big.data.total === 330, '坛经 330 段（实际 ' + big.data.total + '）');
assert(big.data.paras.length === 80, '首屏只渲染 80 段');
big.onReachBottom();
assert(big.data.paras.length === 160, '触底后追加到 160 段');
big.onPageScroll({ detail: { scrollTop: 3000 } });

console.log('[note-edit]');
const editor = loadPage('pages/note-edit/note-edit.js', {
  id: 'T08n0251_001',
  i: '0',
});
assert(!!editor.data.quote, '带出原文');
editor.onInput({ detail: { value: '观自在，照见五蕴皆空。' } });
editor.save();
assert(!!wx.getStorageSync('hd_notes_v1')['T08n0251_001#0'], '笔记已写入本地');

console.log('[reader 回显笔记]');
reader.onShow();
assert(reader.data.paras[0].n === true, '第一段出现笔记标记');

console.log('[notes]');
const notes = loadPage('pages/notes/notes.js');
assert(notes.data.notes.length === 1, '笔记列表 1 条');
assert(notes.data.notes[0].bookTitle === '般若波罗蜜多心经', '笔记关联书名');

console.log('[about / doc]');
const about = loadPage('pages/about/about.js');
assert(about.data.bookCount === 8, '我的页书目统计');
assert(about.data.noteCount === 1, '我的页笔记统计');
const doc = loadPage('pages/doc/doc.js', { type: 'privacy' });
assert(doc.data.doc.title === '隐私政策', '隐私政策页');

console.log(process.exitCode ? '\n模拟失败' : '\n模拟通过');
