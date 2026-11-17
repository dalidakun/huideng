/**
 * 支付宝 App 支付（服务端）：下单签名 / 主动查单 / 异步通知验签。
 *
 * 参考实现，未联调。风格与 cloudfunctions/api/trade.js 一致：
 *  - 只用 Node 内置模块（crypto / https / querystring），云函数不需要 npm install。
 *  - 应用私钥只从环境变量读，绝不进仓库、绝不进客户端。
 *  - 金额一律用「分」在服务端计算；客户端传来的 amountFen 只做范围校验。
 *  - 支付结果以「异步通知 + 主动查询」为准，客户端返回值只用于界面提示。
 *
 * 环境变量（云函数控制台 → 函数配置 → 环境变量）：
 *   ALIPAY_APP_ID       开放平台 APPID
 *   ALIPAY_PRIVATE_KEY  应用私钥（PKCS8 优先，可带或不带 PEM 头；换行可写成 \n）
 *   ALIPAY_PUBLIC_KEY   支付宝公钥（不是应用公钥！）
 *   ALIPAY_NOTIFY_URL   https://<env>.service.tcloudbase.com/alipay/notify
 *   ALIPAY_SELLER_ID    可选，商户 PID（2088 开头），填了会校验通知里的 seller_id
 *   ALIPAY_GATEWAY      可选，默认正式网关；沙箱填 https://openapi-sandbox.dl.alipaydev.com/gateway.do
 *   TZ                  建议 Asia/Shanghai（云函数默认 UTC；本文件的时间戳已自行 +8）
 *
 * 在 index.js 里的三处接线：
 *   const pay = require("./pay");
 *   pay.init(app);                                        // cloudbase.init(...) 之后
 *   const notify = await pay.handleNotify(event);          // event.httpMethod 分支里、postPage 之后
 *   const payResult = await pay.handle(action, event, uid); // switch (action) 之前
 */

const crypto = require("crypto");
const https = require("https");
const querystring = require("querystring");

const COLLECTION = "payOrders";
const MIN_FEN = 100; // 1 元
const MAX_FEN = 200000; // 2000 元
const ORDER_TTL_MINUTES = 30;
const CREATE_COOLDOWN_MS = 5000;

let _app = null;
let _db = null;
let _config = null;

/** 在 index.js 里 cloudbase.init(...) 之后调用一次。 */
function init(app) {
  _app = app;
  _db = null;
}

function db() {
  if (!_db) {
    if (!_app) throw new Error("pay_not_initialized");
    _db = _app.database();
  }
  return _db;
}

function env(name, fallback) {
  const v = process.env[name];
  if (v === undefined || v === null || String(v).trim() === "") {
    return fallback === undefined ? "" : fallback;
  }
  return String(v).trim();
}

/** 允许环境变量里只放 base64 私钥/公钥：自动补 PEM 头。 */
function toPem(raw, label) {
  const text = String(raw || "").replace(/\\n/g, "\n").trim();
  if (!text) return "";
  if (text.indexOf("BEGIN ") >= 0) return text;
  const body = text.replace(/\s+/g, "");
  const lines = body.match(/.{1,64}/g) || [];
  return "-----BEGIN " + label + "-----\n" + lines.join("\n") + "\n-----END " + label + "-----";
}

function config() {
  if (_config) return _config;
  _config = {
    appId: env("ALIPAY_APP_ID"),
    // 密钥工具默认导出的就是 PKCS8（PRIVATE KEY）
    privateKey: toPem(env("ALIPAY_PRIVATE_KEY"), "PRIVATE KEY"),
    publicKey: toPem(env("ALIPAY_PUBLIC_KEY"), "PUBLIC KEY"),
    notifyUrl: env("ALIPAY_NOTIFY_URL"),
    sellerId: env("ALIPAY_SELLER_ID"),
    gateway: env("ALIPAY_GATEWAY", "https://openapi.alipay.com/gateway.do"),
  };
  return _config;
}

