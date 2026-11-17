// 正文分段：与 Flutter 版 reading_page.dart 的 _parseParagraphs 保持同一口径。
//
// 两端笔记是按「段落 index」关联的，只要分段结果差一行，历史笔记就会错位。
// 这里保留 App 的编辑记号规则：
//   。。。  该段隐藏操作栏（阅读时仍显示正文）
//   ///     与下一段不分段（更紧的行距）
//   @@…@@  备注块，整块合并为一段
//   BBB/bbb 该段加粗
//
// 说明：App 里标记组合的剥离顺序较绕，这里用「循环剥离两端记号」实现，
// 对无记号的大正藏原文结果完全一致；带编辑记号的管理员排版也已覆盖常见组合。

const HIDE = '。。。';
const TIGHT_MARKS = ['///', '／／／'];
const BOLD_MARKS = ['BBB', 'bbb'];

function stripMarkers(text, state) {
  let changed = true;
  let guard = 0;

  while (changed && guard++ < 6) {
    changed = false;

    // 尾部：。。。+///、///+。。。 组合
    for (let i = 0; i < TIGHT_MARKS.length; i++) {
      const u = TIGHT_MARKS[i];
      if (text.endsWith(HIDE + u)) {
        text = text.slice(0, -(HIDE.length + u.length));
        state.hide = true;
        state.tight = true;
        changed = true;
      } else if (text.endsWith(u + HIDE)) {
        text = text.slice(0, -(u.length + HIDE.length));
        state.hide = true;
        state.tight = true;
        changed = true;
      }
    }
    if (text.endsWith(HIDE)) {
      text = text.slice(0, -HIDE.length);
      state.hide = true;
      changed = true;
      for (let i = 0; i < TIGHT_MARKS.length; i++) {
        const u = TIGHT_MARKS[i];
        if (text.endsWith(u)) {
          text = text.slice(0, -u.length);
          state.tight = true;
          break;
        }
      }
    }
    for (let i = 0; i < BOLD_MARKS.length; i++) {
      const b = BOLD_MARKS[i];
      if (text.endsWith(b)) {
        text = text.slice(0, -b.length).replace(/\s+$/, '');
        state.bold = true;
        changed = true;
      }
    }

    // 头部：与尾部对称
    for (let i = 0; i < TIGHT_MARKS.length; i++) {
      const u = TIGHT_MARKS[i];
      if (text.startsWith(HIDE + u)) {
        text = text.slice(HIDE.length + u.length);
        state.hide = true;
        state.tight = true;
        changed = true;
      } else if (text.startsWith(u + HIDE)) {
        text = text.slice(u.length + HIDE.length);
        state.hide = true;
        state.tight = true;
        changed = true;
      }
    }
    if (text.startsWith(HIDE)) {
      text = text.slice(HIDE.length);
      state.hide = true;
      changed = true;
      for (let i = 0; i < TIGHT_MARKS.length; i++) {
        const u = TIGHT_MARKS[i];
        if (text.startsWith(u)) {
          text = text.slice(u.length);
          state.tight = true;
          break;
        }
      }
    }
    for (let i = 0; i < BOLD_MARKS.length; i++) {
      const b = BOLD_MARKS[i];
      if (text.startsWith(b)) {
        text = text.slice(b.length).replace(/^\s+/, '');
        state.bold = true;
        changed = true;
      }
    }
  }

  return text;
}

/**
 * 把整本书的纯文本切成段落。
 * @param {string} content
 * @returns {{t: string, cls: string, note: boolean}[]}
 */
function parseParagraphs(content) {
  const lines = String(content || '')
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '\n')
    .split('\n');

  const out = [];
  let noteBuf = [];
  let inNote = false;

  function flushNote() {
    if (!noteBuf.length) return;
    out.push({ t: noteBuf.join('\n'), cls: 'note-block', note: true });
    noteBuf = [];
  }

  for (let li = 0; li < lines.length; li++) {
    let text = lines[li].trim();

    // 空行：备注块内保留一个空行，其余作为分段边界忽略。
    if (!text) {
      if (inNote && noteBuf.length) {
        noteBuf.push('');
      } else if (!inNote) {
        flushNote();
      }
      continue;
    }

    // 备注块内部
    if (inNote) {
      if (text.endsWith('@@')) {
        const rest = text.slice(0, -2);
        if (rest) noteBuf.push(rest);
        flushNote();
        inNote = false;
      } else if (text.startsWith('@@')) {
        noteBuf.push(text.slice(2));
      } else {
        noteBuf.push(text);
      }
      continue;
    }

    // 单行备注：@@内容@@
    if (text.startsWith('@@') && text.endsWith('@@') && text.length >= 4) {
      noteBuf.push(text.slice(2, -2));
      flushNote();
      continue;
    }

    // 备注块开始
    if (text.startsWith('@@')) {
      const rest = text.slice(2);
      if (rest) noteBuf.push(rest);
      inNote = true;
      continue;
    }

    flushNote();

    const state = { hide: false, tight: false, bold: false };
    text = stripMarkers(text, state).trim();
    if (!text) continue;

    const cls = [];
    if (state.tight) cls.push('tight');
    if (state.bold) cls.push('bold');
    if (state.hide) cls.push('quiet');

    out.push({ t: text, cls: cls.join(' '), note: false });
  }

  inNote = false;
  flushNote();
  return out;
}

module.exports = { parseParagraphs };
