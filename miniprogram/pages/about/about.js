const config = require('../../utils/config');
const library = require('../../services/library');
const store = require('../../utils/store');
const { formatChars } = require('../../utils/format');

Page({
  data: {
    appName: config.appName,
    version: config.version,
    bookCount: 0,
    charsText: '',
    noteCount: 0,
    recordNo: config.recordNo,
    contact: config.contact,
  },

  onShow() {
    this.setData({
      bookCount: library.list().length,
      charsText: formatChars(library.totalChars()),
      noteCount: store.noteCount(),
    });
  },

  openNotes() {
    wx.navigateTo({ url: '/pages/notes/notes' });
  },

  openDoc(e) {
    const type = e.currentTarget.dataset.type;
    wx.navigateTo({ url: '/pages/doc/doc?type=' + type });
  },

  clearData() {
    wx.showModal({
      title: '清除本机数据',
      content: '将删除阅读进度、笔记和阅读设置，且不可恢复。',
      confirmColor: '#a8552f',
      success: (res) => {
        if (!res.confirm) return;
        store.clearAll();
        this.onShow();
        wx.showToast({ title: '已清除', icon: 'success' });
      },
    });
  },

  copyContact() {
    wx.setClipboardData({ data: config.contact });
  },
});