function assertConfigured() {
  const c = config();
  if (!c.appId || !c.privateKey || !c.publicKey || !c.notifyUrl) {
    throw new Error("alipay_not_configured");
  }
}

/** 支付宝要求 timestamp 为北京时间（GMT+8），这里不依赖服务器时区。 */
function beijingTimestamp(date) {
  const d = date || new Date();
  const t = new Date(d.getTime() + 8 * 3600 * 1000);
  const p = function (n) {
    return String(n).padStart(2, "0");
  };
  return (
    t.getUTCFullYear() + "-" + p(t.getUTCMonth() + 1) + "-" + p(t.getUTCDate()) +
    " " + p(t.getUTCHours()) + ":" + p(t.getUTCMinutes()) + ":" + p(t.getUTCSeconds())
  );
}

/**
 * 待签名串：去掉 sign 与指定字段，按 key 升序拼 key=value&...。
 * 值是「未 URL 编码」的原始值（与支付宝网关一致）。
 */
function signContent(params, extraExclude) {
  const exclude = { sign: true };
  (extraExclude || []).forEach(function (k) {
    exclude[k] = true;
  });
  return Object.keys(params)
    .filter(function (k) {
      return !exclude[k] && params[k] !== undefined && params[k] !== null && String(params[k]) !== "";
    })
    .sort()
    .map(function (k) {
      return k + "=" + params[k];
    })
    .join("&");
}

function rsaSign(content, privateKey) {
  return crypto.createSign("RSA-SHA256").update(content, "utf8").sign(privateKey, "base64");
}

function rsaVerify(content, signature, publicKey) {
  try {
    return crypto.createVerify("RSA-SHA256").update(content, "utf8").verify(publicKey, signature, "base64");
  } catch (e) {
    return false;
  }
}

/** 生成 app 端调起收银台用的 orderStr（alipay.trade.app.pay）。 */
function buildAppPayOrderStr(order) {
  const c = config();
  const params = {
    app_id: c.appId,
    method: "alipay.trade.app.pay",
    charset: "utf-8",
    sign_type: "RSA2",
    timestamp: beijingTimestamp(),
    version: "1.0",
    notify_url: c.notifyUrl,
    biz_content: JSON.stringify({
      out_trade_no: order.outTradeNo,
      total_amount: order.amount,
      subject: order.subject,
      body: "用于服务器、域名与持续开发维护",
      product_code: "QUICK_MSECURITY_PAY",
      timeout_express: ORDER_TTL_MINUTES + "m",
    }),
  };
  params.sign = rsaSign(signContent(params), c.privateKey);
  return querystring.stringify(params);
}

/**
 * 调用支付宝网关（v2 协议，form POST）。
 * 只解析业务响应；HTTPS + 我方主动请求，不再校验响应签名。
 */
