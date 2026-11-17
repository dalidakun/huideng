// 本机存储：阅读进度、段落笔记、阅读设置。
// 首版全部本地，不上传服务器；后续接云同步时只需替换这一层。

const PROGRESS_KEY = 'hd_progress_v1';
const NOTES_KEY = 'hd_notes_v1';
const SETTINGS_KEY = 'hd_settings_v1';

function readObject(key) {
  try {
    const v = wx.getStorageSync(key);
    return v && typeof v === 'object' ? v : {};
  } catch (e) {
    return {};
  }
}

function writeObject(key, value) {
  try {
    wx.setStorageSync(key, value);
  } catch (e) {
    // 存储失败不影响阅读本身。
  }
}

// ── 阅读进度 ──────────────────────────────────────────────
function getProgress(bookId) {
  return readObject(PROGRESS_KEY)[bookId] || null;
}

function getProgressAll() {
  return readObject(PROGRESS_KEY);
}

function setProgress(bookId, data) {
  const all = readObject(PROGRESS_KEY);
  all[bookId] = data;
  writeObject(PROGRESS_KEY, all);
}

// ── 段落笔记 ──────────────────────────────────────────────
function noteKey(bookId, index) {
  return bookId + '#' + index;
}

function getNote(bookId, index) {
  return readObject(NOTES_KEY)[noteKey(bookId, index)] || null;
}

function saveNote(bookId, index, text, quote) {
  const all = readObject(NOTES_KEY);
  const key = noteKey(bookId, index);
  const old = all[key];
  all[key] = {
    bookId,
    index,
    text,
    quote: quote || '',
    createdAt: old ? old.createdAt : Date.now(),
    updatedAt: Date.now(),
  };
  writeObject(NOTES_KEY, all);
  return all[key];
}

function removeNote(bookId, index) {
  const all = readObject(NOTES_KEY);
  delete all[noteKey(bookId, index)];
  writeObject(NOTES_KEY, all);
}

function allNotes() {
  const all = readObject(NOTES_KEY);
  return Object.keys(all)
    .map((k) => all[k])
    .filter((n) => n && n.text)
    .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
}

function noteCount() {
  return allNotes().length;
}

// ── 设置 ──────────────────────────────────────────────────
function getSettings() {
  const s = readObject(SETTINGS_KEY);
  return {
    fsIndex: typeof s.fsIndex === 'number' ? s.fsIndex : 2,
    theme: s.theme || 'paper',
  };
}

function setSettings(next) {
  writeObject(SETTINGS_KEY, Object.assign(getSettings(), next || {}));
}

// ── 清除 ──────────────────────────────────────────────────
function clearAll() {
  [PROGRESS_KEY, NOTES_KEY, SETTINGS_KEY].forEach((k) => {
    try {
      wx.removeStorageSync(k);
    } catch (e) {}
  });
}

module.exports = {
  getProgress,
  getProgressAll,
  setProgress,
  getNote,
  saveNote,
  removeNote,
  allNotes,
  noteCount,
  getSettings,
  setSettings,
  clearAll,
};
