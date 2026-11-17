// 书库访问层：首版读本地内置文本；后续接云存储时只改这里。
const BOOKS = require('../data/books');
const TEXT_LOADERS = require('../data/texts/index');

const BY_ID = {};
BOOKS.forEach((b) => {
  BY_ID[b.id] = b;
});

function list() {
  return BOOKS.slice();
}

function getBook(id) {
  return BY_ID[id] || null;
}

function getText(id) {
  const load = TEXT_LOADERS[id];
  if (!load) return '';
  return load();
}

function totalChars() {
  return BOOKS.reduce((n, b) => n + (b.chars || 0), 0);
}

module.exports = { list, getBook, getText, totalChars };
