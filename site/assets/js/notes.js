/* 交易笔记（/notes/）
 *
 * 数据：cloudfunctions/api/trade.js 的 tradeNote* 动作；登录态复用行情页的
 * 会话 token（localStorage: huideng.trade.token）。
 * 正文是 contenteditable 富文本，图片直接插在光标处（<img data-file-id>），
 * 服务端清洗后存 HTML；图片文件单独放云存储，数据库只存 fileID。
 */
(function (global) {
  'use strict';

  var CFG = global.NOTES_CFG || {};
  var LS_TOKEN = 'huideng.trade.token';
  var LS_USER = 'huideng.trade.user';
  var LS_SIDEW = 'huideng.notes.sidew';
  var MAX_EDGE = 1600;
  var TARGET_BYTES = 320 * 1024;
  var MAX_SOURCE_BYTES = 25 * 1024 * 1024;
  var PAGE_SIZE = 50;
  var AUTOSAVE_MS = 60000;

  var MSG = {
    unauthorized: '登录已过期，请重新登录',
    storage_quota: '云空间已满（300MB），删掉一些图片再试',
    image_too_large: '图片超过 1.5MB，换一张或再压缩一下',
    bad_image: '只支持 JPG / PNG / WebP 图片',
    empty_image: '图片是空的，换一张试试',
    empty_note: '写点内容或加张图再保存',
    rate_limited: '操作太频繁，稍等一下再试',
    not_found: '这条笔记不存在或已删除',
    network: '网络不稳定，请重试',
    timeout: '请求超时，请重试',
    too_large: '文件太大'
  };

  var S = {
    token: '',
    user: '',
    notes: [],
    nextOffset: null,
    hasMore: false,
    loadingMore: false,
    cur: null,
    dirty: false,
    busy: false,
    uploading: 0,
    savedRange: null,
    autosaveTimer: 0,
    shareUrl: '',
    trashOpen: false,
    trashNotes: []
  };

  var el = {};
  var toastTimer = 0;
  var TEXT_COLORS = [
    '#241f16', '#7e1319', '#b45309', '#a16207',
    '#305c38', '#0e7490', '#4338ca', '#9d174d',
    '#9ca3af', '#6b7280', '#374151', '#000000',
    '#fee2e2', '#fef9c3', '#dcfce7', '#dbeafe'
  ];
  var EMOJIS = [
    '😀', '😅', '😂', '🙂', '😉', '😍', '🤔', '😐',
    '😮', '😢', '😭', '😡', '👍', '👎', '👏', '🙏',
    '💪', '🔥', '⚡', '💡', '📈', '📉', '💰', '🎯',
    '✅', '❌', '⚠️', '⭐', '❤️', '🧘', '📝', '🕯️'
  ];
  var DOTS_SVG =
    '<svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor">' +
    '<circle cx="5" cy="12" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="19" cy="12" r="1.7"/></svg>';

  function $(id) {
    return document.getElementById(id);
  }

  function readLS(key) {
    try {
      return global.localStorage.getItem(key) || '';
    } catch (e) {
      return '';
    }
  }

  function writeLS(key, val) {
    try {
      if (val) global.localStorage.setItem(key, val);
      else global.localStorage.removeItem(key);
    } catch (e) {}
  }

  function err(code) {
    var e = new Error(code);
    e.code = code;
    return e;
  }

  function msgOf(code) {
    var c = String(code || '');
    if (MSG[c]) return MSG[c];
    if (c.indexOf('HTTP') === 0) return '服务暂时不可用（' + c + '）';
    return c || '操作失败';
  }

  function toast(text) {
    if (!el.toast) return;
    el.toast.textContent = text;
    el.toast.hidden = false;
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () {
      el.toast.hidden = true;
      toastTimer = 0;
    }, 2600);
  }

  // ---------------------------------------------------------------- 接口

  function api(action, params, timeout) {
    var body = { action: action, token: S.token };
    if (params) {
      Object.keys(params).forEach(function (k) {
        body[k] = params[k];
      });
    }
    var ctl = null;
    try {
      ctl = new AbortController();
    } catch (e) {}
    var timer = 0;
    if (ctl) {
      timer = setTimeout(function () {
        try {
          ctl.abort();
        } catch (e) {}
      }, timeout || 25000);
    }
    var opts = {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer ' + CFG.key,
        'x-device-id': 'web-notes'
      },
      body: JSON.stringify(body)
    };
    if (ctl) opts.signal = ctl.signal;

    return fetch(CFG.api, opts)
      .then(function (res) {
        if (timer) {
          clearTimeout(timer);
          timer = 0;
        }
        if (!res.ok) throw err('HTTP ' + res.status);
        return res.json();
      })
      .then(function (j) {
        if (!j || !j.ok) throw err((j && j.error) || 'error');
        return j;
      })
      .catch(function (e) {
        if (timer) clearTimeout(timer);
        if (e && e.code) throw e;
        throw err('network');
      });
  }

  // ---------------------------------------------------------------- 时间

  function pad2(n) {
    return n < 10 ? '0' + n : '' + n;
  }

  function fmtListTime(ts) {
    var n = Number(ts) || 0;
    if (!n) return '';
    var d = new Date(n);
    return (
      d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) +
      ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes())
    );
  }

  function fmtMetaTime(ts) {
    var n = Number(ts) || 0;
    if (!n) return '';
    var d = new Date(n);
    return pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
  }

  function plainText() {
    return el.noteBody ? String(el.noteBody.innerText || '') : '';
  }

  // ---------------------------------------------------------------- 列表

  function renderList() {
    if (!el.notesList) return;
    el.notesList.innerHTML = '';
    if (!S.notes.length) {
      var empty = document.createElement('p');
      empty.className = 'notes-list__empty';
      empty.textContent = '还没有笔记，点右下角 + 新建。';
      el.notesList.appendChild(empty);
      return;
    }
    var frag = document.createDocumentFragment();
    S.notes.forEach(function (n) {
      var row = document.createElement('div');
      row.className = 'notes-item';
      row.setAttribute('role', 'listitem');
      row.setAttribute('data-id', n.noteId);
      if (S.cur && S.cur.noteId === n.noteId) row.classList.add('is-on');

      var main = document.createElement('button');
      main.type = 'button';
      main.className = 'notes-item__main';
      main.setAttribute('data-open', '1');

      var title = document.createElement('span');
      title.className = 'notes-item__title' + (n.title ? '' : ' is-untitled');
      title.textContent = n.title || '无标题';
      main.appendChild(title);

      var time = document.createElement('span');
      time.className = 'notes-item__time';
      time.textContent = fmtListTime(n.createdAt || n.updatedAt);
      main.appendChild(time);
      row.appendChild(main);

      var dots = document.createElement('button');
      dots.type = 'button';
      dots.className = 'notes-item__dots';
      dots.setAttribute('data-more', n.noteId);
      dots.setAttribute('aria-label', '更多操作');
      dots.innerHTML = DOTS_SVG;
      row.appendChild(dots);

      frag.appendChild(row);
    });
    el.notesList.appendChild(frag);

    if (S.hasMore) {
      var more = document.createElement('button');
      more.type = 'button';
      more.className = 'notes-more';
      more.disabled = S.loadingMore;
      more.textContent = S.loadingMore ? '加载中…' : '加载更多';
      more.addEventListener('click', loadMore);
      el.notesList.appendChild(more);
    }
  }

  function renderQuota(usage) {
    if (!usage || !el.quotaText) return;
    var bytes = Number(usage.bytes) || 0;
    var count = Number(usage.count) || 0;
    var mb = bytes / 1048576;
    var sizeText;
    if (mb >= 1) sizeText = (mb >= 10 ? Math.round(mb) : mb.toFixed(1)) + 'MB';
    else sizeText = Math.max(0, Math.round(bytes / 1024)) + 'KB';
    el.quotaText.textContent = count + ' 篇 · 图片 ' + sizeText + '/300MB';
  }

  // ---------------------------------------------------------------- 编辑器

  function updateSaveState() {
    if (!el.saveState || !el.saveStateText) return;
    var text = '';
    if (S.busy) text = '保存中…';
    else if (S.uploading > 0) text = '图片处理中…';
    else if (S.dirty) text = '未保存';
    else if (S.cur && S.cur.noteId) text = '已保存';
    el.saveStateText.textContent = text;
    el.saveState.classList.toggle('is-saved', text === '已保存');
    el.saveState.classList.toggle('is-dirty', !!(S.dirty && !S.busy && S.uploading === 0));
  }

  function fitTitle() {
    if (!el.noteTitle) return;
    // field-sizing: content 不支持时，用 size 近似按字数撑宽；长标题由 CSS 省略。
    el.noteTitle.size = Math.min(40, Math.max(6, (el.noteTitle.value || '').length || 6));
  }

  function updateMeta() {
    if (!el.noteDate) return;
    var parts = [];
    var txt = plainText();
    if (txt) parts.push(txt.length + ' 字');
    if (S.cur && S.cur.createdAt) parts.push(fmtMetaTime(S.cur.createdAt));
    el.noteDate.textContent = parts.join(' · ');
  }

  function renderEditor() {
    var cur = S.cur;
    if (!cur) return;
    el.noteTitle.value = cur.title || '';
    fitTitle();
    if (cur.contentFormat === 'html') {
      el.noteBody.innerHTML = cur.content || '';
      el.noteBody.classList.remove('is-plain');
    } else {
      el.noteBody.textContent = cur.content || '';
      el.noteBody.classList.add('is-plain');
    }
    updateMeta();    updateSaveState();
    closePops();
    S.savedRange = null;
  }

  function setDirty() {
    S.dirty = true;
    updateSaveState();
    updateMeta();
    scheduleAutosave();
  }

  function revokeUrls(cur) {
    if (!cur || !cur.images) return;
    cur.images.forEach(function (im) {
      if (im && im.url && im.url.indexOf('blob:') === 0) {
        try {
          URL.revokeObjectURL(im.url);
        } catch (e) {}
      }
    });
  }

  // ---------------------------------------------------------------- 自动保存

  function clearAutosave() {
    if (S.autosaveTimer) {
      clearTimeout(S.autosaveTimer);
      S.autosaveTimer = 0;
    }
  }

  function scheduleAutosave() {
    if (!S.token || !S.cur || S.autosaveTimer) return;
    // 一分钟一次：不在每次输入时重置，否则一直打字就永远不保存。
    S.autosaveTimer = setTimeout(function () {
      S.autosaveTimer = 0;
      save(true);
    }, AUTOSAVE_MS);
  }

  // ---------------------------------------------------------------- 数据

  function gate() {
    if (el.loginGate) el.loginGate.hidden = false;
  }

  function mergeNotes(list) {
    var seen = {};
    var out = [];
    (S.notes || []).concat(list || []).forEach(function (n) {
      if (!n || !n.noteId || seen[n.noteId]) return;
      seen[n.noteId] = 1;
      out.push(n);
    });
    return out;
  }

  function loadList(append) {
    append = !!append;
    if (append && (!S.hasMore || S.loadingMore)) return Promise.resolve();
    var params = { pageSize: PAGE_SIZE };
    if (append) {
      params.offset = S.nextOffset || 0;
      S.loadingMore = true;
      renderList();
    }
    return api('tradeNoteList', params)
      .then(function (j) {
        var list = j.notes || [];
        S.notes = append ? mergeNotes(list) : list;
        S.nextOffset =
          j.nextOffset === null || j.nextOffset === undefined
            ? null
            : Number(j.nextOffset);
        S.hasMore = S.nextOffset !== null && !isNaN(S.nextOffset);
        S.loadingMore = false;
        renderList();
        renderQuota(j.usage);
        if (append) return;
        if (S.cur) return;
        if (S.notes.length) return openNote(S.notes[0].noteId, true);
        newNote(true);
      })
      .catch(function (e) {
        S.loadingMore = false;
        if (e.code === 'unauthorized') {
          writeLS(LS_TOKEN, '');
          gate();
          return;
        }
        if (append) {
          renderList();
          toast(msgOf(e.code));
          return;
        }
        if (el.notesList) {
          el.notesList.innerHTML = '';
          var p = document.createElement('p');
          p.className = 'notes-list__empty';
          p.textContent = '加载失败：' + msgOf(e.code);
          el.notesList.appendChild(p);
        }
        toast(msgOf(e.code));
      });
  }

  function loadMore() {
    loadList(true);
  }

  var openSeq = 0;

  function openNote(id, silent) {
    if (!id) return Promise.resolve();
    if (!silent && S.dirty && !global.confirm('当前笔记还没保存，确定要换一条吗？')) {
      return Promise.resolve();
    }
    clearAutosave();
    var seq = ++openSeq;
    return api('tradeNoteGet', { noteId: id })
      .then(function (j) {
        if (seq !== openSeq) return;
        revokeUrls(S.cur);
        S.cur = j.note;
        S.cur.images = j.note.images || [];
        S.dirty = false;
        renderEditor();
        renderList();
        if (!silent) document.body.classList.add('is-editing');
      })
      .catch(function (e) {
        if (e.code === 'unauthorized') {
          writeLS(LS_TOKEN, '');
          gate();
          return;
        }
        toast(msgOf(e.code));
        if (e.code === 'not_found') {
          S.cur = null;
          loadList(false);
        }
      });
  }

  function newNote(silent) {
    if (!silent && S.dirty && !global.confirm('当前笔记还没保存，确定新建一条吗？')) {
      return;
    }
    clearAutosave();
    openSeq += 1;
    revokeUrls(S.cur);
    S.cur = {
      noteId: '',
      title: '',
      content: '',
      contentFormat: 'html',
      lineHeight: 1.75,
      images: [],
      createdAt: 0,
      updatedAt: 0
    };
    S.dirty = false;
    renderEditor();
    renderList();
    if (!silent) document.body.classList.add('is-editing');
    if (el.noteTitle) el.noteTitle.focus();
  }

  // ---------------------------------------------------------------- 图片

  function loadBitmap(file) {
    return new Promise(function (resolve, reject) {
      function fallback() {
        var url = URL.createObjectURL(file);
        var img = new Image();
        img.onload = function () {
          URL.revokeObjectURL(url);
          resolve(img);
        };
        img.onerror = function () {
          URL.revokeObjectURL(url);
          reject(new Error('decode'));
        };
        img.src = url;
      }
      if (global.createImageBitmap) {
        global.createImageBitmap(file).then(function (bmp) {
          resolve(bmp);
        }, fallback);
      } else {
        fallback();
      }
    });
  }

  function canvasToBlob(canvas, quality) {
    return new Promise(function (resolve, reject) {
      if (!canvas.toBlob) {
        reject(new Error('encode'));
        return;
      }
      canvas.toBlob(
        function (blob) {
          if (blob) resolve(blob);
          else reject(new Error('encode'));
        },
        'image/jpeg',
        quality
      );
    });
  }

  function downscale(canvas, ratio) {
    var w = Math.max(1, Math.round(canvas.width * ratio));
    var h = Math.max(1, Math.round(canvas.height * ratio));
    var c = document.createElement('canvas');
    c.width = w;
    c.height = h;
    var ctx = c.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, w, h);
    ctx.drawImage(canvas, 0, 0, w, h);
    return c;
  }

  function encode(canvas, quality) {
    return canvasToBlob(canvas, quality).then(function (blob) {
      if (blob.size <= TARGET_BYTES) return blob;
      if (quality > 0.5) return encode(canvas, Math.max(0.5, quality - 0.08));
      if (Math.max(canvas.width, canvas.height) > 900) {
        return encode(downscale(canvas, 0.82), 0.7);
      }
      return blob;
    });
  }

  function compressImage(file) {
    return loadBitmap(file).then(function (src) {
      var sw = src.width || src.naturalWidth;
      var sh = src.height || src.naturalHeight;
      if (!sw || !sh) throw new Error('decode');
      var scale = Math.min(1, MAX_EDGE / Math.max(sw, sh));
      var w = Math.max(1, Math.round(sw * scale));
      var h = Math.max(1, Math.round(sh * scale));
      var canvas = document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      var ctx = canvas.getContext('2d');
      ctx.fillStyle = '#fff';
      ctx.fillRect(0, 0, w, h);
      ctx.drawImage(src, 0, 0, w, h);
      if (src.close) src.close();
      return encode(canvas, 0.72);
    });
  }

  function blobToBase64(blob) {
    return new Promise(function (resolve, reject) {
      var reader = new FileReader();
      reader.onload = function () {
        var s = String(reader.result || '');
        var i = s.indexOf(',');
        if (i < 0) {
          reject(new Error('encode'));
          return;
        }
        resolve(s.slice(i + 1));
      };
      reader.onerror = function () {
        reject(new Error('encode'));
      };
      reader.readAsDataURL(blob);
    });
  }

  function saveRange() {
    var sel = global.getSelection && global.getSelection();
    if (!sel || !sel.rangeCount) return;
    var range = sel.getRangeAt(0);
    if (!el.noteBody.contains(range.startContainer)) return;
    S.savedRange = range.cloneRange();
  }

  function placeCaretAtEnd() {
    var range = document.createRange();
    range.selectNodeContents(el.noteBody);
    range.collapse(false);
    var sel = global.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    return range;
  }

  function insertImageAt(fileId, blobUrl, savedRange) {
    var img = document.createElement('img');
    img.src = blobUrl;
    img.setAttribute('data-file-id', fileId);
    img.alt = '';

    el.noteBody.focus();
    var range = null;
    if (savedRange && el.noteBody.contains(savedRange.startContainer)) {
      var sel = global.getSelection();
      sel.removeAllRanges();
      sel.addRange(savedRange);
      range = sel.getRangeAt(0);
    } else {
      range = placeCaretAtEnd();
    }
    range.deleteContents();
    range.insertNode(img);

    var after = document.createRange();
    after.setStartAfter(img);
    after.collapse(true);
    var s2 = global.getSelection();
    s2.removeAllRanges();
    s2.addRange(after);
    S.savedRange = after.cloneRange();
    S.dirty = true;
    updateSaveState();
    updateMeta();
    scheduleAutosave();
    img.scrollIntoView({ block: 'nearest' });
  }

  function insertImageFile(file) {
    if (!S.cur) newNote(true);
    if (file.size > MAX_SOURCE_BYTES) {
      toast('图片太大（超过 25MB），先裁剪或换一张');
      return Promise.resolve();
    }
    var target = S.cur;
    var range = S.savedRange ? S.savedRange.cloneRange() : null;
    S.uploading += 1;
    updateSaveState();
    return compressImage(file)
      .then(function (blob) {
        return blobToBase64(blob).then(function (b64) {
          return api('tradeNoteUpload', { data: b64 }, 60000).then(function (j) {
            if (S.cur !== target) return;
            var url = URL.createObjectURL(blob);
            S.cur.images.push({
              fileId: j.fileId,
              size: j.size || blob.size,
              url: url
            });
            insertImageAt(j.fileId, url, range);
          });
        });
      })
      .catch(function (e) {
        if (e && e.code) toast(msgOf(e.code));
        else if (e && e.message === 'decode') toast('这张图浏览器打不开，换 JPG / PNG 试试');
        else toast('图片处理失败，换一张试试');
      })
      .then(function () {
        S.uploading = Math.max(0, S.uploading - 1);
        updateSaveState();
      });
  }

  function pickImages(files) {
    if (!files || !files.length) return;
    var list = Array.prototype.slice.call(files).filter(function (f) {
      return /^image\//.test(f.type || '');
    });
    if (!list.length) {
      toast('请选择图片文件');
      return;
    }
    var chain = Promise.resolve();
    list.forEach(function (file) {
      chain = chain.then(function () {
        return insertImageFile(file);
      });
    });
    chain.then(function () {
      if (el.fileInput) el.fileInput.value = '';
    });
  }

  // ---------------------------------------------------------------- 保存 / 删除

  function save(auto) {
    if (!S.cur || S.busy) return;
    if (auto && S.uploading > 0) {
      scheduleAutosave();
      return;
    }
    if (auto && !S.dirty) return;
    var title = (el.noteTitle.value || '').trim();
    var html = el.noteBody.innerHTML || '';
    var text = plainText().trim();
    var images = S.cur.images || [];
    if (!title && !text && images.length === 0) {
      if (!auto) toast('写点内容或加张图再保存');
      return;
    }
    clearAutosave();
    S.busy = true;
    el.btnSave.disabled = true;
    updateSaveState();

    api('tradeNoteSave', {
      noteId: S.cur.noteId || '',
      title: title,
      content: html,
      lineHeight: 1.75,
      images: images.map(function (im) {
        return { fileId: im.fileId, size: im.size || 0 };
      })
    })
      .then(function (j) {
        var summary = {
          noteId: j.noteId || S.cur.noteId,
          title: j.title != null ? j.title : title,
          preview:
            j.preview != null
              ? j.preview
              : text.replace(/\s+/g, ' ').slice(0, 120),
          imageCount:
            typeof j.imageCount === 'number' ? j.imageCount : images.length,
          createdAt: j.createdAt || S.cur.createdAt || Date.now(),
          updatedAt: j.updatedAt || Date.now()
        };
        var changed =
          (el.noteTitle.value || '').trim() !== title ||
          (el.noteBody.innerHTML || '') !== html;
        S.cur.noteId = summary.noteId;
        S.cur.updatedAt = summary.updatedAt;
        S.cur.createdAt = summary.createdAt;
        S.cur.contentFormat = 'html';
        if (!changed) {
          S.cur.title = title;
          S.cur.content = html;
          S.dirty = false;
          el.noteTitle.value = title;
        } else {
          // 保存请求飞在路上时用户又改了：保留新内容，等下一分钟再存。
          S.dirty = true;
        }
        el.noteBody.classList.remove('is-plain');
        var idx = -1;
        for (var i = 0; i < S.notes.length; i += 1) {
          if (S.notes[i].noteId === summary.noteId) {
            idx = i;
            break;
          }
        }
        if (idx >= 0) S.notes[idx] = summary;
        else S.notes.unshift(summary);
        if (S.hasMore) S.nextOffset = S.notes.length;
        S.busy = false;
        el.btnSave.disabled = false;
        updateMeta();
        updateSaveState();
        renderList();
        renderQuota(j.usage);
        if (changed) scheduleAutosave();
        if (!auto) toast('已保存');
        fitTitle();
      })
      .catch(function (e) {
        S.busy = false;
        el.btnSave.disabled = false;
        updateSaveState();
        if (e.code === 'unauthorized') {
          writeLS(LS_TOKEN, '');
          gate();
          return;
        }
        if (auto) scheduleAutosave();
        else toast(msgOf(e.code));
      });
  }

  function trashNote(id) {
    if (!id || S.busy) return;
    S.busy = true;
    api('tradeNoteDelete', { noteId: id })
      .then(function (j) {
        S.busy = false;
        S.notes = S.notes.filter(function (n) {
          return n.noteId !== id;
        });
        if (S.hasMore && S.nextOffset) {
          S.nextOffset = Math.max(0, S.nextOffset - 1);
        }
        if (S.cur && S.cur.noteId === id) {
          revokeUrls(S.cur);
          S.cur = null;
          S.dirty = false;
          renderList();
          if (S.notes.length) openNote(S.notes[0].noteId, true);
          else newNote(true);
        } else {
          renderList();
        }
        renderQuota(j.usage);
        if (S.trashOpen) loadTrash();
        toast('已移入回收站');
      })
      .catch(function (e) {
        S.busy = false;
        toast(msgOf(e.code));
      });
  }

  // ---------------------------------------------------------------- 回收站浮层

  function positionTrashPanel() {
    if (!el.trashPanel || !el.btnTrash || !el.sidePane) return;
    var r = el.btnTrash.getBoundingClientRect();
    var s = el.sidePane.getBoundingClientRect();
    el.trashPanel.style.left = Math.max(6, s.left) + 'px';
    el.trashPanel.style.width = Math.max(170, s.width || 240) + 'px';
    el.trashPanel.style.bottom = Math.max(8, global.innerHeight - r.top + 6) + 'px';
  }

  function renderTrash() {
    if (!el.trashList) return;
    el.trashList.innerHTML = '';
    if (!S.trashNotes.length) {
      var p = document.createElement('p');
      p.className = 'notes-trash-empty';
      p.textContent = '回收站是空的。';
      el.trashList.appendChild(p);
      return;
    }
    S.trashNotes.forEach(function (n) {
      var row = document.createElement('div');
      row.className = 'trash-item';
      var title = document.createElement('span');
      title.className = 'trash-item__title';
      title.textContent = n.title || '无标题';
      title.title = n.title || '无标题';
      row.appendChild(title);
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'trash-item__restore';
      btn.textContent = '还原';
      btn.addEventListener('click', function () {
        restoreTrashNote(n.noteId);
      });
      row.appendChild(btn);
      el.trashList.appendChild(row);
    });
  }

  function loadTrash() {
    return api('tradeNoteTrashList', { pageSize: 100 })
      .then(function (j) {
        S.trashNotes = j.notes || [];
        renderTrash();
      })
      .catch(function (e) {
        if (e.code === 'unauthorized') {
          writeLS(LS_TOKEN, '');
          gate();
          return;
        }
        S.trashNotes = [];
        renderTrash();
      });
  }

  function openTrashPanel() {
    S.trashOpen = true;
    el.btnTrash.classList.add('is-on');
    el.trashPanel.hidden = false;
    positionTrashPanel();
    loadTrash();
  }

  function closeTrashPanel() {
    S.trashOpen = false;
    el.btnTrash.classList.remove('is-on');
    el.trashPanel.hidden = true;
  }

  function toggleTrashPanel() {
    if (S.trashOpen) closeTrashPanel();
    else openTrashPanel();
  }

  function restoreTrashNote(id) {
    api('tradeNoteRestore', { noteId: id })
      .then(function () {
        S.trashNotes = S.trashNotes.filter(function (n) {
          return n.noteId !== id;
        });
        renderTrash();
        toast('已还原');
        loadList(false);
      })
      .catch(function (e) {
        toast(msgOf(e.code));
      });
  }

  function clearTrash() {
    if (!S.trashNotes.length) return;
    if (!global.confirm('清空回收站？里面的图片也会一起删除，不能恢复。')) return;
    var list = S.trashNotes.slice();
    var chain = Promise.resolve();
    list.forEach(function (n) {
      chain = chain.then(function () {
        return api('tradeNotePurge', { noteId: n.noteId }).catch(function () {});
      });
    });
    chain.then(function () {
      S.trashNotes = [];
      renderTrash();
      toast('回收站已清空');
      loadList(false);
    });
  }

  // ---------------------------------------------------------------- 三点菜单

  var itemMenu = null;

  function closeItemMenu() {
    if (itemMenu && itemMenu.parentNode) itemMenu.parentNode.removeChild(itemMenu);
    itemMenu = null;
  }

  function openItemMenu(noteId, anchor) {
    closeItemMenu();
    var menu = document.createElement('div');
    menu.className = 'notes-item-menu';
    var actions = [
      { label: '分享', run: function () { shareNote(noteId); } },
      { label: '删除', danger: true, run: function () { trashNote(noteId); } }
    ];
    actions.forEach(function (a) {
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = a.label;
      if (a.danger) b.className = 'is-danger';
      b.addEventListener('click', function (e) {
        e.stopPropagation();
        closeItemMenu();
        a.run();
      });
      menu.appendChild(b);
    });
    document.body.appendChild(menu);
    var r = anchor.getBoundingClientRect();
    var mw = menu.offsetWidth || 112;
    var mh = menu.offsetHeight || 80;
    menu.style.left = Math.min(global.innerWidth - mw - 8, Math.max(8, r.right - mw)) + 'px';
    menu.style.top = Math.min(global.innerHeight - mh - 8, r.bottom + 4) + 'px';
    itemMenu = menu;
  }

  // ---------------------------------------------------------------- 分享

  function shareNote(noteId) {
    if (!noteId) return;
    api('tradeNoteShare', { noteId: noteId })
      .then(function (j) {
        if (!j || !j.url) return;
        S.shareUrl = j.url;
        el.shareUrl.value = j.url;
        try {
          if (global.qrcode) {
            var qr = global.qrcode(0, 'M');
            qr.addData(j.url);
            qr.make();
            el.shareQr.src = qr.createDataURL(5, 8);
          }
        } catch (e) {}
        el.shareModal.hidden = false;
      })
      .catch(function (e) {
        toast(msgOf(e.code));
      });
  }

  function copyShareUrl() {
    var url = el.shareUrl.value;
    if (!url) return;
    function done() {
      toast('链接已复制');
    }
    if (global.navigator && global.navigator.clipboard && global.navigator.clipboard.writeText) {
      global.navigator.clipboard.writeText(url).then(done, function () {
        el.shareUrl.select();
        try {
          document.execCommand('copy');
          done();
        } catch (e) {}
      });
      return;
    }
    el.shareUrl.select();
    try {
      document.execCommand('copy');
      done();
    } catch (e) {}
  }

  // ---------------------------------------------------------------- 头像

  function loadAvatar() {
    api('tradeAvatarGet', {})
      .then(function (j) {
        if (j.avatar && el.avatarImg) el.avatarImg.src = j.avatar;
      })
      .catch(function () {});
  }

  function setAvatar(file) {
    if (!file) return;
    loadBitmap(file)
      .then(function (src) {
        var sw = src.width || src.naturalWidth;
        var sh = src.height || src.naturalHeight;
        var size = 96;
        var canvas = document.createElement('canvas');
        canvas.width = size;
        canvas.height = size;
        var ctx = canvas.getContext('2d');
        ctx.fillStyle = '#fff';
        ctx.fillRect(0, 0, size, size);
        var scale = Math.max(size / sw, size / sh);
        var w = sw * scale;
        var h = sh * scale;
        ctx.drawImage(src, (size - w) / 2, (size - h) / 2, w, h);
        if (src.close) src.close();
        return canvas.toDataURL('image/jpeg', 0.82);
      })
      .then(function (dataUrl) {
        if (dataUrl.length > 60000) {
          toast('头像太大了，换一张');
          return;
        }
        return api('tradeAvatarSet', { avatar: dataUrl }).then(function () {
          el.avatarImg.src = dataUrl;
          toast('头像已更新');
        });
      })
      .catch(function (e) {
        if (e && e.code) toast(msgOf(e.code));
        else toast('头像处理失败');
      });
  }

  // ---------------------------------------------------------------- 左右拖动
  // 中间不画分割线，但保留 10px 透明热区，仍可拖动调整列表宽度。

  function initSplit() {
    if (!el.splitBar || !el.sidePane) return;
    var min = 170;

    function maxW() {
      return Math.max(min, Math.min(global.innerWidth * 0.42, 500));
    }

    function place(w) {
      el.splitBar.style.left = el.sidePane.offsetLeft + w + 'px';
    }

    function setW(w, persist) {
      w = Math.max(min, Math.min(maxW(), w));
      el.sidePane.style.width = w + 'px';
      place(w);
      if (persist) writeLS(LS_SIDEW, String(Math.round(w)));
    }

    var saved = parseFloat(readLS(LS_SIDEW));
    if (Number.isFinite(saved)) setW(saved, false);
    else place(el.sidePane.getBoundingClientRect().width);

    var drag = null;
    el.splitBar.addEventListener('pointerdown', function (e) {
      if (e.button !== 0) return;
      e.preventDefault();
      drag = { x: e.clientX, w: el.sidePane.getBoundingClientRect().width };
      if (el.splitBar.setPointerCapture) {
        try {
          el.splitBar.setPointerCapture(e.pointerId);
        } catch (err) {}
      }
    });
    el.splitBar.addEventListener('pointermove', function (e) {
      if (!drag) return;
      setW(drag.w + (e.clientX - drag.x), false);
    });
    function endDrag() {
      if (!drag) return;
      drag = null;
      setW(el.sidePane.getBoundingClientRect().width, true);
    }
    el.splitBar.addEventListener('pointerup', endDrag);
    el.splitBar.addEventListener('pointercancel', endDrag);
    el.splitBar.addEventListener('keydown', function (e) {
      var w = el.sidePane.getBoundingClientRect().width;
      if (e.key === 'ArrowLeft') {
        e.preventDefault();
        setW(w - 12, true);
      } else if (e.key === 'ArrowRight') {
        e.preventDefault();
        setW(w + 12, true);
      }
    });
  }

  // ---------------------------------------------------------------- 工具栏

  function closePops(except) {
    [el.fontMenu, el.colorMenu].forEach(function (m) {
      if (m && m !== except) m.hidden = true;
    });
  }

  function togglePop(menu) {
    if (!menu) return;
    var willOpen = menu.hidden;
    closePops();
    if (willOpen) menu.hidden = false;
  }

  function focusBody() {
    if (!el.noteBody) return;
    el.noteBody.focus();
  }

  function exec(cmd, value) {
    focusBody();
    try {
      document.execCommand(cmd, false, value == null ? null : value);
    } catch (e) {}
    setDirty();
  }

  function applyFontSize(px) {
    focusBody();
    var sel = global.getSelection();
    if (!sel || !sel.rangeCount || sel.isCollapsed) return;
    var range = sel.getRangeAt(0);
    var span = document.createElement('span');
    span.style.fontSize = px + 'px';
    try {
      range.surroundContents(span);
    } catch (e) {
      try {
        document.execCommand('styleWithCSS', false, false);
        document.execCommand('fontSize', false, '7');
      } catch (e2) {
        return;
      }
      Array.prototype.forEach.call(el.noteBody.querySelectorAll('font[size="7"]'), function (f) {
        var s = document.createElement('span');
        s.style.fontSize = px + 'px';
        while (f.firstChild) s.appendChild(f.firstChild);
        if (f.parentNode) f.parentNode.replaceChild(s, f);
      });
      if (el.tbFontLabel) el.tbFontLabel.textContent = String(px);
      return setDirty();
    }
    var r = document.createRange();
    r.selectNodeContents(span);
    sel.removeAllRanges();
    sel.addRange(r);
    if (el.tbFontLabel) el.tbFontLabel.textContent = String(px);
    setDirty();
  }

  function applyColor(prop, color) {
    focusBody();
    try {
      document.execCommand('styleWithCSS', false, true);
      document.execCommand(prop, false, color);
      document.execCommand('styleWithCSS', false, false);
    } catch (e) {}
    setDirty();
  }

  function insertEmoji(emoji) {
    focusBody();
    try {
      document.execCommand('insertText', false, emoji);
    } catch (e) {}
    setDirty();
  }

  function buildPalettes() {
    if (el.colorMenu) {
      el.colorMenu.innerHTML = '';
      TEXT_COLORS.forEach(function (color) {
        var b = document.createElement('button');
        b.type = 'button';
        b.style.background = color;
        b.setAttribute('data-color', color);
        b.title = color;
        el.colorMenu.appendChild(b);
      });
    }
  }

  function updateToolbarState() {
    if (!el.noteBody) return;
    var sel = global.getSelection && global.getSelection();
    if (!sel || !sel.anchorNode || !el.noteBody.contains(sel.anchorNode)) return;
    S.savedRange = sel.rangeCount ? sel.getRangeAt(0).cloneRange() : S.savedRange;
    ['bold', 'italic', 'underline'].forEach(function (cmd) {
      var btn = el.toolbar ? el.toolbar.querySelector('[data-cmd="' + cmd + '"]') : null;
      if (!btn) return;
      var on = false;
      try {
        on = document.queryCommandState(cmd);
      } catch (e) {}
      btn.classList.toggle('is-on', !!on);
    });
  }

  // ---------------------------------------------------------------- 图片大图

  function openLightbox(src) {
    if (!el.lightbox || !el.lightboxImg) return;
    el.lightboxImg.src = src;
    el.lightbox.hidden = false;
  }

  function closeLightbox() {
    if (!el.lightbox) return;
    el.lightbox.hidden = true;
    el.lightboxImg.removeAttribute('src');
  }

  // ---------------------------------------------------------------- 账户菜单

  function renderAccountMenu() {
    if (el.menuWho) {
      el.menuWho.textContent = S.user
        ? '已登录 · ' + S.user
        : S.token
          ? '已登录'
          : '未登录';
    }
    if (el.menuLogout) el.menuLogout.hidden = !S.token;
    if (el.menuAvatar) el.menuAvatar.hidden = !S.token;
  }

  function closeMenu() {
    if (!el.acctMenu) return;
    el.acctMenu.hidden = true;
    if (el.btnMenu) el.btnMenu.setAttribute('aria-expanded', 'false');
  }

  function bindMenu() {
    if (el.btnMenu && el.acctMenu) {
      el.btnMenu.addEventListener('click', function (e) {
        e.stopPropagation();
        var willOpen = el.acctMenu.hidden;
        closeMenu();
        if (willOpen) {
          el.acctMenu.hidden = false;
          el.btnMenu.setAttribute('aria-expanded', 'true');
        }
      });
    }
    if (el.menuLogout) {
      el.menuLogout.addEventListener('click', function () {
        writeLS(LS_TOKEN, '');
        writeLS(LS_USER, '');
        global.location.href = (CFG.rel || '') + 'index.html';
      });
    }
    if (el.menuAvatar && el.avatarInput) {
      el.menuAvatar.addEventListener('click', function () {
        closeMenu();
        el.avatarInput.value = '';
        el.avatarInput.click();
      });
    }
    document.addEventListener('click', function (e) {
      var t = e.target;
      if (t && t.closest && (t.closest('#acctMenu') || t.closest('#btnMenu'))) return;
      closeMenu();
    });
  }

  // ---------------------------------------------------------------- 事件

  function bind() {
    el.btnNew.addEventListener('click', function () {
      newNote(false);
    });
    el.btnSave.addEventListener('click', function () {
      save(false);
    });
    el.btnBack.addEventListener('click', function () {
      document.body.classList.remove('is-editing');
    });
    el.btnTrash.addEventListener('click', function (e) {
      e.stopPropagation();
      toggleTrashPanel();
    });
    if (el.trashClear) el.trashClear.addEventListener('click', clearTrash);

    el.notesList.addEventListener('click', function (e) {
      var t = e.target;
      if (!t || !t.closest) return;
      var more = t.closest('[data-more]');
      if (more) {
        e.stopPropagation();
        openItemMenu(more.getAttribute('data-more'), more);
        return;
      }
      var open = t.closest('[data-open]');
      var row = t.closest('.notes-item');
      if (open && row) openNote(row.getAttribute('data-id'), false);
    });

    el.noteTitle.addEventListener('input', function () {
      fitTitle();
      setDirty();
    });
    el.noteBody.addEventListener('input', function () {
      if (S.cur) S.cur.contentFormat = 'html';
      setDirty();
    });
    el.noteBody.addEventListener('paste', function (e) {
      var cd = e.clipboardData || global.clipboardData;
      if (!cd) return;
      // 从走势图复制过来的截图：直接当图片插到光标处，别再当纯文本丢掉。
      var items = cd.items || [];
      for (var i = 0; i < items.length; i += 1) {
        if (items[i] && items[i].kind === 'file' && /^image\//.test(items[i].type || '')) {
          var file = items[i].getAsFile();
          if (file) {
            e.preventDefault();
            saveRange();
            insertImageFile(file);
            return;
          }
        }
      }
      e.preventDefault();
      var text = cd.getData('text/plain') || '';
      try {
        document.execCommand('insertText', false, text);
      } catch (err) {}
      setDirty();
    });
    el.noteBody.addEventListener('click', function (e) {
      var t = e.target;
      if (t && t.tagName === 'IMG') {
        e.preventDefault();
        openLightbox(t.src);
      }
    });

    el.fileInput.addEventListener('change', function () {
      pickImages(el.fileInput.files);
    });

    if (el.avatarInput) {
      el.avatarInput.addEventListener('change', function () {
        setAvatar(el.avatarInput.files && el.avatarInput.files[0]);
      });
    }

    el.toolbar.addEventListener('mousedown', function (e) {
      if (e.target && e.target.closest && e.target.closest('button')) {
        e.preventDefault();
      }
    });

    el.tbImage.addEventListener('click', function () {
      saveRange();
      el.fileInput.value = '';
      el.fileInput.click();
    });
    el.tbBullet.addEventListener('click', function () {
      exec('insertUnorderedList');
    });
    el.tbFont.addEventListener('click', function (e) {
      e.stopPropagation();
      togglePop(el.fontMenu);
    });
    el.tbColor.addEventListener('click', function (e) {
      e.stopPropagation();
      togglePop(el.colorMenu);
    });
    el.tbClear.addEventListener('click', function () {
      closePops();
      exec('removeFormat');
      exec('unlink');
    });

    el.toolbar.addEventListener('click', function (e) {
      var t = e.target;
      if (!t || !t.closest) return;
      var cmdBtn = t.closest('[data-cmd]');
      if (cmdBtn) {
        exec(cmdBtn.getAttribute('data-cmd'));
        return;
      }
      var sizeBtn = t.closest('[data-size]');
      if (sizeBtn) {
        applyFontSize(Number(sizeBtn.getAttribute('data-size')));
        closePops();
        return;
      }
      var colorBtn = t.closest('[data-color]');
      if (colorBtn) {
        applyColor('foreColor', colorBtn.getAttribute('data-color'));
        closePops();
      }
    });

    document.addEventListener('click', function (e) {
      var t = e.target;
      if (t && t.closest && t.closest('#toolbar')) {
        if (!t.closest('.tb-pop')) closePops();
      } else {
        closePops();
      }
      if (t && t.closest && (t.closest('#trashPanel') || t.closest('#btnTrash'))) return;
      closeTrashPanel();
      if (!t || !t.closest || !t.closest('.notes-item-menu')) closeItemMenu();
    });

    document.addEventListener('selectionchange', updateToolbarState);

    document.addEventListener('keydown', function (e) {
      if ((e.ctrlKey || e.metaKey) && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        save(false);
      }
      if (e.key === 'Escape') {
        closePops();
        closeTrashPanel();
        closeLightbox();
        el.shareModal.hidden = true;
      }
    });

    if (el.lightboxClose) el.lightboxClose.addEventListener('click', closeLightbox);
    if (el.lightbox) {
      el.lightbox.addEventListener('click', function (e) {
        if (e.target === el.lightbox) closeLightbox();
      });
    }

    if (el.shareClose) {
      el.shareClose.addEventListener('click', function () {
        el.shareModal.hidden = true;
      });
    }
    if (el.shareCopy) el.shareCopy.addEventListener('click', copyShareUrl);
    if (el.shareNative) {
      el.shareNative.addEventListener('click', function () {
        if (global.navigator && global.navigator.share) {
          global.navigator.share({ title: '交易笔记', url: S.shareUrl }).catch(function () {});
        } else {
          copyShareUrl();
        }
      });
    }
    if (el.shareModal) {
      el.shareModal.addEventListener('click', function (e) {
        if (e.target === el.shareModal) el.shareModal.hidden = true;
      });
    }

    global.addEventListener('beforeunload', function (e) {
      if (!S.dirty) return;
      e.preventDefault();
      e.returnValue = '';
    });

    global.addEventListener('resize', function () {
      closeItemMenu();
      closePops();
      closeTrashPanel();
    });
    global.addEventListener('scroll', closeItemMenu, true);
  }

  function cacheEls() {
    [
      'notesList', 'quotaText',
      'btnNew', 'btnSave', 'btnBack', 'btnTrash',
      'noteTitle', 'noteBody', 'noteDate', 'saveState', 'saveStateText',
      'loginGate', 'toast', 'toolbar', 'tbImage',
      'tbBullet', 'tbFont', 'tbFontLabel', 'tbColor', 'tbClear',
      'fontMenu', 'colorMenu',
      'splitBar', 'sidePane',
      'trashPanel', 'trashList', 'trashClear',
      'lightbox', 'lightboxImg', 'lightboxClose',
      'avatarImg', 'avatarInput', 'menuAvatar',
      'shareModal', 'shareQr', 'shareUrl', 'shareCopy', 'shareNative', 'shareClose',
      'fileInput',
      'btnMenu', 'acctMenu', 'menuWho', 'menuLogout'
    ].forEach(function (id) {
      el[id] = $(id);
    });
  }

  function init() {
    cacheEls();
    S.token = readLS(LS_TOKEN);
    S.user = readLS(LS_USER);
    renderAccountMenu();
    if (!S.token) {
      gate();
      bindMenu();
      return;
    }
    buildPalettes();
    bind();
    bindMenu();
    initSplit();
    loadAvatar();
    loadList(false);
  }

  init();
})(window);
