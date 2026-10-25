/**
 * 模拟交易（纯记账，不碰真实资金）。
 *
 * 独立成文件是因为 index.js 已经 5000+ 行，交易这块自成一体：
 * 身份（网页注册/登录 → 会话 token）、账户、持仓、挂单、成交历史。
 *
 * 身份为什么不用 access token：
 *   resolveUid() 故意不认匿名身份（认了全站会串号），网页匿名调用拿不到 uid；
 *   而 CloudBase 自定义登录（ticket → access token）需要浏览器引入 JS SDK，
 *   还要处理 CORS。这里改用「自己的会话表」：登录成功发一个随机 token，
 *   后续请求带着它，服务端查表换回 uid。纯 fetch，零 SDK。
 *
 * 撮合为什么由客户端推动：
 *   云函数没有常驻定时器，限价单的触发只能靠客户端在价格更新时调 tradeSync。
 *   客户端上报的价格不可信，所以下面所有金额都在服务端重算，并对价格做限幅校验。
 *
 * 会计模型（1 倍逐仓，无杠杆）：
 *   开仓：冻结 margin = qty × entry → cash -= margin（模拟盘不收手续费，fee 恒为 0）
 *   平仓：cash += margin + pnl
 *     多头 pnl = (mark − entry) × qty
 *     空头 pnl = (entry − mark) × qty
 *   权益 equity = cash + Σ(margin + 浮动盈亏)，开平仓不改变权益，账自洽。
 *   空头亏损无上界，margin + pnl ≤ 0 即强平（返还 0），账户不会穿仓。
 */
const crypto = require("crypto");
const https = require("https");

/* 模拟交易，不收手续费：前端 trade.js 的 FEE 也是 0，两边必须一致。 */
const FEE_RATE = 0;
const INITIAL_CASH = 100000; // 初始虚拟资金 10 万 USDT
const MIN_NOTIONAL = 10; // 最小名义价值 10 USDT（对齐币安）
const MAX_QTY = 1000; // 单笔数量上限
const SESSION_TTL = 30 * 24 * 3600 * 1000; // 会话 30 天
const MAX_FILLS = 60; // 成交历史保留条数
const MAX_PRICE_DRIFT = 0.05; // 上报价与上次已知价的最大偏离
const RATE_WINDOW = 10 * 1000;
const RATE_MAX = 30;

const COLLECTIONS = [
  "tradeAccounts",
  "tradePositions",
  "tradeOrders",
  "tradeFills",
  "tradeSessions",
  "tradePhones",
  "tradePhoneCodes",
  "userAccounts",
];

function round(n, digits) {
  const f = Math.pow(10, digits);
  return Math.round(n * f) / f;
}

function roundQty(qty) {
  return round(qty, 6);
}

function roundPrice(p) {
  return round(p, 2);
}

function num(v) {
  const n = typeof v === "number" ? v : parseFloat(v);
  return Number.isFinite(n) ? n : NaN;
}

// 简易限流：进程内按 key 记录最近调用时间。冷启动会重置，但配合云函数自身的
// 调用配额已经够用，不额外引入依赖。
const rateBuckets = new Map();

function rateLimited(key) {
  const now = Date.now();
  let list = rateBuckets.get(key);
  if (!list) {
    list = [];
    rateBuckets.set(key, list);
  }
  // list[0] 是最新一次，最老的在末尾
  while (list.length && now - list[list.length - 1] > RATE_WINDOW) list.pop();
  if (rateBuckets.size > 5000) rateBuckets.clear();
  if (list.length >= RATE_MAX) return true;
  list.unshift(now);
  return false;
}

// 集合只在冷启动时探测一次：云函数实例会复用，没必要每次调用都 createCollection。
let collectionsEnsured = false;