function callGateway(method, bizContent) {
  const c = config();
  const params = {
    app_id: c.appId,
    method: method,
    format: "JSON",
    charset: "utf-8",
    sign_type: "RSA2",
    timestamp: beijingTimestamp(),
    version: "1.0",
    biz_content: JSON.stringify(bizContent),
  };
  params.sign = rsaSign(signContent(params), c.privateKey);
  const body = querystring.stringify(params);

  return new Promise(function (resolve, reject) {
    let url;
    try {
      url = new URL(c.gateway);
    } catch (e) {
      reject(new Error("alipay_bad_gateway"));
      return;
    }
    const req = https.request(
      {
        hostname: url.hostname,
        port: url.port || 443,
        path: url.pathname + url.search,
        method: "POST",
        timeout: 8000,
        headers: {
          "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
          "Content-Length": Buffer.byteLength(body),
        },
      },
      function (res) {
        let raw = "";
        res.setEncoding("utf8");
        res.on("data", function (chunk) {
          raw += chunk;
        });
        res.on("end", function () {
          try {
            const json = JSON.parse(raw);
            const key = method.replace(/\./g, "_") + "_response";
            resolve(json[key] || { code: "unknown", sub_msg: String(raw).slice(0, 200) });
          } catch (e) {
            reject(new Error("alipay_bad_response"));
          }
        });
      }
    );
    req.on("timeout", function () {
      req.destroy(new Error("alipay_timeout"));
    });
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

function ok(data) {
  return Object.assign({ ok: true }, data);
}

function fail(error) {
  return { ok: false, error: error };
}

async function markPaid(order, info) {
  const now = Date.now();
  await db()
    .collection(COLLECTION)
    .doc(order._id)
    .update({
      status: "paid",
      tradeNo: info.tradeNo || "",
      source: info.source || "",
      paidAt: now,
      updatedAt: now,
    });
}

// 内存级防抖：同一 uid 5 秒内只允许建一单。冷启动会重置，够用。
const lastCreateAt = new Map();

async function createOrder(uid, event) {
  if (!uid || uid === "anon") return fail("unauthorized");
  assertConfigured();

  const fen = Number(event.amountFen);
  if (!Number.isInteger(fen) || fen < MIN_FEN || fen > MAX_FEN) return fail("invalid_amount");

  const nowMs = Date.now();
  if (nowMs - (lastCreateAt.get(uid) || 0) < CREATE_COOLDOWN_MS) return fail("too_frequent");
  lastCreateAt.set(uid, nowMs);
  if (lastCreateAt.size > 2000) lastCreateAt.clear();

  const outTradeNo = "RD" + nowMs + String(crypto.randomInt(1000, 10000));
  const amount = (fen / 100).toFixed(2);
  const order = {
    outTradeNo: outTradeNo,
    uid: uid,
    amountFen: fen,
    amount: amount,
    subject: "燃灯资助",
    status: "pending",
    tradeNo: "",
    source: "",
    client: String(event.client || "").slice(0, 16),
    createdAt: nowMs,
    paidAt: 0,
    updatedAt: nowMs,
  };
  await db().collection(COLLECTION).add(order);

  return ok({ outTradeNo: outTradeNo, amountFen: fen, orderStr: buildAppPayOrderStr(order) });
}

async function queryOrder(uid, event) {
  if (!uid || uid === "anon") return fail("unauthorized");
  const outTradeNo = String(event.outTradeNo || "").trim();
  if (!outTradeNo) return fail("invalid_params");

  const got = await db().collection(COLLECTION).where({ outTradeNo: outTradeNo, uid: uid }).limit(1).get();
  const order = got.data && got.data[0];
  if (!order) return fail("order_not_found");
  if (order.status === "paid") {
    return ok({ status: "paid", amountFen: order.amountFen, tradeNo: order.tradeNo });
  }
  if (order.status === "closed") {
    return ok({ status: "closed", amountFen: order.amountFen });
  }

  let res;
  try {
    res = await callGateway("alipay.trade.query", { out_trade_no: outTradeNo });
  } catch (e) {
    // 查单失败不要吓用户：保持 pending，客户端稍后再查。
    console.error("[pay] query gateway failed:", e && e.message);
    return ok({ status: order.status, amountFen: order.amountFen, queryFailed: true });
  }

  const tradeStatus = res.trade_status || "";
  if (res.code === "10000" && (tradeStatus === "TRADE_SUCCESS" || tradeStatus === "TRADE_FINISHED")) {
    await markPaid(order, { tradeNo: res.trade_no || "", source: "query" });
    return ok({ status: "paid", amountFen: order.amountFen, tradeNo: res.trade_no || "" });
  }
  if (tradeStatus === "TRADE_CLOSED") {
    await db().collection(COLLECTION).doc(order._id).update({ status: "closed", updatedAt: Date.now() });
    return ok({ status: "closed", amountFen: order.amountFen });
  }
  return ok({ status: order.status, amountFen: order.amountFen });
}

async function listOrders(uid) {
  if (!uid || uid === "anon") return fail("unauthorized");
  const got = await db()
    .collection(COLLECTION)
    .where({ uid: uid, status: "paid" })
    .orderBy("paidAt", "desc")
    .limit(20)
    .get();
  const list = (got.data || []).map(function (o) {
    return {
      outTradeNo: o.outTradeNo,
      amountFen: o.amountFen,
      amount: o.amount,
      paidAt: o.paidAt,
      tradeNo: o.tradeNo || "",
    };
  });
  return ok({ orders: list });
}

/** 云函数 action 入口；不是本模块的 action 时返回 undefined，让 index.js 继续 switch。 */
async function handle(action, event, uid) {
  if (action !== "createPayOrder" && action !== "queryPayOrder" && action !== "listMyPayOrders") {
    return undefined;
  }
  try {
    if (action === "createPayOrder") return await createOrder(uid, event || {});
    if (action === "queryPayOrder") return await queryOrder(uid, event || {});
    return await listOrders(uid);
  } catch (e) {
    console.error("[pay] " + action + " failed:", e && e.message);
    if (e && e.message === "alipay_not_configured") return fail("pay_not_configured");
    return fail("pay_failed");
  }
}

function parseNotifyBody(event) {
  let raw = event && event.body;
  if (event && event.isBase64Encoded && typeof raw === "string") {
    raw = Buffer.from(raw, "base64").toString("utf8");
  }
  if (raw && typeof raw === "object") return raw;
  const params = {};
  const text = String(raw || "");
  new URLSearchParams(text).forEach(function (v, k) {
    params[k] = v;
  });
  return params;
}

function notifyResponse(text) {
  return {
    statusCode: 200,
    headers: { "Content-Type": "text/plain; charset=utf-8" },
    body: text,
  };
}

/**
 * 支付宝异步通知（HTTP 访问服务，路径 /alipay/notify）。
 * 返回 null 表示这不是通知请求，交给 index.js 的其他分支。
 * 必须返回纯文本 success，否则支付宝会重试。
 */
async function handleNotify(event) {
  if (!event || !event.httpMethod) return null;
  const path = String(event.path || event.rawPath || "");
  if (!/\/alipay\/notify\/?$/.test(path)) return null;

  try {
    const c = config();
    if (!c.publicKey) {
      console.error("[pay] notify received but ALIPAY_PUBLIC_KEY missing");
      return notifyResponse("failure");
    }

    const params = parseNotifyBody(event);
    if (!rsaVerify(signContent(params, ["sign_type"]), params.sign || "", c.publicKey)) {
      console.error("[pay] notify signature invalid:", params.out_trade_no || "");
      return notifyResponse("failure");
    }
    if (c.appId && params.app_id !== c.appId) {
      console.error("[pay] notify app_id mismatch:", params.app_id);
      return notifyResponse("failure");
    }
    if (c.sellerId && params.seller_id !== c.sellerId) {
      console.error("[pay] notify seller_id mismatch:", params.seller_id);
      return notifyResponse("failure");
    }

    const outTradeNo = String(params.out_trade_no || "");
    const got = await db().collection(COLLECTION).where({ outTradeNo: outTradeNo }).limit(1).get();
    const order = got.data && got.data[0];
    if (!order) {
      // 订单不存在通常意味着建单写库失败，重试也无济于事：记日志、走人工对账。
      console.error("[pay] notify for unknown order:", outTradeNo, params.trade_status);
      return notifyResponse("success");
    }

    const status = String(params.trade_status || "");
    if (status === "TRADE_SUCCESS" || status === "TRADE_FINISHED") {
      if (String(params.total_amount || "") !== String(order.amount)) {
        console.error("[pay] notify amount mismatch:", outTradeNo, params.total_amount, order.amount);
        return notifyResponse("failure");
      }
      if (order.status !== "paid") {
        await markPaid(order, { tradeNo: params.trade_no || "", source: "notify" });
      }
    } else if (status === "TRADE_CLOSED" && order.status === "pending") {
      await db().collection(COLLECTION).doc(order._id).update({ status: "closed", updatedAt: Date.now() });
    }

    return notifyResponse("success");
  } catch (e) {
    console.error("[pay] notify failed:", e && e.message);
    return notifyResponse("failure");
  }
}

module.exports = {
  init: init,
  handle: handle,
  handleNotify: handleNotify,
};
