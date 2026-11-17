/* 页脚「联系我们」：点了先弹窗给出邮箱，可复制、可调起本机邮件客户端。
   本机没配邮件客户端时 mailto 点了没反应，这里至少保证有明确反馈。
   用法：页面里放 <footer class="lite-foot"> 且含一个 mailto 链接，引入本脚本即可。 */
(function () {
  "use strict";

  var link = document.querySelector('.lite-foot a[href^="mailto:"]');
  if (!link) return;

  var address = (link.getAttribute("href") || "").replace(/^mailto:/, "");
  var box = null;

  function build() {
    box = document.createElement("div");
    box.className = "mail-dialog";
    box.id = "mailDialog";
    box.hidden = true;
    box.innerHTML =
      '<div class="mail-dialog__box" role="dialog" aria-modal="true" aria-labelledby="mailDialogTitle">' +
      '<h2 class="mail-dialog__title" id="mailDialogTitle">联系我们</h2>' +
      '<p class="mail-dialog__addr"></p>' +
      '<div class="mail-dialog__acts">' +
      '<button type="button" class="mail-dialog__btn" data-act="copy">复制邮箱</button>' +
      '<a class="mail-dialog__btn mail-dialog__btn--primary" data-act="open">打开邮件客户端</a>' +
      "</div>" +
      '<button type="button" class="mail-dialog__close" aria-label="关闭">×</button>' +
      "</div>";
    box.querySelector(".mail-dialog__addr").textContent = address;
    box.querySelector('[data-act="open"]').setAttribute("href", "mailto:" + address);
    document.body.appendChild(box);

    box.addEventListener("click", function (e) {
      if (e.target === box) close();
    });
    box.querySelector(".mail-dialog__close").addEventListener("click", close);
    box.querySelector('[data-act="copy"]').addEventListener("click", function () {
      var btn = this;
      var done = function () {
        btn.textContent = "已复制";
        window.setTimeout(function () {
          btn.textContent = "复制邮箱";
        }, 1600);
      };
      var fallback = function () {
        var ta = document.createElement("textarea");
        ta.value = address;
        ta.setAttribute("readonly", "");
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        try {
          document.execCommand("copy");
          done();
        } catch (err) {
          /* 复制失败就让用户自己选中 */
        }
        document.body.removeChild(ta);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(address).then(done, fallback);
      } else {
        fallback();
      }
    });
  }

  function open() {
    if (!box) build();
    box.hidden = false;
    var btn = box.querySelector(".mail-dialog__close");
    if (btn) btn.focus();
  }

  function close() {
    if (!box) return;
    box.hidden = true;
    link.focus();
  }

  link.addEventListener("click", function (e) {
    e.preventDefault();
    open();
  });

  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && box && !box.hidden) close();
  });
})();
