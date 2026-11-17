/* 公开分享页：/note.html?s=<shareId>
 * 只调 tradeNotePublicGet，不需要登录；正文由服务端清洗过，图片已换成临时链接。
 */
(function (global) {
  'use strict';

  var CFG = global.SHARE_CFG || {};
  var titleEl = document.getElementById('shareTitle');
  var metaEl = document.getElementById('shareMeta');
  var contentEl = document.getElementById('shareContent');
  var errorEl = document.getElementById('shareError');

  function fail(text) {
    titleEl.textContent = '笔记打不开';
    metaEl.textContent = '';
    contentEl.innerHTML = '';
    errorEl.hidden = false;
    errorEl.textContent = text;
  }

  function fmt(ts) {
    var n = Number(ts) || 0;
    if (!n) return '';
    var d = new Date(n);
    var p = function (x) {
      return x < 10 ? '0' + x : '' + x;
    };
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  var shareId = '';
  try {
    shareId = new URLSearchParams(global.location.search).get('s') || '';
  } catch (e) {
    shareId = '';
  }
  if (!shareId) {
    fail('链接不完整。');
    return;
  }

  fetch(CFG.api, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: 'Bearer ' + CFG.key
    },
    body: JSON.stringify({ action: 'tradeNotePublicGet', shareId: shareId })
  })
    .then(function (res) {
      return res.json();
    })
    .then(function (j) {
      if (!j || !j.ok || !j.note) {
        fail('这条笔记可能已被作者删除，或取消分享。');
        return;
      }
      var n = j.note;
      titleEl.textContent = n.title || '无标题笔记';
      metaEl.textContent = fmt(n.createdAt);
      contentEl.innerHTML = n.content || '';
      contentEl.style.lineHeight = String(Number(n.lineHeight) || 1.5);
      document.title = (n.title || '交易笔记') + ' · 燃灯';
    })
    .catch(function () {
      fail('网络不稳定，稍后再试。');
    });
})(window);
