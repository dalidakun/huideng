/* 缠论读书会：108 课单页阅读器
   - hash 路由 #l001..#l108，复制地址即可分享单独一课
   - 目录检索（先查标题，标题没命中再查正文）
   - 记住上次读到哪、字号偏大偏小
   页面内容全部是构建时写死的静态 HTML，本脚本只负责显示哪一课。 */
(function () {
  "use strict";

  var reader = document.getElementById("chanReader");
  if (!reader) return;

  var scrollBox = document.getElementById("chanScroll");

  var sections = Array.prototype.slice.call(
    reader.querySelectorAll(".chan-lesson")
  );
  if (!sections.length) return;

  var tocLinks = Array.prototype.slice.call(
    document.querySelectorAll("#chanToc a")
  );
  var tocItems = tocLinks.map(function (a) {
    return a.parentNode;
  });

  var countEl = document.getElementById("chanCount");
  var prevBtn = document.getElementById("chanPrev");
  var nextBtn = document.getElementById("chanNext");
  var resumeBtn = document.getElementById("chanResume");
  var searchEl = document.getElementById("chanSearch");
  var searchBox = document.getElementById("chanSearchBox");
  var searchClear = document.getElementById("chanSearchClear");
  var sideEl = document.getElementById("chanSide");
  var tocBtn = document.getElementById("chanTocBtn");
  var tocScrim = document.getElementById("chanTocScrim");
  var emptyEl = document.getElementById("chanEmpty");
  var fontUp = document.getElementById("chanFontUp");
  var fontDown = document.getElementById("chanFontDown");

  var TOTAL = sections.length;
  var FS_KEY = "chan:fs";
  var LAST_KEY = "chan:last";
  var current = 0;

  function pad(n) {
    return ("00" + n).slice(-3);
  }

  function store(key, value) {
    try {
      window.localStorage.setItem(key, value);
    } catch (e) {
      /* 隐私模式里存不了，忽略 */
    }
  }

  function load(key) {
    try {
      return window.localStorage.getItem(key);
    } catch (e) {
      return null;
    }
  }

  function scrollToTop(smooth) {
    if (scrollBox) {
      scrollBox.scrollTo({
        top: 0,
        behavior: smooth ? "smooth" : "auto",
      });
    }
  }

  function show(no, opts) {
    opts = opts || {};
    no = Math.min(Math.max(no | 0, 1), TOTAL);

    sections.forEach(function (section) {
      section.classList.toggle("is-on", Number(section.dataset.no) === no);
    });

    var activeLink = null;
    tocLinks.forEach(function (a) {
      var on = Number(a.dataset.no) === no;
      if (on) {
        a.setAttribute("aria-current", "true");
        activeLink = a;
      } else {
        a.removeAttribute("aria-current");
      }
    });

    if (activeLink && opts.reveal !== false) {
      var box = activeLink.closest(".chan-toc-wrap");
      if (box) {
        var boxRect = box.getBoundingClientRect();
        var linkRect = activeLink.getBoundingClientRect();
        if (linkRect.top < boxRect.top + 8) {
          box.scrollTop += linkRect.top - boxRect.top - 8;
        } else if (linkRect.bottom > boxRect.bottom - 8) {
          box.scrollTop += linkRect.bottom - boxRect.bottom + 8;
        }
      }
    }

    var lesson = sections[no - 1];
    if (countEl) countEl.textContent = "第 " + no + " / " + TOTAL + " 课";
    if (prevBtn) prevBtn.disabled = no <= 1;
    if (nextBtn) nextBtn.disabled = no >= TOTAL;

    document.title = lesson.dataset.title + " · 缠论读书会";

    if (opts.scroll) scrollToTop(!opts.instant);

    if (opts.save !== false) store(LAST_KEY, String(no));
    current = no;

    // 通知注释模块（assets/js/chan-annotations.js）换课了：
    // 注释按课隔离，切换后要换成这一课的数据。
    try {
      document.dispatchEvent(
        new CustomEvent("chan:lesson", {
          detail: { no: no, title: lesson.dataset.title || "" },
        })
      );
    } catch (e) {}
  }

  function go(no, opts) {
    opts = opts || {};
    if (opts.push !== false) {
      var hash = "#l" + pad(no);
      if (location.hash !== hash) {
        location.hash = hash;
        // hashchange 会再调一次，这里只负责存
        return;
      }
    }
    show(no, opts);
  }

  function readHash() {
    var m = /^#l(\d{1,3})$/.exec(location.hash || "");
    return m ? Number(m[1]) : 0;
  }

  window.addEventListener("hashchange", function () {
    var no = readHash();
    if (!no) return;
    show(no, { scroll: true });
  });

  // 目录 / 翻页链接统一走 hash，浏览器前进后退也就能用
  document.addEventListener("click", function (e) {
    var link = e.target.closest ? e.target.closest('a[href^="#l"]') : null;
    if (!link) return;
    var m = /#l(\d{1,3})$/.exec(link.getAttribute("href"));
    if (!m) return;
    e.preventDefault();
    go(Number(m[1]), { scroll: true });
  });

  /* ---------------- 字号 ---------------- */

  function applyFont(size) {
    size = Math.min(Math.max(size, 14), 23);
    document.body.style.setProperty("--chan-fs", size + "px");
    store(FS_KEY, String(size));
  }

  if (fontUp) {
    fontUp.addEventListener("click", function () {
      var now = parseInt(load(FS_KEY) || "17", 10);
      applyFont(now + 1);
    });
  }
  if (fontDown) {
    fontDown.addEventListener("click", function () {
      var now = parseInt(load(FS_KEY) || "17", 10);
      applyFont(now - 1);
    });
  }
  applyFont(parseInt(load(FS_KEY) || "17", 10));

  /* ---------------- 手机上的目录抽屉 ---------------- */

  function openDrawer() {
    if (!sideEl) return;
    sideEl.classList.add("is-open");
    if (tocScrim) tocScrim.hidden = false;
    if (tocBtn) tocBtn.setAttribute("aria-expanded", "true");
  }

  function closeDrawer() {
    if (!sideEl) return;
    sideEl.classList.remove("is-open");
    if (tocScrim) tocScrim.hidden = true;
    if (tocBtn) tocBtn.setAttribute("aria-expanded", "false");
  }

  if (tocBtn) {
    tocBtn.addEventListener("click", function () {
      if (sideEl.classList.contains("is-open")) closeDrawer();
      else openDrawer();
    });
  }
  if (tocScrim) tocScrim.addEventListener("click", closeDrawer);
  if (sideEl) {
    sideEl.addEventListener("click", function (e) {
      var link = e.target.closest ? e.target.closest('a[href^="#l"]') : null;
      if (link) closeDrawer();
    });
  }
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") closeDrawer();
  });

  /* ---------------- 检索（只搜标题） ---------------- */

  var searchTimer = 0;

  function filter() {
    if (!searchEl) return;
    var q = searchEl.value.trim().toLowerCase();
    var hits = 0;

    tocItems.forEach(function (item, i) {
      var link = tocLinks[i];
      var hit = !q || (link.dataset.search || "").indexOf(q) !== -1;
      item.hidden = !hit;
      if (hit) hits += 1;
    });

    if (emptyEl) emptyEl.hidden = hits !== 0;
    if (countEl && q) countEl.textContent = "匹配 " + hits + " 课";
    else if (countEl && current) countEl.textContent = "第 " + current + " / " + TOTAL + " 课";
  }

  function syncSearchClear() {
    if (searchClear && searchEl) searchClear.hidden = !searchEl.value;
  }

  if (searchEl) {
    searchEl.addEventListener("input", function () {
      syncSearchClear();
      window.clearTimeout(searchTimer);
      searchTimer = window.setTimeout(filter, 120);
    });
    searchEl.addEventListener("keydown", function (e) {
      if (e.key === "Enter") {
        var first = tocItems.filter(function (item) {
          return !item.hidden;
        })[0];
        if (first) {
          var no = Number(first.querySelector("a").dataset.no);
          go(no, { scroll: true });
        }
      }
    });
    syncSearchClear();
  }

  if (searchClear) {
    searchClear.addEventListener("click", function () {
      if (!searchEl) return;
      searchEl.value = "";
      syncSearchClear();
      window.clearTimeout(searchTimer);
      filter();
      searchEl.focus();
    });
  }

  // 点搜索框空白处 / 放大镜都聚焦到输入框
  if (searchBox && searchEl) {
    searchBox.addEventListener("click", function (e) {
      if (e.target === searchClear || e.target === searchEl) return;
      searchEl.focus();
    });
  }

  /* ---------------- 键盘翻页 ---------------- */

  document.addEventListener("keydown", function (e) {
    var tag = (e.target.tagName || "").toLowerCase();
    if (tag === "input" || tag === "textarea" || tag === "select") return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "ArrowRight") {
      e.preventDefault();
      go(Math.min(current + 1, TOTAL), { scroll: true });
    } else if (e.key === "ArrowLeft") {
      e.preventDefault();
      go(Math.max(current - 1, 1), { scroll: true });
    }
  });

  if (prevBtn) {
    prevBtn.addEventListener("click", function () {
      go(Math.max(current - 1, 1), { scroll: true });
    });
  }
  if (nextBtn) {
    nextBtn.addEventListener("click", function () {
      go(Math.min(current + 1, TOTAL), { scroll: true });
    });
  }

  /* ---------------- 启动 ---------------- */

  var last = parseInt(load(LAST_KEY) || "0", 10);
  if (resumeBtn && last > 1) {
    resumeBtn.textContent = "继续上次：第 " + last + " 课";
    resumeBtn.setAttribute("href", "#l" + pad(last));
  }

  var initialHash = readHash();
  var start = initialHash || (last >= 1 ? last : 1);
  show(start, { instant: true });
  scrollToTop(false);
})();