module.exports = function createTrade(deps) {
  const db = deps.db;
  const ok = deps.ok;
  const fail = deps.fail;

  const accounts = () => db.collection("tradeAccounts");
  const positions = () => db.collection("tradePositions");
  const orders = () => db.collection("tradeOrders");
  const fills = () => db.collection("tradeFills");
  const sessions = () => db.collection("tradeSessions");

  async function ensureCollections() {
    if (collectionsEnsured) return;
    for (const name of COLLECTIONS) {
      try {
        await db.createCollection(name);
      } catch (e) {
        // 已存在或无权限都继续，真出错会在下面的读写里暴露。
      }
    }
    collectionsEnsured = true;
  }

  // ---------------- 会话 ----------------

  async function createSession(uid) {
    const token = crypto.randomBytes(24).toString("hex");
    await sessions().add({
      _id: token,
      uid,
      createdAt: Date.now(),
      expiresAt: Date.now() + SESSION_TTL,
    });
    return token;
  }

  async function resolveSession(token) {
    if (!token || typeof token !== "string" || token.length < 20) return null;
    const { data } = await sessions().doc(token).get();
    const s = data && data[0];
    if (!s) return null;
    if (s.expiresAt < Date.now()) {
      try {
        await sessions().doc(token).remove();
      } catch (e) {}
      return null;
    }
    return s;
  }

  // ---------------- 账户 ----------------

  async function getOrCreateAccount(uid) {
    const { data } = await accounts().doc(uid).get();
    if (data && data[0]) return data[0];
    // 约定：账户文档的 _id 就是 uid，读写都走 doc(uid)，避免 where 查询。
    const fresh = {
      uid,
      cash: INITIAL_CASH,
      lastPrice: 0,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    await accounts().doc(uid).set(fresh);
    return fresh;
  }

  async function snapshot(uid) {
    const [acc, pos, ord, fil] = await Promise.all([
      getOrCreateAccount(uid),
      positions().where({ uid }).limit(50).get(),
      orders().where({ uid }).limit(50).get(),
      fills().where({ uid }).orderBy("at", "desc").limit(MAX_FILLS).get(),
    ]);
    return {
      cash: round(acc.cash, 2),
      lastPrice: acc.lastPrice || 0,
      positions: (pos.data || []).map((p) => ({
        id: p._id,
        side: p.side,
        qty: p.qty,
        entry: p.entry,
        margin: p.margin,
        openFee: p.openFee,
        openedAt: p.createdAt,
      })),
      orders: (ord.data || []).map((o) => ({
        id: o._id,
        side: o.side,
        price: o.price,
        qty: o.qty,
        createdAt: o.createdAt,
      })),
      history: (fil.data || []).map((f) => ({
        id: f._id,
        type: f.type,
        side: f.side,
        qty: f.qty,
        price: f.price,
        fee: f.fee,
        pnl: f.pnl || 0,
        at: f.at,
      })),
    };
  }

  /**
   * 校验客户端上报的价格：必须是正数、在合理区间内，且与该账户上一次
   * 看到的价格偏离不超过 5%（第一次调用没有上次价格，只做区间校验）。
   * 距上次上报超过 30 秒就放宽——长时间没调用（切后台、断网）之后，
   * 市场本来就可能跳空，这时再卡 5% 会把正常操作挡在外面。
   * 返回 null 表示可用，否则返回错误码。
   */
  async function checkPrice(uid, price) {
    if (!Number.isFinite(price) || price <= 0) return "bad_price";
    if (price < 1000 || price > 10000000) return "bad_price";
    const { data } = await accounts().doc(uid).get();
    const acc = data && data[0];
    const last = acc && acc.lastPrice;
    const at = (acc && acc.lastPriceAt) || 0;
    const stale = Date.now() - at > 30000;
    if (last > 0 && !stale && Math.abs(price - last) / last > MAX_PRICE_DRIFT) {
      return "price_deviation";
    }
    try {
      await accounts().doc(uid).update({ lastPrice: price, lastPriceAt: Date.now(), updatedAt: Date.now() });
    } catch (e) {}
    return null;
  }

  async function touchAccount(uid, patch) {
    try {
      await accounts().doc(uid).update({ ...patch, updatedAt: Date.now() });
    } catch (e) {}
  }

  async function addFill(uid, entry) {
    const doc = { uid, at: Date.now(), fee: round(entry.fee, 6), pnl: round(entry.pnl || 0, 6) };
    const { id } = await fills().add({ ...doc, type: entry.type, side: entry.side, qty: entry.qty, price: entry.price });
    // 只保留最近 MAX_FILLS 条，超出的老记录直接删
    const { data } = await fills().where({ uid }).orderBy("at", "desc").limit(MAX_FILLS + 20).get();
    const all = data || [];
    for (let i = MAX_FILLS; i < all.length; i++) {
      try {
        await fills().doc(all[i]._id).remove();
      } catch (e) {}
    }
    return id;
  }

  /**
   * 开仓：kind='market' 直接用 price 成交；kind='limit' 挂单等 tradeSync 触发。
   */
  async function openPosition(uid, params, marketPrice) {
    const side = params.side === "short" ? "short" : "long";
    const qty = roundQty(num(params.qty));
    if (!Number.isFinite(qty) || qty <= 0 || qty > MAX_QTY) return fail("bad_qty");

    if (params.kind === "limit") {
      const price = roundPrice(num(params.price));
      if (!Number.isFinite(price) || price <= 0) return fail("bad_price");
      if (price * qty < MIN_NOTIONAL) return fail("min_notional");
      if (rateLimited("order:" + uid)) return fail("rate_limited");
      const { id } = await orders().add({ uid, side, price, qty, createdAt: Date.now() });
      return ok({ account: await snapshot(uid), pendingOrder: { id, side, price, qty } });
    }

    const price = roundPrice(num(params.price));
    if (!Number.isFinite(price) || price <= 0) return fail("bad_price");
    if (price * qty < MIN_NOTIONAL) return fail("min_notional");
    if (rateLimited("order:" + uid)) return fail("rate_limited");

    const fee = price * qty * FEE_RATE;
    const margin = price * qty;
    const acc = await getOrCreateAccount(uid);
    if (acc.cash < margin + fee) return fail("insufficient_balance");

    await accounts().doc(uid).update({
      cash: round(acc.cash - margin - fee, 6),
      updatedAt: Date.now(),
    });
    await positions().add({
      uid,
      side,
      qty,
      entry: price,
      margin,
      openFee: fee,
      createdAt: Date.now(),
    });
    await addFill(uid, { type: "open", side, qty, price, fee, pnl: 0 });
    return ok({ account: await snapshot(uid) });
  }

  /**
   * 平仓 / 强平。price 为 mark，liquidated=true 时不再扣手续费、返还 0。
   */
  async function closePosition(uid, pos, price, liquidated) {
    const pnl = pos.side === "short" ? (pos.entry - price) * pos.qty : (price - pos.entry) * pos.qty;
    const fee = liquidated ? 0 : price * pos.qty * FEE_RATE;
    let proceeds = pos.margin + pnl - fee;
    if (proceeds < 0) proceeds = 0; // 不穿仓
    const acc = await getOrCreateAccount(uid);
    await positions().doc(pos._id).remove();
    await accounts().doc(uid).update({
      cash: round(acc.cash + proceeds, 6),
      updatedAt: Date.now(),
    });
    await addFill(uid, {
      type: liquidated ? "liquidated" : "close",
      side: pos.side,
      qty: pos.qty,
      price,
      fee,
      pnl,
    });
    return proceeds;
  }

  /** 用当前价撮合该用户的挂单 + 检查是否触发强平。返回是否有变化。 */
  async function matchOrders(uid, price) {
    const [ordRes, posRes] = await Promise.all([
      orders().where({ uid }).limit(50).get(),
      positions().where({ uid }).limit(50).get(),
    ]);
    let changed = false;

    for (const o of ordRes.data || []) {
      const hit = o.side === "long" ? price <= o.price : price >= o.price;
      if (!hit) continue;
      // 成交价用市价（对挂单方更优），不要用挂单价假装成交。
      const fillPrice = roundPrice(price);
      const qty = o.qty;
      const fee = fillPrice * qty * FEE_RATE;
      const margin = fillPrice * qty;
      const acc = await getOrCreateAccount(uid);
      if (acc.cash < margin + fee) {
        // 资金不足：撤单而不是硬成交
        await orders().doc(o._id).remove();
        changed = true;
        continue;
      }
      await orders().doc(o._id).remove();
      await accounts().doc(uid).update({ cash: round(acc.cash - margin - fee, 6), updatedAt: Date.now() });
      await positions().add({ uid, side: o.side, qty, entry: fillPrice, margin, openFee: fee, createdAt: Date.now() });
      await addFill(uid, { type: "open", side: o.side, qty, price: fillPrice, fee, pnl: 0 });
      changed = true;
    }

    const posNow = await positions().where({ uid }).limit(50).get();
    for (const p of posNow.data || []) {
      const pnl = p.side === "short" ? (p.entry - price) * p.qty : (price - p.entry) * p.qty;
      if (p.margin + pnl > 0) continue;
      await closePosition(uid, p, price, true);
      changed = true;
    }
    return changed;
  }

  // ---------------- 认证（账号 + 密码） ----------------

  async function findAccount(usernameKey) {
    const { data } = await db
      .collection("userAccounts")
      .where({ usernameKey })
      .limit(1)
      .get();
    return data && data[0] ? data[0] : null;
  }

  function checkPassword(acc, password) {
    if (!acc.passwordHash) return false;
    try {
      return deps.hashPassword(password, acc.salt) === acc.passwordHash;
    } catch (e) {
      return false;
    }
  }

  // ---------------- 手机号：绑定 / 找回密码 ----------------
  //
  // 短信复用云开发自带的验证码服务（App 端 signInWithOtp 就是这一套），
  // 服务端拿发布密钥直接调它的 REST 接口，只用来证明「手机在你手上」：
  //   POST /auth/v1/verification        发码 -> verification_id
  //   POST /auth/v1/verification/verify 校验 -> verification_token
  // 手机号↔账号的对应关系自己存（tradePhones，_id 就是手机号），
  // 不建 CloudBase 用户，也不影响 App 那边的手机验证码登录。

  const AUTH_ENV = process.env.TCB_ENV || "randeng-d8gs968w22a3d98e8";
  // 发布密钥是发给浏览器的公开值（每个页面里都带着），写在这里不算泄密。
  const AUTH_KEY = process.env.CLOUDBASE_PUBLISHABLE_KEY ||
    "eyJhbGciOiJSUzI1NiIsImtpZCI6IjlkMWRjMzFlLWI0ZDAtNDQ4Yi1hNzZmLWIwY2M2M2Q4MTQ5OCJ9" +
    ".eyJpc3MiOiJodHRwczovL3JhbmRlbmctZDhnczk2OHcyMmEzZDk4ZTguYXAtc2hhbmdoYWkudGNiLWFwaS50" +
    "ZW5jZW50Y2xvdWRhcGkuY29tIiwic3ViIjoiYW5vbiIsImF1ZCI6InJhbmRlbmctZDhnczk2OHcyMmEzZDk4" +
    "ZTgiLCJleHAiOjQwODkyNDU0MTEsImlhdCI6MTc4NTU2MjIxMSwibm9uY2UiOiJYTmpVYVlTclJONi1ZVkk3" +
    "bUlOUXF3IiwiYXRfaGFzaCI6IlhOalVhWVNyUk42LVlWSTdtSU5RcXciLCJuYW1lIjoiQW5vbnltb3VzIiwi" +
    "c2NvcGUiOiJhbm9ueW1vdXMiLCJwcm9qZWN0X2lkIjoicmFuZGVuZy1kOGdzOTY4dzIyYTNkOThlOCIsIm1l" +
    "dGEiOnsicGxhdGZvcm0iOiJQdWJsaXNoYWJsZUtleSJ9LCJ1c2VyX3R5cGUiOiIiLCJjbGllbnRfdHlwZSI6" +
    "ImNsaWVudF91c2VyIiwiaXNfc3lzdGVtX2FkbWluIjpmYWxzZX0.hCs04BM4hFTqIcdf0SS7vgnIP9-Um4vvw" +
    "WLNzHlSTaEQ8QzAcaFoW2foDJE7ReiiOPYgnOXw75TcsdHIr6HsRMNgalCNGNmjxRv2WSK3dpgIe6wr65tNOn" +
    "5eTxWM-M-96hgNLpVksUDw46Ejq58rINjGl674DPw-FxeGc8EbngInBkJSN-6-XWwTCglGDTRdygeR70CQGw" +
    "buYjw8MYvFxAo190ENtSJcWZf9ZphlgIj52mMoQXqE1FsefSQEfSDjFyuh1RHSRkNVEbecmO98J8ybQjbkkt0" +
    "p905DoQucKpz_W6MvMwkDTeH3jnIwYguBs8G_j_jcXQtAguPGZ6ed8w";

  const CODE_TTL = 5 * 60 * 1000; // 验证码 5 分钟有效
  const CODE_TRIES = 5; // 同一条验证码最多试 5 次
  const SEND_GAP = 60 * 1000; // 同一手机号 60 秒一条
  const SEND_DAILY = 8; // 同一手机号 24 小时最多 8 条

  const phones = () => db.collection("tradePhones");
  const phoneCodes = () => db.collection("tradePhoneCodes");

  function authPost(path, body) {
    return new Promise((resolve) => {
      const payload = JSON.stringify(body || {});
      const req = https.request(
        {
          hostname: AUTH_ENV + ".api.tcloudbasegateway.com",
          path: path + "?client_id=" + encodeURIComponent(AUTH_ENV),
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Content-Length": Buffer.byteLength(payload),
            Authorization: "Bearer " + AUTH_KEY,
            "x-device-id": "web",
          },
        },
        (res) => {
          let raw = "";
          res.setEncoding("utf8");
          res.on("data", (c) => { raw += c; });
          res.on("end", () => {
            let json = null;
            try { json = JSON.parse(raw); } catch (e) {}
            resolve({ status: res.statusCode, json, raw });
          });
        }
      );
      req.on("error", (e) => resolve({ status: 0, json: null, raw: String(e && e.message) }));
      req.setTimeout(8000, () => {
        try { req.destroy(new Error("timeout")); } catch (e) {}
      });
      req.write(payload);
      req.end();
    });
  }

  /** 中国大陆手机号归一化：接受 138…、+86138…、86-138…，返回 {local, display}。 */
  function normalizePhone(raw) {
    let d = String(raw || "").replace(/[\s()\-]/g, "");
    if (d.startsWith("+86")) d = d.slice(3);
    else if (d.startsWith("86") && d.length === 13) d = d.slice(2);
    if (!/^1[3-9]\d{9}$/.test(d)) return null;
    return { local: d, display: d.slice(0, 3) + "****" + d.slice(7) };
  }

  function todayKey() {
    // 按北京时间切天，和国内用户直觉一致
    return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
  }

  function authField(json, key) {
    if (!json) return "";
    return String(json[key] || (json.data && json.data[key]) || "");
  }

  function verifyFailCode(res) {
    const text = authField(res.json, "error_description") + " " +
      authField(res.json, "message") + " " + String(res.raw || "");
    if (/过期|expired/i.test(text)) return "code_expired";
    if (/错误|不正确|invalid.*code|mismatch/i.test(text)) return "code_wrong";
    return "verify_failed";
  }

  /** 发一条验证码，返回 {ok:true,...} 或失败对象。 */
  async function sendCode(phone) {
    const res = await authPost("/auth/v1/verification", { phone_number: "+86 " + phone.local });
    const vid = authField(res.json, "verification_id");
    if (res.status !== 200 || !vid) return { error: "sms_failed", detail: String(res.raw || "").slice(0, 200) };
    return { verificationId: vid };
  }

  /** 校验验证码，成功返回 verified=true。 */
  async function checkCode(verificationId, code) {
    const res = await authPost("/auth/v1/verification/verify", {
      verification_id: verificationId,
      verification_code: code,
    });
    const token = authField(res.json, "verification_token");
    if (res.status === 200 && token) return { verified: true };
    return { verified: false, error: verifyFailCode(res) };
  }

  async function phoneCode(event, sessionUid) {
    const scene = event.scene === "reset" ? "reset" : "bind";
    const phone = normalizePhone(event.phone);
    if (!phone) return fail("invalid_phone");

    if (scene === "bind") {
      if (!sessionUid) return fail("unauthorized");
      const { data } = await phones().doc(phone.local).get();
      const owner = data && data[0];
      if (owner && owner.uid && owner.uid !== sessionUid) return fail("phone_taken");
    }

    const now = Date.now();
    const day = todayKey();
    const { data: prevData } = await phoneCodes().doc(phone.local).get();
    const prev = prevData && prevData[0];
    if (prev) {
      if (now - (prev.sentAt || 0) < SEND_GAP) return fail("too_frequent");
      if (prev.dayKey === day && (prev.dayCount || 0) >= SEND_DAILY) return fail("too_many");
    }

    const sent = await sendCode(phone);
    if (sent.error) {
      console.log("[trade] 发码失败", phone.display, sent.detail || "");
      return fail(sent.error);
    }

    await phoneCodes().doc(phone.local).set({
      phone: phone.local,
      scene,
      uid: scene === "bind" ? sessionUid : "",
      verificationId: sent.verificationId,
      sentAt: now,
      expiresAt: now + CODE_TTL,
      tries: 0,
      dayKey: day,
      dayCount: prev && prev.dayKey === day ? (prev.dayCount || 0) + 1 : 1,
      createdAt: (prev && prev.createdAt) || now,
    });

    return ok({ id: phone.local, display: phone.display, expiresIn: Math.round(CODE_TTL / 1000) });
  }

  async function phoneConfirm(event, sessionUid) {
    const scene = event.scene === "reset" ? "reset" : "bind";
    const id = String(event.id || "").trim();
    const code = String(event.code || "").trim();
    if (!/^1[3-9]\d{9}$/.test(id)) return fail("invalid_phone");
    if (!/^\d{4,8}$/.test(code)) return fail("code_wrong");

    const { data } = await phoneCodes().doc(id).get();
    const rec = data && data[0];
    if (!rec || rec.scene !== scene) return fail("code_expired");
    if ((rec.expiresAt || 0) < Date.now()) return fail("code_expired");
    if ((rec.tries || 0) >= CODE_TRIES) return fail("too_many");

    const checked = await checkCode(rec.verificationId, code);
    if (!checked.verified) {
      try {
        await phoneCodes().doc(id).update({ tries: (rec.tries || 0) + 1 });
      } catch (e) {}
      return fail(checked.error || "code_wrong");
    }

    if (scene === "bind") {
      if (!sessionUid) return fail("unauthorized");
      const { data: ownerData } = await phones().doc(id).get();
      const owner = ownerData && ownerData[0];
      if (owner && owner.uid && owner.uid !== sessionUid) return fail("phone_taken");

      const { data: accData } = await db
        .collection("userAccounts")
        .where({ uid: sessionUid })
        .limit(1)
        .get();
      const acc = accData && accData[0];

      // 换绑：先把旧号码的映射删掉，别让旧手机还能重置密码
      if (acc && acc.phone && acc.phone !== id) {
        try {
          await phones().doc(acc.phone).remove();
        } catch (e) {}
      }
      await phones().doc(id).set({ uid: sessionUid, phone: id, createdAt: Date.now() });
      if (acc) {
        try {
          await db.collection("userAccounts").doc(acc._id).update({
            phone: id,
            phoneBoundAt: Date.now(),
            updatedAt: Date.now(),
          });
        } catch (e) {}
      }
      try {
        await phoneCodes().doc(id).remove();
      } catch (e) {}
      return ok({ phone: id.slice(0, 3) + "****" + id.slice(7) });
    }

    // scene === reset
    const newPassword = String(event.newPassword || "");
    if (newPassword.length < 6 || newPassword.length > 64) return fail("invalid_password");

    const { data: bindData } = await phones().doc(id).get();
    const bind = bindData && bindData[0];
    if (!bind || !bind.uid) return fail("phone_not_bound");

    const { data: accData } = await db
      .collection("userAccounts")
      .where({ uid: bind.uid })
      .limit(1)
      .get();
    const acc = accData && accData[0];
    if (!acc) return fail("account_not_found");

    const salt = crypto.randomBytes(16).toString("hex");
    await db.collection("userAccounts").doc(acc._id).update({
      salt,
      passwordHash: deps.hashPassword(newPassword, salt),
      hasPassword: true,
      updatedAt: Date.now(),
    });
    // 旧会话全部作废：密码换了，老 token 不能继续用
    await removeWhere(sessions(), bind.uid);
    try {
      await phoneCodes().doc(id).remove();
    } catch (e) {}
    return ok({ username: acc.username || "", phone: id.slice(0, 3) + "****" + id.slice(7) });
  }

  /**
   * 网页注册：往 userAccounts 写一条带密码的记录，uid 由服务端生成。
   *
   * 这张表就是 App「账号密码登录」读的那张，所以网页注册的账号，
   * 在燃灯 App 里可以直接用 loginWithAccount 登录（那边会拿 acc.uid 签 ticket）。
   */
  async function register(event, uid) {
    const username = deps.normalizeUsername(event.username);
    if (!username) return fail("invalid_username");
    const password = String(event.password || "");
    if (password.length < 6 || password.length > 64) return fail("invalid_password");
    if (rateLimited("register")) return fail("rate_limited");

    const usernameKey = username.toLowerCase();
    const existing = await findAccount(usernameKey);
    if (existing) return fail("username_taken");

    // uid 必须过得了 CloudBase 自定义登录 createTicket 的校验：
    //   ^[a-zA-Z0-9_\-#@~=*(){}[\]:.,<>+]{4,32}$
    // 所以固定 32 位（web_ + 28 位十六进制）。写长了网页侧照样注册成功，
    // 只有在 App 里用这个账号登录时才报 Invalid uid —— 联调时踩过一次。
    const newUid = uid || "web_" + crypto.randomBytes(14).toString("hex");
    const salt = crypto.randomBytes(16).toString("hex");
    await db.collection("userAccounts").add({
      username,
      usernameKey,
      salt,
      passwordHash: deps.hashPassword(password, salt),
      hasPassword: true,
      uid: newUid,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });
    const token = await createSession(newUid);
    await getOrCreateAccount(newUid);
    return ok({ token, uid: newUid, username, registered: true });
  }

  async function login(event) {
    const username = String(event.username || "").trim().toLowerCase();
    const password = String(event.password || "");
    if (!username) return fail("bad_request");
    if (rateLimited("login")) return fail("rate_limited");
    const acc = await findAccount(username);
    if (!acc) return fail("account_not_found");
    if (!acc.passwordHash) return fail("no_password"); // 手机号登录建的默认账号，还没设密码
    if (!checkPassword(acc, password)) return fail("wrong_password");
    const token = await createSession(acc.uid);
    await getOrCreateAccount(acc.uid);
    return ok({ token, uid: acc.uid, username: acc.username || username });
  }

  // ---------------- 入口 ----------------

  async function removeWhere(coll, uid) {
    const { data } = await coll.where({ uid }).limit(100).get();
    for (const doc of data || []) {
      try {
        await coll.doc(doc._id).remove();
      } catch (e) {}
    }
  }

  /**
   * 返回 undefined 表示不是交易类 action，交给 index.js 原有的 switch。
   * 其余一律返回要直接 return 给调用方的对象。
   */
  return async function handle(action, event, uid) {
    if (typeof action !== "string" || !action.startsWith("trade")) return undefined;

    try {
      await ensureCollections();

      if (action === "tradeRegister") return await register(event, uid);
      if (action === "tradeLogin") return await login(event);

      // 找回密码时用户还没登录，所以手机号相关动作先于会话校验；
      // 只有「绑定手机」这一路需要登录态。
      if (action === "tradePhoneCode" || action === "tradePhoneConfirm") {
        const session = event.scene === "reset" ? null : await resolveSession(event.token);
        if (action === "tradePhoneCode") return await phoneCode(event, session && session.uid);
        return await phoneConfirm(event, session && session.uid);
      }

      const session = await resolveSession(event.token);
      if (!session) return fail("unauthorized");
      const me = session.uid;
      await getOrCreateAccount(me);

      if (action === "tradeState") {
        const account = await snapshot(me);
        // 带上绑定手机（脱敏），前端据此显示「已绑定 138****0000」
        try {
          const { data } = await db
            .collection("userAccounts")
            .where({ uid: me })
            .limit(1)
            .get();
          const rec = data && data[0];
          if (rec && rec.phone) {
            account.phone = rec.phone.slice(0, 3) + "****" + rec.phone.slice(7);
          }
        } catch (e) {}
        return ok({ account });
      }

      if (action === "tradeReset") {
        if (rateLimited("reset:" + me)) return fail("rate_limited");
        await removeWhere(positions(), me);
        await removeWhere(orders(), me);
        await removeWhere(fills(), me);
        await touchAccount(me, { cash: INITIAL_CASH, lastPrice: 0 });
        return ok({ account: await snapshot(me) });
      }

      if (action === "tradeCancel") {
        const id = String(event.orderId || "");
        if (!id) return fail("bad_request");
        const { data } = await orders().doc(id).get();
        const o = data && data[0];
        if (!o || o.uid !== me) return fail("not_found");
        await orders().doc(id).remove();
        return ok({ account: await snapshot(me) });
      }

      if (action === "tradeClose") {
        const price = roundPrice(num(event.price));
        const bad = await checkPrice(me, price);
        if (bad) return fail(bad);
        const id = String(event.positionId || "");
        if (!id) return fail("bad_request");
        const { data } = await positions().doc(id).get();
        const p = data && data[0];
        if (!p || p.uid !== me) return fail("not_found");
        if (rateLimited("close:" + me)) return fail("rate_limited");
        await closePosition(me, p, price, false);
        return ok({ account: await snapshot(me) });
      }

      if (action === "tradeSync") {
        const price = num(event.price);
        const bad = await checkPrice(me, price);
        if (bad) return fail(bad);
        const changed = await matchOrders(me, price);
        return ok({ account: await snapshot(me), matched: changed });
      }

      if (action === "tradePlace") {
        const price = num(event.price);
        if (event.kind === "market") {
          const bad = await checkPrice(me, price);
          if (bad) return fail(bad);
        }
        return await openPosition(me, event, price);
      }

      return fail(`unknown action: ${action}`);
    } catch (e) {
      console.error("[trade] error:", e && e.stack ? e.stack : e);
      return fail(e && e.message ? e.message : "trade_error");
    }
  };
};
