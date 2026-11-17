const library = require('../../services/library');
const store = require('../../utils/store');
const { formatDate } = require('../../utils/format');

Page({
  data: {
    notes: [],
  },

  onShow() {
    this.refresh();
  },

  refresh() {
    const notes = store.allNotes().map((n) => {
      const b = library.getBook(n.bookId) || {};
      const quote = n.quote || '';
      return Object.assign({}, n, {
        key: n.bookId + '#' + n.index,
        bookTitle: b.title || '未知书目',
        date: formatDate(n.updatedAt),
        quoteShort: quote.length > 52 ? quote.slice(0, 52) + '…' : quote,
      });
    });
    this.setData({ notes });
  },

  openNote(e) {
    const ds = e.currentTarget.dataset;
    wx.navigateTo({
      url: '/pages/reader/reader?id=' + ds.id + '&para=' + ds.index,
    });
  },

  removeNote(e) {
    const ds = e.currentTarget.dataset;
    wx.showModal({
      title: '删除这条笔记？',
      content: '删除后不可恢复。',
      confirmColor: '#a8552f',
      success: (res) => {
        if (!res.confirm) return;
        store.removeNote(ds.id, Number(ds.index));
        this.refresh();
      },
    });
  },
});
