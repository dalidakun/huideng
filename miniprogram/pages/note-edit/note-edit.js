const library = require('../../services/library');
const store = require('../../utils/store');
const { parseParagraphs } = require('../../utils/paragraphs');
const { formatDate } = require('../../utils/format');

Page({
  data: {
    id: '',
    index: 0,
    title: '',
    quote: '',
    value: '',
    existing: false,
    updatedText: '',
  },

  onLoad(options) {
    const id = options.id;
    const index = Number(options.i);
    const book = library.getBook(id);
    const paras = parseParagraphs(library.getText(id));
    const quote = paras[index] ? paras[index].t : '';
    const note = store.getNote(id, index);

    this.setData({
      id,
      index,
      title: book ? book.title : '笔记',
      quote,
      value: note ? note.text : '',
      existing: !!note,
      updatedText: note ? '上次修改 ' + formatDate(note.updatedAt) : '',
    });
    wx.setNavigationBarTitle({ title: note ? '编辑笔记' : '写笔记' });
  },

  onInput(e) {
    this.setData({ value: e.detail.value });
  },

  save() {
    const text = (this.data.value || '').trim();
    if (!text) {
      this.remove(true);
      return;
    }
    store.saveNote(this.data.id, this.data.index, text, this.data.quote);
    wx.showToast({ title: '已保存', icon: 'success' });
    setTimeout(() => wx.navigateBack(), 350);
  },

  onRemove() {
    this.remove(false);
  },

  remove(silent) {
    const doRemove = () => {
      store.removeNote(this.data.id, this.data.index);
      wx.showToast({ title: '已删除', icon: 'none' });
      setTimeout(() => wx.navigateBack(), 300);
    };
    if (silent) {
      doRemove();
      return;
    }
    wx.showModal({
      title: '删除这条笔记？',
      content: '删除后不可恢复。',
      confirmColor: '#a8552f',
      success: (res) => {
        if (res.confirm) doRemove();
      },
    });
  },
});
