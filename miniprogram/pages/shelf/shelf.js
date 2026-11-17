const library = require('../../services/library');
const store = require('../../utils/store');
const config = require('../../utils/config');
const { formatChars } = require('../../utils/format');

Page({
  data: {
    books: [],
    filtered: [],
    q: '',
    totalCharsText: '',
  },

  onShow() {
    this.refresh();
  },

  refresh() {
    const progress = store.getProgressAll();
    const books = library.list().map((b) => {
      const p = progress[b.id];
      const percent = p && p.percent ? Math.max(1, Math.round(p.percent)) : 0;
      return Object.assign({}, b, {
        percent: Math.min(100, percent),
        charsText: formatChars(b.chars),
      });
    });
    this.setData(
      {
        books,
        totalCharsText: formatChars(library.totalChars()),
      },
      () => this.applyFilter()
    );
  },

  applyFilter() {
    const q = (this.data.q || '').trim();
    const books = this.data.books;
    const filtered = !q
      ? books
      : books.filter(
          (b) =>
            b.title.indexOf(q) >= 0 ||
            b.volume.indexOf(q) >= 0 ||
            b.tag.indexOf(q) >= 0 ||
            b.translator.indexOf(q) >= 0
        );
    this.setData({ filtered });
  },

  onSearch(e) {
    this.setData({ q: e.detail.value }, () => this.applyFilter());
  },

  clearSearch() {
    this.setData({ q: '' }, () => this.applyFilter());
  },

  openBook(e) {
    const id = e.currentTarget.dataset.id;
    wx.navigateTo({ url: '/pages/reader/reader?id=' + id });
  },
});
