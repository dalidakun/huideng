const library = require('../../services/library');
const store = require('../../utils/store');
const config = require('../../utils/config');
const { parseParagraphs } = require('../../utils/paragraphs');

const CHUNK = config.chunkSize || 80;
const THEMES = ['paper', 'white', 'night'];

Page({
  data: {
    book: null,
    paras: [],
    loaded: 0,
    total: 0,
    percent: 0,
    fsIndex: 2,
    theme: 'paper',
    searchOpen: false,
    keyword: '',
    matchCount: 0,
    matchPos: 0,
  },

  onLoad(options) {
    const id = options.id;
    const book = library.getBook(id);
    if (!book) {
      wx.showToast({ title: '未找到这本书', icon: 'none' });
      setTimeout(() => wx.navigateBack(), 800);
      return;
    }
    const text = library.getText(id);
    if (!text) {
      wx.showToast({ title: '正文加载失败', icon: 'none' });
      return;
    }

    this.bookId = id;
    this._full = parseParagraphs(text);
    this._scrollTop = 0;
    this._hits = [];

    const settings = store.getSettings();
    const fsIndex = settings.fsIndex;
    const theme = settings.theme;
    const jump = parseInt(options.para, 10);
    let target = -1;
    let startCount = Math.min(this._full.length, CHUNK);
    let restoreTop = 0;

    if (!isNaN(jump) && jump >= 0) {
      target = Math.min(jump, this._full.length - 1);
      startCount = Math.min(this._full.length, target + 30);
    } else {
      const progress = store.getProgress(id);
      if (progress) {
        const ratio = Math.max(0, Math.min(1, (progress.percent || 0) / 100));
        startCount = Math.min(
          this._full.length,
          Math.max(CHUNK, Math.ceil(this._full.length * ratio) + 30)
        );
        if (progress.fsIndex === fsIndex) restoreTop = progress.scrollTop || 0;
      }
    }

    wx.setNavigationBarTitle({ title: book.title });
    if (theme === 'night') this.applyNightNav(true);

    this.setData(
      {
        book,
        total: this._full.length,
        fsIndex,
        theme,
        loaded: startCount,
        paras: this.buildItems(0, startCount),
      },
      () => {
        if (target >= 0) {
          wx.nextTick(() => this.scrollToPara(target));
        } else if (restoreTop > 0) {
          wx.nextTick(() => wx.pageScrollTo({ scrollTop: restoreTop, duration: 0 }));
        }
      }
    );
  },

  onShow() {
    if (!this._full) return;
    const set = this.noteKeySet();
    const patch = {};
    let changed = false;
    const items = this.data.paras;
    for (let k = 0; k < items.length; k++) {
      const it = items[k];
      const n = !!set[this.bookId + '#' + it.i];
      if (n !== it.n) {
        patch['paras[' + k + '].n'] = n;
        patch['paras[' + k + '].cls'] = it.base + (n ? ' has-note' : '');
        changed = true;
      }
    }
    if (changed) this.setData(patch);
  },

  onHide() {
    this.saveProgress();
  },

  onUnload() {
    this.saveProgress();
  },

  noteKeySet() {
    const set = {};
    store.allNotes().forEach((n) => {
      set[n.bookId + '#' + n.index] = true;
    });
    return set;
  },

  buildItems(from, to) {
    const set = this.noteKeySet();
    const out = [];
    const end = Math.min(to, this._full.length);
    for (let i = from; i < end; i++) {
      const p = this._full[i];
      const n = !!set[this.bookId + '#' + i];
      out.push({
        i,
        t: p.t,
        base: p.cls,
        cls: p.cls + (n ? ' has-note' : ''),
        n,
      });
    }
    return out;
  },

  ensureLoaded(count, cb) {
    const target = Math.min(this._full.length, Math.max(count, this.data.loaded));
    if (target === this.data.loaded) {
      if (cb) cb();
      return;
    }
    this.setData(
      {
        paras: this.buildItems(0, target),
        loaded: target,
      },
      () => {
        if (cb) cb();
      }
    );
  },

  loadMore() {
    if (this.data.loaded >= this.data.total) return;
    const next = Math.min(this.data.total, this.data.loaded + CHUNK);
    this.setData({
      paras: this.data.paras.concat(this.buildItems(this.data.loaded, next)),
      loaded: next,
    });
  },

  onReachBottom() {
    this.loadMore();
  },

  onPageScroll(e) {
    this._scrollTop = e.detail.scrollTop;

    if (!this._ticking) {
      this._ticking = true;
      setTimeout(() => {
        this._ticking = false;
        this.refreshPercent();
      }, 150);
    }

    const now = Date.now();
    if (!this._lastSave || now - this._lastSave > 5000) {
      this._lastSave = now;
      this.saveProgress();
    }
  },

  refreshPercent() {
    const q = wx.createSelectorQuery();
    q.select('.body').boundingClientRect();
    q.exec((res) => {
      const body = res && res[0];
      if (!body) return;
      const info = wx.getWindowInfo ? wx.getWindowInfo() : wx.getSystemInfoSync();
      // 只渲染了前 loaded 段，按比例估算全文高度，避免读到「已加载部分」的底部就显示 100%。
      const ratio = this.data.total / Math.max(1, this.data.loaded);
      const fullHeight = body.height * ratio;
      const denom = Math.max(1, fullHeight - info.windowHeight);
      const percent = Math.max(
        0,
        Math.min(100, Math.round(((this._scrollTop || 0) / denom) * 100))
      );
      if (percent !== this.data.percent) this.setData({ percent });
    });
  },

  saveProgress() {
    if (!this.bookId) return;
    store.setProgress(this.bookId, {
      scrollTop: this._scrollTop || 0,
      percent: this.data.percent || 0,
      fsIndex: this.data.fsIndex,
      at: Date.now(),
    });
  },

  changeFont(e) {
    const delta = Number(e.currentTarget.dataset.delta);
    const next = Math.max(0, Math.min(4, this.data.fsIndex + delta));
    if (next === this.data.fsIndex) return;
    const top = this._scrollTop || 0;
    this.setData({ fsIndex: next }, () => {
      store.setSettings({ fsIndex: next });
      wx.nextTick(() => wx.pageScrollTo({ scrollTop: top, duration: 0 }));
    });
  },

  switchTheme() {
    const idx = THEMES.indexOf(this.data.theme);
    const theme = THEMES[(idx + 1) % THEMES.length];
    this.setData({ theme });
    store.setSettings({ theme });
    this.applyNightNav(theme === 'night');
  },

  applyNightNav(isNight) {
    wx.setNavigationBarColor({
      frontColor: isNight ? '#ffffff' : '#000000',
      backgroundColor: isNight ? '#1b1b1b' : '#f7f3ea',
    });
    if (wx.setBackgroundColor) {
      wx.setBackgroundColor({
        backgroundColor: isNight ? '#1b1b1b' : '#f7f3ea',
        backgroundColorTop: isNight ? '#1b1b1b' : '#f7f3ea',
        backgroundColorBottom: isNight ? '#1b1b1b' : '#f7f3ea',
      });
    }
  },

  openNotes() {
    wx.navigateTo({ url: '/pages/notes/notes' });
  },

  openSearch() {
    this._hits = [];
    this.setData({ searchOpen: true, keyword: '', matchCount: 0, matchPos: 0 });
  },

  closeSearch() {
    this.setData({ searchOpen: false });
  },

  onKeyword(e) {
    this.setData({ keyword: e.detail.value });
  },

  doSearch() {
    const kw = (this.data.keyword || '').trim();
    if (!kw) return;
    const hits = [];
    for (let i = 0; i < this._full.length; i++) {
      if (this._full[i].t.indexOf(kw) >= 0) hits.push(i);
    }
    this._hits = hits;
    if (!hits.length) {
      this.setData({ matchCount: 0, matchPos: 0 });
      wx.showToast({ title: '没有找到', icon: 'none' });
      return;
    }
    this.setData({ matchCount: hits.length, matchPos: 1 });
    this.jumpHit(0);
  },

  prevHit() {
    if (!this._hits.length) return;
    const pos = (this.data.matchPos - 2 + this._hits.length) % this._hits.length;
    this.setData({ matchPos: pos + 1 });
    this.jumpHit(pos);
  },

  nextHit() {
    if (!this._hits.length) return;
    const pos = this.data.matchPos % this._hits.length;
    this.setData({ matchPos: pos + 1 });
    this.jumpHit(pos);
  },

  jumpHit(pos) {
    const i = this._hits[pos];
    this.ensureLoaded(i + 20, () => {
      wx.nextTick(() => this.scrollToPara(i));
    });
  },

  scrollToPara(i) {
    wx.pageScrollTo({
      selector: '#p' + i,
      offsetTop: -20,
      duration: 0,
      fail: () => {},
    });
  },

  onParaLongPress(e) {
    this._longPressAt = Date.now();
    const i = Number(e.currentTarget.dataset.i);
    const note = store.getNote(this.bookId, i);
    wx.showActionSheet({
      itemList: [note ? '查看 / 编辑笔记' : '写笔记', '复制段落'],
      success: (res) => {
        if (res.tapIndex === 0) {
          this.openNoteEditor(i);
        } else {
          this.copyParagraph(i);
        }
      },
    });
  },

  onParaTap(e) {
    if (this._longPressAt && Date.now() - this._longPressAt < 700) return;
    const i = Number(e.currentTarget.dataset.i);
    const note = store.getNote(this.bookId, i);
    if (!note) return;
    wx.showModal({
      title: '段落笔记',
      content: note.text,
      confirmText: '编辑',
      cancelText: '关闭',
      success: (res) => {
        if (res.confirm) this.openNoteEditor(i);
      },
    });
  },

  openNoteEditor(i) {
    wx.navigateTo({
      url: '/pages/note-edit/note-edit?id=' + this.bookId + '&i=' + i,
    });
  },

  copyParagraph(i) {
    wx.setClipboardData({ data: this._full[i].t });
  },
});
