/* 交易复盘：读「交易练习」的本机/云端账户历史，逐笔平仓记录写复盘。
   阶段划分：重置资金（重置一次就开一个新阶段）为分界点。 */
(function () {
  "use strict";

  var listEl = document.getElementById("reviewList");
  var listEmpty = document.getElementById("reviewListEmpty");
  var countEl = document.getElementById("reviewCount");
  var infoEl = document.getElementById("reviewInfo");
  var bodyEl = document.getElementById("reviewBody");
  var hintEl = document.getElementById("reviewHint");
  var savedEl = document.getElementById("reviewSaved");
  var exportBtn = document.getElementById("reviewExport");
  var statsEl = document.getElementById("reviewStats");
  var stageSub = document.getElementById("reviewStageSub");
  var canvas = document.getElementById("reviewChart");
  var refreshBtn = document.getElementById("reviewRefresh");
  var lightbox = document.getElementById("reviewLightbox");
  var lightboxImg = document.getElementById("reviewLightboxImg");
  var printEl = document.getElementById("reviewPrint");
  var yearSelect = document.getElementById("reviewYear");

  if (!listEl || !bodyEl) return;

  var LS_GUEST = "huideng.trade.guest";
  var LS_CACHE = "huideng.trade.cache";
  var LS_REVIEWS = "huideng.trade.reviews";
  var LS_RESETS = "huideng.trade.resets";
  var DEFAULT_CAPITAL = 100000;

  var records = []; // 时间正序
  var resets = []; // [{at, amount}]，每次重置资金一条
  var reviews = {};
  var selectedId = "";
  var baseCapital = DEFAULT_CAPITAL;
  var chartMode = "stage";
  var saveTimer = 0;
  var savedTimer = 0;
  var autoTimer = 0;
  var dirty = false;
  var AUTOSAVE_MS = 60000;

  function currentUser() {
    try {
      var u = JSON.parse(window.localStorage.getItem("huideng.trade.user") || "null");
      if (u && u.username) return String(u.username);
    } catch (e) {}
    var cache = readJSON("huideng.trade.cache");
    if (cache && cache.u) return String(cache.u);
    return "本机账户";
  }

  function safeName(name) {
    return String(name || "交易复盘").replace(/[\\/:*?"<>|\s]+/g, "_").slice(0, 40);
  }

  function readJSON(key) {
    try {
      return JSON.parse(window.localStorage.getItem(key) || "null");
    } catch (e) {
      return null;
    }
  }

  function writeJSON(key, value) {
    try {
      window.localStorage.setItem(key, JSON.stringify(value));
    } catch (e) {
      /* 存不了就只留在内存里 */
    }
  }

  function num(v) {
    return typeof v === "number" && isFinite(v) ? v : 0;
  }

  function fmtAbs(v) {
    return Math.abs(num(v)).toLocaleString("zh-CN", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
  }

  function fmtMoney(v) {
    var s = Math.abs(v).toLocaleString("zh-CN", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
    return (v > 0 ? "+" : v < 0 ? "-" : "") + s;
  }

  function fmtMoneyPlain(v) {
    return num(v).toLocaleString("zh-CN", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
  }

  function fmtPct(v) {
    return (v > 0 ? "+" : v < 0 ? "-" : "") + Math.abs(v).toFixed(2) + "%";
  }

  function fmtPrice(v) {
    if (!v) return "--";
    return v.toLocaleString("zh-CN", { maximumFractionDigits: 2 });
  }

  function pad2(n) {
    return (n < 10 ? "0" : "") + n;
  }

  function fmtDate(at) {
    if (!at) return "--";
    var d = new Date(at);
    return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate());
  }

  function fmtTime(at) {
    if (!at) return "--";
    var d = new Date(at);
    return pad2(d.getHours()) + ":" + pad2(d.getMinutes());
  }

  function fmtDateTime(at) {
    if (!at) return "--";
    return fmtDate(at) + " " + fmtTime(at);
  }

  function axisMoney(v, span) {
    span = span || 0;
    if (span >= 200000) return (v / 1000).toFixed(0) + "k";
    if (span >= 20000) return (v / 1000).toFixed(1) + "k";
    return Math.round(v).toLocaleString("zh-CN");
  }

  function axisTime(at) {
    if (!at) return "";
    var d = new Date(at);
    return pad2(d.getMonth() + 1) + "-" + pad2(d.getDate()) + " " + pad2(d.getHours()) + ":" + pad2(d.getMinutes());
  }

  function pnlClass(v) {
    return v > 0 ? "is-up" : v < 0 ? "is-down" : "";
  }

  function loadAccount() {
    var guest = readJSON(LS_GUEST);
    var cache = readJSON(LS_CACHE);
    var guestHist = (guest && guest.history) || [];
    var cacheHist = (cache && cache.data && cache.data.history) || [];
    if (cacheHist.length > guestHist.length) return cache.data;
    if (guest) return guest;
    return null;
  }

  function loadResets() {
    var list = readJSON(LS_RESETS) || [];
    if (!Array.isArray(list)) return [];
    return list
      .filter(function (r) {
        return r && Number.isFinite(+r.at);
      })
      .map(function (r) {
        return { at: +r.at, amount: +r.amount || 0 };
      })
      .sort(function (a, b) {
        return a.at - b.at;
      });
  }

  function stageStartCapital(stage) {
    if (stage > 0) {
      var r = resets[stage - 1];
      if (r && r.amount > 0) return r.amount;
    }
    return baseCapital;
  }

  function buildRecords(account) {
    var hist = (account && account.history) || [];
    baseCapital = num(account && account.baseCash) || DEFAULT_CAPITAL;
    resets = loadResets();

    var opens = {};
    hist.forEach(function (h) {
      if (h && h.type === "open" && h.posId) opens[h.posId] = h;
    });
    var list = [];
    hist.forEach(function (h) {
      if (!h || (h.type !== "close" && h.type !== "liquidated")) return;
      var open = opens[h.posId];
      list.push({
        id: h.id || String(h.at) + "-" + list.length,
        at: h.at || 0,
        side: h.side === "short" ? "short" : "long",
        qty: num(h.qty),
        entry: open ? num(open.price) : 0,
        openAt: open ? num(open.at) : 0,
        exit: num(h.price),
        pnl: num(h.pnl),
        fee: num(h.fee),
        liquidated: h.type === "liquidated",
      });
    });
    list.sort(function (a, b) {
      return a.at - b.at;
    });

    // 按重置资金分阶段，再在阶段内递推余额
    var running = {};
    var lastAt = {};
    list.forEach(function (r) {
      var stage = 0;
      for (var i = 0; i < resets.length; i++) {
        if (resets[i].at <= r.at) stage = i + 1;
      }
      r.stage = stage;
      if (running[stage] == null) running[stage] = stageStartCapital(stage);
      r.before = running[stage];
      r.after = r.before + r.pnl;
      r.pct = r.before ? (r.pnl / r.before) * 100 : 0;
      r.periodDays = lastAt[stage] ? (r.at - lastAt[stage]) / 86400000 : 0;
      lastAt[stage] = r.at;
      running[stage] = r.after;
    });
    return list;
  }

  function currentStage() {
    // 阶段号 = 重置次数：刚重置完还没交易时，当前阶段就是空的
    return resets.length;
  }

  function stageRecords(stage) {
    return records.filter(function (r) {
      return r.stage === stage;
    });
  }

  /* ------------------------------ 左：历史记录 ------------------------------ */

  function renderList() {
    listEl.innerHTML = "";
    if (countEl) countEl.textContent = records.length + " 笔";
    listEmpty.hidden = records.length !== 0;
    var events = [];
    records.forEach(function (r) {
      events.push({ kind: "trade", at: r.at, r: r });
    });
    resets.forEach(function (rs) {
      events.push({ kind: "reset", at: rs.at, amount: rs.amount });
    });
    events.sort(function (a, b) {
      return b.at - a.at;
    });

    events.forEach(function (ev) {
      if (ev.kind === "reset") {
        var row = document.createElement("div");
        row.className = "review-reset";
        row.innerHTML =
          "<span>重置资金</span><b>" +
          fmtMoneyPlain(ev.amount) +
          "</b><span>" +
          fmtDateTime(ev.at) +
          "</span>";
        listEl.appendChild(row);
        return;
      }
        var r = ev.r;
        var btn = document.createElement("button");
        btn.type = "button";
        btn.className = "review-record" + (r.id === selectedId ? " is-on" : "");
        btn.setAttribute("data-id", r.id);
        var reviewed = !!reviewHtml(r);
        btn.innerHTML =
          '<div class="review-record__top">' +
          '<span class="review-record__side ' +
          (r.side === "long" ? "is-long" : "is-short") +
          '">' +
          (r.side === "long" ? "多" : "空") +
          "</span>" +
          '<span class="review-record__pnl ' +
          pnlClass(r.pnl) +
          '">' +
          fmtAbs(r.pnl) +
          "</span>" +
          '<span class="review-record__pct ' +
          pnlClass(r.pnl) +
          '"><em>收益率：</em>' +
          fmtPct(r.pct) +
          "</span>" +
          "</div>" +
          '<div class="review-record__sub">' +
          '<span class="review-record__hold">持仓 ' +
          periodText(r.openAt ? (r.at - r.openAt) / 86400000 : 0) +
          "</span>" +
          '<span class="review-record__time">' +
          fmtDateTime(r.at) +
          "</span>" +
          (reviewed ? '<i class="review-record__dot" title="已复盘"></i>' : "") +
          "</div>";
        listEl.appendChild(btn);
      });
  }

  function selectedRecord() {
    for (var i = 0; i < records.length; i++) {
      if (records[i].id === selectedId) return records[i];
    }
    return null;
  }

  function periodText(days) {
    if (!days) return "-";
    if (days < 1 / 24) return Math.max(1, Math.round(days * 1440)) + " 分钟";
    if (days < 1) return Math.round(days * 24) + " 小时";
    return Math.round(days) + " 天";
  }

  function renderInfo(r) {
    if (!r) {
      infoEl.hidden = true;
      return;
    }
    infoEl.hidden = false;
    var saved = reviews[r.id];
    infoEl.innerHTML =
      '<div class="review-info__grid">' +
      item("初始余额", fmtMoneyPlain(r.before)) +
      item("开仓时间", fmtDateTime(r.openAt)) +
      item("平仓时间", fmtDateTime(r.at)) +
      item("复盘时间", saved && saved.at ? fmtDateTime(saved.at) : "--") +
      item("开仓价位", fmtPrice(r.entry)) +
      item("平仓价位", fmtPrice(r.exit)) +
      "</div>";
  }

  function item(label, value, cls) {
    return (
      '<span class="review-info__item"><i>' +
      label +
      "</i><b" +
      (cls ? ' class="' + cls + '"' : "") +
      ">" +
      value +
      "</b></span>"
    );
  }

  /* ------------------------------ 中：复盘编辑 ------------------------------ */

  function textToHtml(text) {
    if (!text) return "";
    return String(text)
      .split(/\n/)
      .map(function (line) {
        return line ? escapeHtml(line) : "";
      })
      .join("<br>");
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function reviewHtml(r) {
    var saved = reviews[r.id];
    if (!saved) return "";
    if (saved.html != null) return saved.html;
    return textToHtml(saved.text);
  }

  function hasReviewContent() {
    if (bodyEl.querySelector("img")) return true;
    return !!bodyEl.textContent.replace(/\u200b/g, "").trim();
  }

  /** 手动/定时保存；返回是否真的写了东西 */
  function saveReview() {
    var r = selectedRecord();
    if (!r) return false;
    var html = hasReviewContent() ? bodyEl.innerHTML : "";
    reviews[r.id] = { html: html, at: Date.now() };
    writeJSON(LS_REVIEWS, reviews);
    dirty = false;
    window.clearTimeout(autoTimer);
    autoTimer = 0;
    savedEl.hidden = false;
    window.clearTimeout(savedTimer);
    savedTimer = window.setTimeout(function () {
      savedEl.hidden = true;
    }, 1800);
    renderList();
    renderInfo(r);
    return true;
  }

  /** 输入后一分钟保存一次；不在每次输入时重置计时 */
  function markDirty() {
    dirty = true;
    if (autoTimer) return;
    autoTimer = window.setTimeout(function () {
      autoTimer = 0;
      if (dirty) saveReview();
    }, AUTOSAVE_MS);
  }

  function select(id) {
    if (dirty) saveReview();
    selectedId = id;
    var r = selectedRecord();
    renderList();
    renderInfo(r);
    renderStats(r ? currentStage() : -1);
    drawChart(r);
    if (!r) {
      bodyEl.setAttribute("contenteditable", "false");
      bodyEl.innerHTML = "";
      hintEl.hidden = false;
      return;
    }
    hintEl.hidden = true;
    bodyEl.setAttribute("contenteditable", "true");
    bodyEl.innerHTML = reviewHtml(r);
    // 光标放到末尾：接着写、直接粘贴图片都从后面来
    try {
      var range = document.createRange();
      range.selectNodeContents(bodyEl);
      range.collapse(false);
      var sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    } catch (e) {}
  }

  /* ------------------------------ 图片压缩 / 粘贴 ------------------------------ */

  function compressImage(file) {
    return new Promise(function (resolve) {
      var url = URL.createObjectURL(file);
      var img = new Image();
      img.onload = function () {
        var maxSide = 1280;
        var w = img.naturalWidth || img.width;
        var h = img.naturalHeight || img.height;
        var scale = Math.min(1, maxSide / Math.max(w, h));
        var cw = Math.max(1, Math.round(w * scale));
        var ch = Math.max(1, Math.round(h * scale));
        var c = document.createElement("canvas");
        c.width = cw;
        c.height = ch;
        var ctx = c.getContext("2d");
        // 透明 PNG 转 JPEG 会变黑，先铺一层纸色
        ctx.fillStyle = "#f7f1e3";
        ctx.fillRect(0, 0, cw, ch);
        ctx.drawImage(img, 0, 0, cw, ch);
        URL.revokeObjectURL(url);

        var q = 0.72;
        var data = c.toDataURL("image/jpeg", q);
        var bytes = Math.round((data.length - 23) * 0.75);
        while (bytes > 180 * 1024 && q > 0.42) {
          q -= 0.08;
          data = c.toDataURL("image/jpeg", q);
          bytes = Math.round((data.length - 23) * 0.75);
        }
        resolve(data);
      };
      img.onerror = function () {
        URL.revokeObjectURL(url);
        resolve("");
      };
      img.src = url;
    });
  }

  function insertImage(src) {
    if (!src) return;
    bodyEl.focus();
    var img = document.createElement("img");
    img.src = src;
    img.alt = "粘贴的图片";
    var sel = window.getSelection();
    if (sel && sel.rangeCount && bodyEl.contains(sel.anchorNode)) {
      var range = sel.getRangeAt(0);
      range.deleteContents();
      range.insertNode(img);
      range.setStartAfter(img);
      range.collapse(true);
      sel.removeAllRanges();
      sel.addRange(range);
    } else {
      bodyEl.appendChild(img);
    }
    markDirty();
  }

  /* ------------------------------ 大图 ------------------------------ */

  function openLightbox(src) {
    if (!lightbox || !lightboxImg || !src) return;
    lightboxImg.src = src;
    lightbox.hidden = false;
  }

  function closeLightbox() {
    if (!lightbox) return;
    lightbox.hidden = true;
    if (lightboxImg) lightboxImg.removeAttribute("src");
  }

  /* ------------------------------ 右：曲线 + 统计 ------------------------------ */

  function stageSeries(stage) {
    var list = stageRecords(stage);
    return {
      list: list,
      start: stageStartCapital(stage),
      values: [stageStartCapital(stage)].concat(
        list.map(function (r) {
          return r.after;
        })
      ),
    };
  }

  function chartSeries(record) {
    if (!record) return null;
    if (chartMode === "all") {
      return {
        values: [baseCapital].concat(
          records.map(function (r) {
            return r.after;
          })
        ),
        start: baseCapital,
        list: records,
        index: records.indexOf(record),
      };
    }
    // 阶段图固定看「当前阶段」：最近一次重置资金之后
    var series = stageSeries(currentStage());
    return {
      values: series.values,
      start: series.start,
      list: series.list,
      index: record.stage === currentStage() ? series.list.indexOf(record) : -1,
    };
  }

  function drawChart(record) {
    if (!canvas) return;
    var rect = canvas.getBoundingClientRect();
    var w = Math.max(1, Math.round(rect.width));
    var h = Math.max(1, Math.round(rect.height));
    var dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    var ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    if (!record) return;

    var series = chartSeries(record);
    var values = series.values;
    var padL = 54;
    var padR = 10;
    var padT = 12;
    var padB = 24;
    var innerW = Math.max(1, w - padL - padR);
    var innerH = Math.max(1, h - padT - padB);

    var min = Math.min.apply(null, values);
    var max = Math.max.apply(null, values);
    if (max - min < 1) {
      min -= 1;
      max += 1;
    }
    var span = max - min;
    min -= span * 0.12;
    max += span * 0.12;

    function px(i) {
      if (values.length <= 1) return padL;
      return padL + (innerW * i) / (values.length - 1);
    }
    function py(v) {
      return padT + innerH - ((v - min) / (max - min)) * innerH;
    }

    var times = [series.list.length ? series.list[0].at : 0].concat(
      series.list.map(function (r) {
        return r.at;
      })
    );

    // 纵坐标：余额刻度 + 横向网格
    ctx.font = "10px -apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif";
    var steps = 4;
    for (var gy = 0; gy <= steps; gy++) {
      var gv = min + ((max - min) * gy) / steps;
      var yy = py(gv);
      ctx.strokeStyle = "rgba(36, 31, 22, 0.06)";
      ctx.beginPath();
      ctx.moveTo(padL, yy);
      ctx.lineTo(w - padR, yy);
      ctx.stroke();
      ctx.fillStyle = "rgba(107, 98, 80, 0.85)";
      // 纵坐标靠左写，和下面那排数据指标的左边界对齐
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      ctx.fillText(axisMoney(gv, max - min), 4, yy);
    }

    // 横坐标：时间刻度
    var xTickIdx =
      values.length > 3 && innerW >= 320
        ? [0, Math.floor((values.length - 1) / 2), values.length - 1]
        : [0, values.length - 1];
    xTickIdx.forEach(function (ti) {
      var tx = px(ti);
      var align = ti === 0 ? "left" : ti === values.length - 1 ? "right" : "center";
      ctx.fillStyle = "rgba(107, 98, 80, 0.85)";
      ctx.textBaseline = "top";
      ctx.textAlign = align;
      ctx.fillText(axisTime(times[ti]), tx, padT + innerH + 6);
    });

    // 阶段起始本金基线
    var baseY = py(series.start);
    ctx.save();
    ctx.strokeStyle = "rgba(36, 31, 22, 0.14)";
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    ctx.moveTo(padL, baseY);
    ctx.lineTo(w - padR, baseY);
    ctx.stroke();
    ctx.restore();

    if (chartMode !== "all") {
      // 阶段图只留这条虚线，不写字
    } else {
      // 全周期图：每次重置资金画一条竖虚线，标出阶段分界（只画线，不写字）
      resets.forEach(function (rs) {
        var hit = -1;
        for (var q = 0; q < records.length; q++) {
          if (records[q].at >= rs.at) {
            hit = q;
            break;
          }
        }
        if (hit < 0) return;
        var rx = px(hit + 1);
        ctx.save();
        ctx.strokeStyle = "rgba(107, 98, 80, 0.45)";
        ctx.setLineDash([3, 3]);
        ctx.beginPath();
        ctx.moveTo(rx, padT);
        ctx.lineTo(rx, padT + innerH);
        ctx.stroke();
        ctx.restore();
      });
    }

    ctx.beginPath();
    ctx.moveTo(px(0), py(values[0]));
    for (var i = 1; i < values.length; i++) ctx.lineTo(px(i), py(values[i]));
    ctx.lineTo(px(values.length - 1), padT + innerH);
    ctx.lineTo(px(0), padT + innerH);
    ctx.closePath();
    var grad = ctx.createLinearGradient(0, padT, 0, padT + innerH);
    grad.addColorStop(0, "rgba(48, 92, 56, 0.18)");
    grad.addColorStop(1, "rgba(48, 92, 56, 0.01)");
    ctx.fillStyle = grad;
    ctx.fill();

    ctx.beginPath();
    ctx.moveTo(px(0), py(values[0]));
    for (var j = 1; j < values.length; j++) ctx.lineTo(px(j), py(values[j]));
    ctx.strokeStyle = "#305C38";
    ctx.lineWidth = 1.6;
    ctx.lineJoin = "round";
    ctx.stroke();

    // 每个交易点一个小圆
    for (var k = 0; k < series.list.length; k++) {
      var dr = series.list[k];
      ctx.beginPath();
      ctx.arc(px(k + 1), py(values[k + 1]), 2, 0, Math.PI * 2);
      ctx.fillStyle = dr.pnl >= 0 ? "#7E1319" : "#305C38";
      ctx.globalAlpha = 0.7;
      ctx.fill();
      ctx.globalAlpha = 1;
    }

    if (!series.list.length) {
      ctx.fillStyle = "rgba(107, 98, 80, 0.75)";
      ctx.font = "11px -apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText("暂无交易", padL + innerW / 2, padT + innerH / 2);
    }

    var idx = series.index;
    if (idx >= 0) {
      var cx = px(idx + 1);
      var cy = py(values[idx + 1]);
      ctx.beginPath();
      ctx.arc(cx, cy, 5.5, 0, Math.PI * 2);
      ctx.fillStyle = record.pnl >= 0 ? "#7E1319" : "#305C38";
      ctx.globalAlpha = 0.18;
      ctx.fill();
      ctx.globalAlpha = 1;
      ctx.beginPath();
      ctx.arc(cx, cy, 3, 0, Math.PI * 2);
      ctx.fillStyle = record.pnl >= 0 ? "#7E1319" : "#305C38";
      ctx.fill();
    }

  }

  function computeStats(stage) {
    var list = stageRecords(stage);
    var n = list.length;
    if (!n) return null;
    var wins = 0;
    var gross = 0;
    var loss = 0;
    var profitRates = [];
    var lossRates = [];
    list.forEach(function (r) {
      if (r.pnl > 0) {
        wins += 1;
        gross += r.pnl;
        profitRates.push(r.pct);
      } else if (r.pnl < 0) {
        loss += -r.pnl;
        lossRates.push(Math.abs(r.pct));
      }
    });
    var avgProfit = profitRates.length ? gross / profitRates.length : 0;
    var avgLoss = lossRates.length ? loss / lossRates.length : 0;
    var winRate = (wins / n) * 100;
    var startBalance = stageStartCapital(stage);
    var endBalance = list[n - 1].after;
    var returnRate = startBalance ? ((endBalance - startBalance) / startBalance) * 100 : 0;
    var days = Math.max(1, Math.ceil((list[n - 1].at - list[0].at) / 86400000));
    var annualized = 0;
    if (returnRate !== 0 && days > 0) {
      annualized = (Math.pow(1 + returnRate / 100, 365 / days) - 1) * 100;
    }
    var monthly = 0;
    if (annualized !== 0) {
      monthly = (Math.pow(1 + annualized / 100, 1 / 12) - 1) * 100;
    }
    var peak = startBalance;
    var maxDrawdown = 0;
    [startBalance]
      .concat(
        list.map(function (r) {
          return r.after;
        })
      )
      .forEach(function (b) {
        if (b > peak) peak = b;
        var dd = peak ? ((peak - b) / peak) * 100 : 0;
        if (dd > maxDrawdown) maxDrawdown = dd;
      });

    return {
      count: n,
      winRate: winRate,
      returnRate: returnRate,
      ratio: avgLoss > 0 ? avgProfit / avgLoss : 0,
      maxDrawdown: maxDrawdown,
      expectancy: (winRate / 100) * avgProfit - ((100 - winRate) / 100) * avgLoss,
      avgProfitRate: profitRates.length
        ? profitRates.reduce(function (a, b) {
            return a + b;
          }, 0) / profitRates.length
        : 0,
      avgLossRate: lossRates.length
        ? lossRates.reduce(function (a, b) {
            return a + b;
          }, 0) / lossRates.length
        : 0,
      annualized: annualized,
      monthly: monthly,
      days: days,
      startBalance: startBalance,
      endBalance: endBalance,
      startDate: fmtDate(list[0].at),
    };
  }

  function emptyItems() {
    return [
      "起始日期",
      "初始本金",
      "期末余额",
      "持续天数",
      "阶段收益率",
      "胜率",
      "盈亏比",
      "最大回撤",
      "期望值",
      "平均收益率",
      "平均亏损率",
      "年化拟合",
      "月化拟合",
      "交易笔数",
    ].map(function (label) {
      return { label: label, value: "暂无", cls: "" };
    });
  }

  function renderStats(stage) {
    var s = computeStats(stage);
    statsEl.innerHTML = "";
    if (stageSub) {
      stageSub.textContent =
        stage >= 0
          ? "第 " + (stage + 1) + " 阶段" + (s ? " · 起始 " + s.startDate : "")
          : "";
    }
    var items;
    if (!s) {
      items = emptyItems();
    } else {
      items = [
      { label: "起始日期", value: s.startDate, cls: "" },
      { label: "初始本金", value: fmtMoneyPlain(s.startBalance), cls: "" },
      { label: "期末余额", value: fmtMoneyPlain(s.endBalance), cls: "" },
      { label: "持续天数", value: s.days + " 天", cls: "" },
      { label: "阶段收益率", value: fmtPct(s.returnRate), cls: pnlClass(s.returnRate) },
      { label: "胜率", value: s.winRate.toFixed(2) + "%", cls: "" },
      { label: "盈亏比", value: s.ratio.toFixed(2), cls: "" },
      { label: "最大回撤", value: s.maxDrawdown.toFixed(2) + "%", cls: "is-down" },
      { label: "期望值", value: fmtMoney(s.expectancy), cls: pnlClass(s.expectancy) },
      { label: "平均收益率", value: fmtPct(s.avgProfitRate), cls: "is-up" },
      { label: "平均亏损率", value: fmtPct(-s.avgLossRate), cls: "is-down" },
      { label: "年化拟合", value: fmtPct(s.annualized), cls: pnlClass(s.annualized) },
      { label: "月化拟合", value: fmtPct(s.monthly), cls: pnlClass(s.monthly) },
      { label: "交易笔数", value: String(s.count), cls: "" },
      ];
    }
    items.forEach(function (it) {
      var d = document.createElement("div");
      d.className = "review-stat";
      d.innerHTML =
        '<div class="review-stat__label">' +
        it.label +
        '</div><div class="review-stat__value ' +
        it.cls +
        '">' +
        it.value +
        "</div>";
      statsEl.appendChild(d);
    });
  }

  function exportPdf() {
    if (!records.length || !printEl) return;
    if (dirty) saveReview();
    var year = yearSelect && !yearSelect.hidden ? +yearSelect.value || 0 : 0;
    var list = year
      ? records.filter(function (r) {
          return new Date(r.at).getFullYear() === year;
        })
      : records;
    if (!list.length) return;

    var parts = ["<h1>交易复盘</h1>"];
    parts.push(
      '<p class="print-meta">' +
        (year ? year + " 年 · " : "") +
        "导出时间 " +
        fmtDateTime(Date.now()) +
        " · 共 " +
        list.length +
        " 笔平仓</p>"
    );
    list
      .slice()
      .reverse()
      .forEach(function (r, i) {
        parts.push("<section>");
        parts.push(
          "<h2>[" +
            (i + 1) +
            "] " +
            fmtDateTime(r.at) +
            " · " +
            (r.side === "long" ? "多" : "空") +
            " · 盈亏 " +
            fmtMoney(r.pnl) +
            " USDT（" +
            fmtPct(r.pct) +
            "）</h2>"
        );
        parts.push(
          '<p class="print-line">开仓 ' +
            fmtPrice(r.entry) +
            " · 平仓 " +
            fmtPrice(r.exit) +
            " · 数量 " +
            r.qty +
            " BTC · 持仓 " +
            periodText(r.openAt ? (r.at - r.openAt) / 86400000 : 0) +
            "</p>"
        );
        var html = reviewHtml(r);
        parts.push(
          '<div class="print-review">' +
            (html || '<p class="print-line">（未写复盘）</p>') +
            "</div>"
        );
        parts.push("</section>");
      });
    printEl.innerHTML = parts.join("");

    // 打印对话框里的默认文件名取自 document.title
    var fileName =
      safeName(currentUser()) +
      "-交易复盘" +
      (year ? "-" + year : "-" + fmtDate(Date.now()));
    var prevTitle = document.title;
    var prevTop = null;
    document.title = fileName;
    try {
      if (window.top && window.top !== window && window.top.document) {
        prevTop = window.top.document.title;
        window.top.document.title = fileName;
      }
    } catch (e) {}

    function restoreTitle() {
      document.title = prevTitle;
      try {
        if (prevTop != null) window.top.document.title = prevTop;
      } catch (e) {}
    }
    window.addEventListener("afterprint", restoreTitle, { once: true });
    window.print();
    window.setTimeout(restoreTitle, 20000);
  }

  listEl.addEventListener("click", function (e) {
    var btn = e.target.closest ? e.target.closest(".review-record") : null;
    if (!btn) return;
    select(btn.getAttribute("data-id"));
  });

  bodyEl.addEventListener("input", markDirty);

  bodyEl.addEventListener("paste", function (e) {
    var cd = e.clipboardData || window.clipboardData;
    if (!cd || !cd.items) return;
    for (var i = 0; i < cd.items.length; i++) {
      var it = cd.items[i];
      if (it && it.type && it.type.indexOf("image/") === 0) {
        e.preventDefault();
        var file = it.getAsFile();
        if (!file) return;
        compressImage(file).then(function (dataUrl) {
          insertImage(dataUrl);
        });
        return;
      }
    }
  });

  bodyEl.addEventListener("click", function (e) {
    var img = e.target;
    if (img && img.tagName === "IMG" && img.getAttribute("src")) {
      e.preventDefault();
      openLightbox(img.getAttribute("src"));
    }
  });

  if (lightbox) lightbox.addEventListener("click", closeLightbox);

  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") closeLightbox();
    if ((e.ctrlKey || e.metaKey) && String(e.key).toLowerCase() === "s") {
      e.preventDefault();
      var r = selectedRecord();
      if (r && bodyEl.getAttribute("contenteditable") === "true") saveReview();
    }
  });

  if (exportBtn) exportBtn.addEventListener("click", exportPdf);
  if (refreshBtn) refreshBtn.addEventListener("click", refreshAll);

  var switchEl = document.querySelector(".review-chart-switch");
  if (switchEl) {
    switchEl.addEventListener("click", function (e) {
      var b = e.target.closest ? e.target.closest("button[data-mode]") : null;
      if (!b) return;
      Array.prototype.forEach.call(switchEl.querySelectorAll("button"), function (x) {
        x.classList.toggle("is-on", x === b);
      });
      chartMode = b.getAttribute("data-mode") || "stage";
      drawChart(selectedRecord());
    });
  }

  function renderYearSelect() {
    if (!yearSelect) return;
    var years = [];
    records.forEach(function (r) {
      var y = new Date(r.at).getFullYear();
      if (years.indexOf(y) < 0) years.push(y);
    });
    years.sort(function (a, b) {
      return b - a;
    });
    if (years.length <= 1) {
      yearSelect.hidden = true;
      yearSelect.innerHTML = "";
      return;
    }
    var keep = +yearSelect.value;
    yearSelect.innerHTML = years
      .map(function (y) {
        return '<option value="' + y + '">' + y + " 年</option>";
      })
      .join("");
    if (years.indexOf(keep) >= 0) yearSelect.value = String(keep);
    yearSelect.hidden = false;
  }

  function refreshAll() {
    if (dirty) saveReview();
    var keep = selectedId;
    reviews = readJSON(LS_REVIEWS) || {};
    if (typeof reviews !== "object" || Array.isArray(reviews)) reviews = {};
    records = buildRecords(loadAccount());
    if (!records.length) {
      selectedId = "";
      renderList();
      renderInfo(null);
      renderStats(-1);
      drawChart(null);
      return;
    }
    renderYearSelect();
    var found = records.some(function (r) {
      return r.id === keep;
    });
    select(found ? keep : records[records.length - 1].id);
  }

  var resizeTimer = 0;
  window.addEventListener("resize", function () {
    window.clearTimeout(resizeTimer);
    resizeTimer = window.setTimeout(function () {
      drawChart(selectedRecord());
    }, 120);
  });

  // 启动
  reviews = readJSON(LS_REVIEWS) || {};
  if (typeof reviews !== "object" || Array.isArray(reviews)) reviews = {};
  records = buildRecords(loadAccount());
  renderYearSelect();
  if (records.length) select(records[records.length - 1].id);
  else {
    renderList();
    renderInfo(null);
    renderStats(-1);
    drawChart(null);
  }
})();
