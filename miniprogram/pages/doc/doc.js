const DOCS = require('../../data/docs');

Page({
  data: {
    doc: null,
  },

  onLoad(options) {
    const doc = DOCS[options.type] || DOCS.privacy;
    this.setData({ doc });
    wx.setNavigationBarTitle({ title: doc.title });
  },
});
