/* 缠论读书会 · 每课评论
   - 每篇文章末尾一块评论区，任何用户都能发表评论、回复别人的评论；
   - randeng 等管理员可置顶 / 删除任意评论，作者可删除自己的评论；
   - 评论按 lessonNo 归属，课与课互不混淆；
   - 身份与正文注释共用 localStorage 里的 clientId + secret，
     管理员由云函数 chanAdmins 里的 clientId + clientHash 判定。 */
(function () {
  "use strict";

  var reader = document.getElementById("chanReader");
  var cfg = window.CHAN_CFG || {};
  if (!reader || !cfg.api || !cfg.key) return;

  /* ------------------------------------------------------------ 本地身份 */

  var LS_ID = "chan:anno:id";
  var LS_SECRET = "chan:anno:secret";
  var LS_NAME = "chan:anno:name";
  var TRADE_USER_KEY = "huideng.trade.user";

  function readLS(key) {
    try {
      return window.localStorage.getItem(key);
    } catch (e) {
      return null;
    }
  }

  function writeLS(key, value) {
    try {
      window.localStorage.setItem(key, value);
    } catch (e) {}
  }

  function randomHex(bytes) {
    var out = "";
    var i;
    try {
      var buf = new Uint8Array(bytes);
      window.crypto.getRandomValues(buf);
      for (i = 0; i < buf.length; i += 1) {
        out += (buf[i] + 0x100).toString(16).slice(1);
      }
    } catch (e) {
      out = "";
      for (i = 0; i < bytes * 2; i += 1) {
        out += Math.floor(Math.random() * 16).toString(16);
      }
    }
    return out;
  }

  var clientId = readLS(LS_ID);
  if (!clientId) {
    clientId = randomHex(12);
    writeLS(LS_ID, clientId);
  }
  var secret = readLS(LS_SECRET);
  if (!secret) {
    secret = randomHex(24);
    writeLS(LS_SECRET, secret);
  }

  function savedName() {
    return readLS(LS_NAME) || readLS(TRADE_USER_KEY) || "";
  }

  /* -------------------------------------------------------------- 状态 */

  var lessonNo = 0;
  var state = null; // { no, comments: [], total, admin, profiles, error }
  var cache = {}; // no -> { comments, total, admin, profiles, at }
  var loadSeq = 0;
  var replyOpen = null;
  var toastEl = null;
  var toastTimer = 0;
  var CACHE_TTL = 60 * 1000;
  var myAvatar = "";
  var avatarTried = false;
  var avatarSaved = false;

  /* -------------------------------------------------------------- 工具 */

  function pad2(n) {
    return n < 10 ? "0" + n : "" + n;
  }

  function formatTime(ts) {
    var n = Number(ts) || 0;
    if (!n) return "";
    var d = new Date(n);
    return (
      d.getFullYear() +
      "-" +
      pad2(d.getMonth() + 1) +
      "-" +
      pad2(d.getDate()) +
      " " +
      pad2(d.getHours()) +
      ":" +
      pad2(d.getMinutes())
    );
  }

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  }

  function toast(text) {
    if (!toastEl) {
      toastEl = document.createElement("div");
      toastEl.className = "chan-anno-toast";
      toastEl.setAttribute("role", "status");
      document.body.appendChild(toastEl);
    }
    toastEl.textContent = text;
    toastEl.hidden = false;
    if (toastTimer) window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      toastEl.hidden = true;
      toastTimer = 0;
    }, 2800);
  }

  function activeSection() {
    return reader.querySelector(".chan-lesson.is-on");
  }

  function commentsBox(no) {
    var sec = no
      ? document.querySelector('.chan-lesson[data-no="' + no + '"]')
      : activeSection();
    return sec ? sec.querySelector(".chan-comments") : null;
  }

  /* -------------------------------------------------------------- 接口 */

  function mkErr(code) {
    var e = new Error(code);
    e.code = code;
    return e;
  }

  function api(action, params, timeout) {
    var body = { action: action };
    if (params) {
      Object.keys(params).forEach(function (k) {
        body[k] = params[k];
      });
    }
    var ctl = null;
    var timer = 0;
    if (window.AbortController) {
      ctl = new AbortController();
      timer = window.setTimeout(function () {
        try {
          ctl.abort();
        } catch (e) {}
      }, timeout || 25000);
    }
    var opts = {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + cfg.key,
        "x-device-id": "web-chan-comments",
      },
      body: JSON.stringify(body),
    };
    if (ctl) opts.signal = ctl.signal;

    return fetch(cfg.api, opts)
      .then(function (res) {
        if (timer) {
          window.clearTimeout(timer);
          timer = 0;
        }
        if (!res.ok) throw mkErr("http_" + res.status);
        return res.json();
      })
      .then(function (j) {
        if (!j || !j.ok) throw mkErr((j && j.error) || "error");
        return j;
      })
      .catch(function (e) {
        if (timer) window.clearTimeout(timer);
        if (e && e.code) throw e;
        throw mkErr("network");
      });
  }

  function errorText(e) {
    var code = e && e.code ? e.code : "";
    if (code === "rate_limited") return "发得太频繁了，歇一会儿再试";
    if (code === "empty_comment") return "评论不能为空";
    if (code === "parent_deleted") return "这条评论已经被删除了";
    if (code === "forbidden") return "没有权限执行这个操作";
    if (code === "bad_request") return "内容有点问题，请检查后再试";
    return "网络不给力，请稍后重试";
  }

  /* -------------------------------------------------------------- 加载 */

  function load(no, force) {
    if (!no) return;
    var box = commentsBox(no);
    if (!box) return;
    var cached = cache[no];
    if (!force && cached && Date.now() - cached.at < CACHE_TTL) {
      state = {
        no: no,
        comments: cached.comments,
        total: cached.total,
        admin: cached.admin,
        profiles: cached.profiles || {},
        error: false,
      };
      render();
      return;
    }
    var seq = ++loadSeq;
    state = { no: no, comments: null, total: 0, admin: false, profiles: {}, error: false };
    render();
    api("getChanComments", {
      lessonNo: no,
      clientId: clientId,
      clientSecret: secret,
    })
      .then(function (j) {
        if (seq !== loadSeq || no !== lessonNo) return;
        var comments = (j && j.comments) || [];
        state = {
          no: no,
          comments: comments,
          total: Number(j.total) || 0,
          admin: !!j.admin,
          profiles: (j && j.profiles) || {},
          error: false,
        };
        cache[no] = {
          comments: comments,
          total: state.total,
          admin: state.admin,
          profiles: state.profiles,
          at: Date.now(),
        };
        render();
      })
      .catch(function () {
        if (seq !== loadSeq || no !== lessonNo) return;
        state = { no: no, comments: null, total: 0, admin: false, profiles: {}, error: true };
        render();
      });
  }

  function reload() {
    delete cache[lessonNo];
    load(lessonNo, true);
  }

  function avatarFor(c) {
    var fromState = state && state.profiles ? state.profiles[c.clientId] : "";
    if (fromState) return fromState;
    if (c.clientId && c.clientId === clientId && myAvatar) return myAvatar;
    return "";
  }

  function avatarNode(c, who) {
    var src = avatarFor(c);
    if (src) {
      var img = document.createElement("img");
      img.className = "chan-comment__avatar chan-comment__avatar--img";
      img.src = src;
      img.alt = "";
      img.loading = "lazy";
      return img;
    }
    return el(
      "span",
      "chan-comment__avatar",
      String(who || "匿").trim().charAt(0) || "匿"
    );
  }

  // 头像取自己账号里上传过的头像（交易/个人资料共用 tradeAvatarGet），
  // 存到 chanProfiles（按 clientId），这样所有用户都能看到；没有就保持首字默认头像。
  function applyMyAvatar() {
    if (!myAvatar) return;
    if (state && state.profiles) state.profiles[clientId] = myAvatar;
    if (cache[lessonNo]) {
      if (!cache[lessonNo].profiles) cache[lessonNo].profiles = {};
      cache[lessonNo].profiles[clientId] = myAvatar;
    }
    var nodes = document.querySelectorAll(
      '.chan-comment[data-client="' + clientId + '"] > .chan-comment__avatar'
    );
    for (var i = 0; i < nodes.length; i += 1) {
      var old = nodes[i];
      var img = document.createElement("img");
      img.className = "chan-comment__avatar chan-comment__avatar--img";
      img.src = myAvatar;
      img.alt = "";
      img.loading = "lazy";
      old.parentNode.replaceChild(img, old);
    }
  }

  function fetchMyAvatar() {
    if (avatarTried) return;
    avatarTried = true;
    var token = readLS("huideng.trade.token");
    if (!token) return;
    api("tradeAvatarGet", { token: token })
      .then(function (j) {
        var av = j && j.avatar ? String(j.avatar) : "";
        if (!av) return;
        myAvatar = av;
        applyMyAvatar();
        if (!avatarSaved) {
          avatarSaved = true;
          api("saveChanAvatar", {
            clientId: clientId,
            clientSecret: secret,
            avatar: av,
          }).catch(function () {});
        }
      })
      .catch(function () {});
  }

  /* -------------------------------------------------------------- 渲染 */

  function render() {
    var box = commentsBox(state ? state.no : lessonNo);
    if (!box || !state) return;
    box.innerHTML = "";

    var head = el("div", "chan-comments__head");
    head.appendChild(el("h2", "chan-comments__title", "评论"));
    var count = el(
      "span",
      "chan-comments__count",
      state.comments ? String(state.total) : "…"
    );
    head.appendChild(count);
    if (state.admin) {
      var badge = el("span", "chan-comments__admin", "管理员");
      badge.title = "你可以置顶或删除本课评论";
      head.appendChild(badge);
    }
    var refresh = el("button", "chan-comments__refresh", "↻");
    refresh.type = "button";
    refresh.setAttribute("aria-label", "刷新评论");
    refresh.title = "刷新评论";
    refresh.addEventListener("click", function () {
      reload();
    });
    head.appendChild(refresh);
    box.appendChild(head);

    if (state.error) {
      box.appendChild(el("p", "chan-comments__empty", "评论加载失败，点右上角 ↻ 重试。"));
      return;
    }
    if (!state.comments) {
      box.appendChild(el("p", "chan-comments__empty", "正在加载评论…"));
      return;
    }

    box.appendChild(composer());

    var list = el("div", "chan-comments__list");
    // 删掉的评论不显示；主楼删掉时，它下面的回复也不显示
    var visible = state.comments.filter(function (c) {
      return !c.deleted;
    });
    var tops = visible.filter(function (c) {
      return !c.parentId;
    });
    tops.sort(function (a, b) {
      var ap = !!a.pinned;
      var bp = !!b.pinned;
      if (bp !== ap) return bp ? 1 : -1;
      if (bp && ap) return (b.pinnedAt || 0) - (a.pinnedAt || 0);
      return (b.createdAt || 0) - (a.createdAt || 0);
    });

    if (!tops.length) {
      list.appendChild(
        el("p", "chan-comments__empty", "还没有评论，来说两句吧。")
      );
    } else {
      tops.forEach(function (top) {
        var replies = visible
          .filter(function (c) {
            return c.parentId === top.id;
          })
          .sort(function (a, b) {
            return (a.createdAt || 0) - (b.createdAt || 0);
          });
        list.appendChild(commentEl(top, replies, true));
      });
    }
    box.appendChild(list);
  }

  function composer() {
    var wrap = el("div", "chan-comments__compose");
    var ta = el("textarea");
    ta.maxLength = 1000;
    ta.placeholder = "写下你对这一课的看法…";
    ta.setAttribute("aria-label", "评论内容");
    wrap.appendChild(ta);

    var row = el("div", "chan-comments__compose-row");
    var btn = el("button", "chan-comments__submit", "发表评论");
    btn.type = "button";
    row.appendChild(btn);
    wrap.appendChild(row);

    function submit() {
      var text = String(ta.value || "").trim();
      if (!text) {
        toast("评论不能为空");
        ta.focus();
        return;
      }
      var who = String(savedName() || "").trim().slice(0, 20);
      btn.disabled = true;
      btn.textContent = "发表中…";
      api("createChanComment", {
        lessonNo: lessonNo,
        parentId: "",
        content: text,
        name: who,
        clientId: clientId,
        clientSecret: secret,
      })
        .then(function () {
          toast("评论已发表");
          reload();
        })
        .catch(function (e) {
          btn.disabled = false;
          btn.textContent = "发表评论";
          toast(errorText(e));
        });
    }

    btn.addEventListener("click", submit);
    ta.addEventListener("keydown", function (e) {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        submit();
      }
    });
    // 当前课切走时草稿不该跟着乱跑到别的课：不缓存草稿，切课重建
    return wrap;
  }

  function commentEl(c, replies, isTop) {
    var box = el("article", "chan-comment");
    box.setAttribute("data-id", c.id);
    if (!isTop) box.classList.add("chan-comment--reply");

    var who = String(c.name || "匿名读者").replace(/^@+/, "");
    box.setAttribute("data-client", c.clientId || "");
    box.appendChild(avatarNode(c, who));

    var main = el("div", "chan-comment__main");
    box.appendChild(main);

    var head = el("div", "chan-comment__head");
    head.appendChild(el("span", "chan-comment__who", "@" + who));
    if (!isTop && c.replyToName) {
      head.appendChild(
        el(
          "span",
          "chan-comment__replyto",
          "回复 @" + String(c.replyToName).replace(/^@+/, "")
        )
      );
    }
    if (c.pinned) head.appendChild(el("span", "chan-comment__pin", "置顶"));
    head.appendChild(el("span", "chan-comment__time", formatTime(c.createdAt)));
    main.appendChild(head);

    main.appendChild(el("p", "chan-comment__body", c.content || ""));

    var acts = el("div", "chan-comment__acts");
    var replyBtn = el("button", "", "回复");
    replyBtn.type = "button";
    replyBtn.addEventListener("click", function () {
      openReplyForm(box, c);
    });
    acts.appendChild(replyBtn);

    if (state.admin) {
      var delBtn = el("button", "", "删除");
      delBtn.type = "button";
      delBtn.addEventListener("click", function () {
        removeComment(c.id);
      });
      acts.appendChild(delBtn);
    }
    if (state.admin && isTop) {
      var pinBtn = el("button", "", c.pinned ? "取消置顶" : "置顶");
      pinBtn.type = "button";
      pinBtn.addEventListener("click", function () {
        pinComment(c.id, !c.pinned);
      });
      acts.appendChild(pinBtn);
    }
    if (acts.children.length) main.appendChild(acts);

    if (isTop && replies.length) {
      var wrap = el("div", "chan-comment__replies");
      replies.forEach(function (r) {
        wrap.appendChild(commentEl(r, [], false));
      });
      main.appendChild(wrap);
    }
    return box;
  }

  function openReplyForm(parentBox, comment) {
    if (replyOpen) {
      replyOpen.remove();
      replyOpen = null;
    }
    var form = el("div", "chan-comment__reply-form");
    var ta = el("textarea");
    ta.maxLength = 1000;
    ta.placeholder = "回复 @" + String(comment.name || "匿名读者").replace(/^@+/, "") + "…";
    ta.setAttribute("aria-label", "回复内容");
    form.appendChild(ta);

    var row = el("div", "chan-comments__compose-row");
    var cancel = el("button", "chan-comments__cancel", "取消");
    cancel.type = "button";
    var send = el("button", "chan-comments__submit", "回复");
    send.type = "button";
    row.appendChild(cancel);
    row.appendChild(send);
    form.appendChild(row);

    var host = parentBox.querySelector(".chan-comment__main") || parentBox;
    var repliesBox = host.querySelector(".chan-comment__replies");
    if (repliesBox) host.insertBefore(form, repliesBox);
    else host.appendChild(form);
    replyOpen = form;
    ta.focus();

    cancel.addEventListener("click", function () {
      form.remove();
      if (replyOpen === form) replyOpen = null;
    });

    function submit() {
      var text = String(ta.value || "").trim();
      if (!text) {
        toast("回复不能为空");
        ta.focus();
        return;
      }
      send.disabled = true;
      send.textContent = "回复中…";
      api("createChanComment", {
        lessonNo: lessonNo,
        parentId: comment.id,
        content: text,
        name: savedName(),
        clientId: clientId,
        clientSecret: secret,
      })
        .then(function () {
          toast("回复已发表");
          reload();
        })
        .catch(function (e) {
          send.disabled = false;
          send.textContent = "回复";
          toast(errorText(e));
        });
    }

    send.addEventListener("click", submit);
    ta.addEventListener("keydown", function (e) {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        submit();
      }
    });
  }

  function removeComment(id) {
    if (!window.confirm("删除这条评论？")) return;
    api("deleteChanComment", {
      id: id,
      clientId: clientId,
      clientSecret: secret,
    })
      .then(function () {
        toast("操作成功");
        reload();
      })
      .catch(function (e) {
        toast(errorText(e));
      });
  }

  function pinComment(id, pinned) {
    api("pinChanComment", {
      id: id,
      pinned: pinned,
      clientId: clientId,
      clientSecret: secret,
    })
      .then(function () {
        toast(pinned ? "已置顶" : "已取消置顶");
        reload();
      })
      .catch(function (e) {
        toast(errorText(e));
      });
  }

  /* -------------------------------------------------------------- 启动 */

  document.addEventListener("chan:lesson", function (e) {
    var no = e && e.detail ? Number(e.detail.no) : 0;
    if (!no || no === lessonNo) return;
    lessonNo = no;
    state = null;
    replyOpen = null;
    load(no);
  });

  (function init() {
    var sec = activeSection();
    if (!sec) return;
    lessonNo = Number(sec.getAttribute("data-no")) || 1;
    load(lessonNo);
    fetchMyAvatar();
  })();
})();
