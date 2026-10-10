/**
 * 「api」云函数：佛经阅读器 App 的所有数据操作统一入口。
 *
 * 部署方式（云开发控制台 → 云函数 → 新建函数，函数名填写 api）：
 *  1. 上传本目录（index.js + package.json）
 *  2. 安装依赖：控制台「依赖」页执行 `npm install`（声明了 @cloudbase/js-sdk）
 *  3. 部署后先用 App 实测：登录后发布一条笔记，若日志中 uid= 非空即成功。
 *
 * 调用者身份说明：
 *  - 新平台（Web/HTTP 网关调用）不会自动向普通云函数注入用户身份，
 *    因此客户端会把当前登录用户的 access token 放在 event.__accessToken 传给本函数。
 *  - 本函数优先尝试环境注入的 TCB_UUID（新架构 context.environment / 旧架构 environ），
 *    否则用该 token 调官方接口 GET /auth/v1/user/me 解析出 uid。
 *
 * 客户端通过 cloudbase_flutter 的 app.callFunction(name: 'api', data: { action, ... }) 调用，
 * 函数 return 的普通对象会作为 FunctionResponse.result 返回。
 */
// 云函数专用 Server SDK：自动读取环境注入的管理员凭证，数据库端点自带地域。
const cloudbase = require("@cloudbase/node-sdk");
const crypto = require("crypto");
const https = require("https");

/**
 * 用 access token 调 CloudBase auth/v1/user/me 解析真实用户 ID。
 * 使用 Node.js 内置 https 模块，不依赖 fetch（Node 16 及以下无全局 fetch）。
 * 超时 5 秒，失败返回空字符串。
 */
function resolveUidByToken(token) {
  return new Promise((resolve) => {
    const envId = process.env.TCB_ENV || "randeng-d8gs968w22a3d98e8";
    const options = {
      hostname: `${envId}.api.tcloudbasegateway.com`,
      path: "/auth/v1/user/me",
      method: "GET",
      headers: { Authorization: `Bearer ${token}` },
    };
    const req = https.request(options, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
      res.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8");
        if (res.statusCode === 200) {
          try {
            const profile = JSON.parse(body);
            // 匿名会话（signInAnonymously 浏览广场）解析出的不是真实用户：
            // 返回空串，让上层绝不把「共享匿名 uid」当作真实身份，
            // 否则所有未登录用户共用同一 uid 会导致点赞/评论/查询全部串号。
            const isAnon =
              profile.is_anonymous === true ||
              profile.isAnonymous === true ||
              String(profile.user_type || "").toUpperCase() === "ANONYMOUS";
            if (isAnon) {
              console.log("[api] user/me anonymous, treat as no identity");
              return resolve("");
            }
            const u = profile.user_id || profile.sub || profile.uid || "";
            resolve(u ? String(u) : "");
          } catch (e) {
            console.log("[api] user/me parse error:", e.message);
            resolve("");
          }
        } else {
          console.log("[api] user/me status:", res.statusCode);
          resolve("");
        }
      });
    });
    req.on("error", (e) => {
      console.log("[api] user/me request error:", e.message);
      resolve("");
    });
    req.setTimeout(5000, () => {
      req.destroy();
      console.log("[api] user/me timeout");
      resolve("");
    });
    req.end();
  });
}

// 按环境变量显式构造凭证（与 SDK 自动读取等价，显式更稳妥）。
function buildInitOptions() {
  const opts = { env: process.env.TCB_ENV || "randeng-d8gs968w22a3d98e8" };
  if (process.env.TENCENTCLOUD_SECRETID && process.env.TENCENTCLOUD_SECRETKEY) {
    opts.secretId = process.env.TENCENTCLOUD_SECRETID;
    opts.secretKey = process.env.TENCENTCLOUD_SECRETKEY;
    if (process.env.TENCENTCLOUD_SESSIONTOKEN) {
      opts.sessionToken = process.env.TENCENTCLOUD_SESSIONTOKEN;
    }
  } else if (process.env.CLOUDBASE_APIKEY) {
    opts.accessKey = process.env.CLOUDBASE_APIKEY;
  }
  // 自定义登录私钥：从云函数环境变量 TCB_CUSTOM_LOGIN_CREDENTIALS 读取，
  // 值为控制台「自定义登录」下载的 key json（含 private_key / private_key_id / env_id）。
  // 这样私钥不写入代码，只存在云函数环境配置中。
  if (process.env.TCB_CUSTOM_LOGIN_CREDENTIALS) {
    try {
      opts.credentials = JSON.parse(process.env.TCB_CUSTOM_LOGIN_CREDENTIALS);
    } catch (e) {
      console.log("[api] TCB_CUSTOM_LOGIN_CREDENTIALS 解析失败:", e.message);
    }
  }
  return opts;
}

const app = cloudbase.init(buildInitOptions());

// 热门讨论聚合结果缓存（内存级，仅热实例间共享）：15 分钟内不重复全表扫描。
let hotDiscussionsCache = null;
// 菩提空间热门经文榜缓存：累计 $提及 计数（不设时间窗口），15 分钟 TTL。
let hotSutraMentionsCache = null;
// 大家都在读：全平台锁定精读经书热度缓存。
let popularSutrasCache = null;
// 宗门菜单页顶部展示位：某时间窗内各栏目社区的发帖数（按 since-until 分键），10 分钟 TTL。
let communityDailyTopCache = null;

async function resolveUid(event, context) {
  // 1) 客户端显式传入的 access token → 官方接口解析调用者
  //    优先级最高：新平台不会自动注入用户身份到普通云函数，
  //    context.environment.TCB_UUID 可能为匿名 UUID 而非真实用户，
  //    此时若先取 TCB_UUID 会导致所有用户共享同一 uid：
  //    - 点赞/评论时 note.ownerUserId === uid（误判为自己赞自己）→ 通知不创建
  //    - 查询时 userId 与 activity.userId 不一致 → 通知查不到
  //    - getMyNotes/getMyVerification 返回共享匿名数据 → 认证丢失、帖子串号
  //    因此有 token 时必须只信任 token 解析出的真实用户；token 存在但解析为空
  //    （匿名会话/过期/失败）也绝不回退 TCB_UUID，避免数据串号。
  const token = event.__accessToken || (event.data && event.data.__accessToken);
  if (token) {
    return resolveUidByToken(token);
  }

  // 2) 无 token（纯匿名浏览，未建匿名会话或调用方不带 token）时才回退
  //    context.environment（JSON 字符串）里的 TCB_UUID。
  //    ⚠️ 注意：未认证的 publishable-key 调用，TCB_UUID 是字面量 "anon"
  //    （共享占位符，不是真实用户）。绝不能把它当 uid 用——否则评论/回复/
  //    转发/关注全部写成同一个 "anon"，出现"评论没有@账号、主页空白"。
  //    真实匿名会话（signInAnonymously）的 TCB_UUID 是唯一长字符串，不在此列。
  try {
    const raw = context.environment;
    const env =
      typeof raw === "string" ? JSON.parse(raw) : raw && typeof raw === "object" ? raw : null;
    if (env && env.TCB_UUID) {
      const u = String(env.TCB_UUID);
      if (u && u !== "anon" && u.toLowerCase() !== "anonymous") return u;
    }
  } catch (e) {}

  // 3) 旧架构：parseContext().environ 里的 TCB_UUID
  try {
    const ctx = app.parseContext(context);
    if (ctx && ctx.environ && ctx.environ.TCB_UUID) {
      const u = String(ctx.environ.TCB_UUID);
      if (u && u !== "anon" && u.toLowerCase() !== "anonymous") {
        return u;
      }
    }
  } catch (e) {}

  // 4) 进程级环境变量（旧架构实例级）
  if (process.env.TCB_UUID) {
    const u = String(process.env.TCB_UUID);
    if (u && u !== "anon" && u.toLowerCase() !== "anonymous") return u;
  }

  return "";
}

function now() {
  return Date.now();
}

function ok(data) {
  return { ok: true, ...data };
}

function fail(error) {
  return { ok: false, error };
}

// ─────────────────────────────────────────────────────────────
// 大模型调用（DeepSeek，兼容 OpenAI chat/completions 协议）
// 密钥放云函数环境变量 DEEPSEEK_API_KEY，绝不进客户端。
// model：默认 deepseek-chat（性好价廉，适合佛经白话翻译）。
//        deepseek-reasoner 供「深入讨论」时按需选用。
// ─────────────────────────────────────────────────────────────
function callDeepSeek({ model, messages, maxTokens, timeoutMs, temperature }) {
  const apiKey = process.env.DEEPSEEK_API_KEY || "";
  if (!apiKey) {
    return Promise.reject(new Error("AI服务未配置（缺少 DEEPSEEK_API_KEY）"));
  }
  const body = JSON.stringify({
    model: model || "deepseek-chat",
    messages: messages || [],
    max_tokens: maxTokens || 600,
    // 默认 0.3（问答/翻译求稳）；白话译文要更自然流畅时可略调高。
    temperature: typeof temperature === "number" ? temperature : 0.3,
    stream: false,
  });
  const options = {
    hostname: "api.deepseek.com",
    path: "/chat/completions",
    method: "POST",
    // agent:false = 每次请求新建独立连接，不用 keep-alive 连接池。
    // 云函数出网代理常对长连接/keep-alive 重置（ECONNRESET），显式关闭更稳。
    agent: false,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
      "Content-Length": Buffer.byteLength(body),
      // 显式要求短连接，避免连接空闲被代理 RST。
      Connection: "close",
      "User-Agent": "huideng-sutra/1.0",
      Accept: "application/json",
    },
  };

  // 单次 https.request 包装成 Promise。
  function attempt(rejectUnauthorized) {
    return new Promise((resolve, reject) => {
      const opt = { ...options, rejectUnauthorized };
      const req = https.request(opt, (res) => {
        // 必须先用 Buffer 收齐再按 UTF-8 一次性解码：
        // 若 `string += chunk` 逐块转字符串，汉字（UTF-8 三字节）恰好被
        // TCP 分块切断时会解码失败变成替换字符，界面上就显示成问号。
        const chunks = [];
        res.on("data", (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
        res.on("end", () => {
          const data = Buffer.concat(chunks).toString("utf8");
          if (res.statusCode !== 200) {
            try {
              const j = JSON.parse(data);
              return reject(
                new Error("AI服务返回异常：" + (j.error && j.error.message ? j.error.message : res.statusCode))
              );
            } catch (e) {
              return reject(new Error("AI服务返回异常：HTTP " + res.statusCode));
            }
          }
          try {
            const j = JSON.parse(data);
            const text = j.choices && j.choices[0] && j.choices[0].message
              ? j.choices[0].message.content
              : "";
            if (!text) return reject(new Error("AI服务返回空内容"));
            resolve(String(text).trim());
          } catch (e) {
            reject(new Error("AI服务响应解析失败"));
          }
        });
      });
      req.on("error", (e) => {
        const code = e.code || "";
        const hint =
          code === "ECONNRESET"
            ? "（连接被重置，可能为密钥无效或云函数网络出口受限）"
            : code === "ENOTFOUND"
            ? "（域名无法解析）"
            : code === "ETIMEDOUT" || e.message === "Socket timeout"
            ? "（连接超时）"
            : "";
        reject(new Error("调用AI服务失败：" + (code || e.message) + hint));
      });
      req.setTimeout(timeoutMs || 45000, () => {
        req.destroy(new Error("AI服务响应超时"));
      });
      req.end(body);
    });
  }

  return attempt(true).catch((err) => {
    // 首次失败（尤其 ECONNRESET/证书类）时，用关闭证书校验再试一次，
    // 排除中间设备/证书链导致的握手后重置。若首次是非网络类错误（如 401/余额），
    // 直接以首次错误为准，避免掩盖真实原因。
    const msg = err && err.message ? err.message : "";
    const retryable =
      msg.includes("ECONNRESET") ||
      msg.includes("certificate") ||
      msg.includes("CERT_") ||
      msg.includes("socket hang up") ||
      msg.includes("ETIMEDOUT") ||
      msg.includes("timeout");
    if (!retryable) throw err;
    return attempt(false);
  });
}

// ─────────────────────────────────────────────────────────
// GitHub 写入：管理员「编辑经文」的新排版提交到仓库 assets/sutras_edited/。
// 需在云函数环境变量配置 GITHUB_TOKEN（带仓库 push 权限的 Personal Access Token）。
// 首次提交与更新均通过 Contents API（读当前 sha 后整体 PUT），FilePath 为提交路径。
// ─────────────────────────────────────────────────────────
function githubWriteFile({ repo, path, content, message }) {
  const token = process.env.GITHUB_TOKEN || "";
  if (!token) {
    return Promise.reject(new Error("GitHub 未配置（缺少 GITHUB_TOKEN）"));
  }
  const apiBase = "https://api.github.com";
  return new Promise((resolve, reject) => {
    // 先用 GET 读该文件当前 sha（不存在则为 404，用 null 表示新建）。
    const getSha = new Promise((res2) => {
      const getOpt = {
        hostname: "api.github.com",
        path: `/repos/${repo}/contents/${encodeURIComponent(path).replace(
          /%2F/g,
          "/"
        )}`,
        method: "GET",
        headers: {
          Authorization: `Bearer ${token}`,
          "User-Agent": "huideng-sutra/1.0",
          Accept: "application/vnd.github+json",
          "X-GitHub-Api-Version": "2022-11-28",
        },
      };
      const req = https.get(getOpt, (r) => {
        let body = "";
        r.on("data", (c) => (body += c));
        r.on("end", () => {
          if (r.statusCode === 200) {
            try {
              res2(JSON.parse(body).sha || null);
            } catch (e) {
              res2(null);
            }
          } else {
            res2(null);
          }
        });
      });
      req.on("error", () => res2(null));
    });

    getSha.then((sha) => {
      const body = JSON.stringify({
        message: message || "update sutra layout",
        content: Buffer.from(content, "utf8").toString("base64"),
        sha: sha || undefined,
      });
      const putOpt = {
        hostname: "api.github.com",
        path: `/repos/${repo}/contents/${encodeURIComponent(path).replace(
          /%2F/g,
          "/"
        )}`,
        method: "PUT",
        headers: {
          Authorization: `Bearer ${token}`,
          "User-Agent": "huideng-sutra/1.0",
          Accept: "application/vnd.github+json",
          "X-GitHub-Api-Version": "2022-11-28",
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body),
        },
      };
      const req = https.request(putOpt, (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          if (res.statusCode === 200 || res.statusCode === 201) {
            resolve({ ok: true });
          } else {
            let msg = "HTTP " + res.statusCode;
            try {
              const j = JSON.parse(data);
              msg = (j && j.message) || msg;
            } catch (e) {}
            reject(new Error("GitHub 写入失败：" + msg));
          }
        });
      });
      req.on("error", (e) =>
        reject(new Error("GitHub 写入失败：" + (e.code || e.message)))
      );
      req.end(body);
    });
  });
}

// GitHub 删除：管理员「撤销完成排版」时删除仓库 assets/sutras_edited/<卷>/<ID>.txt。
function githubDeleteFile({ repo, path, message }) {
  const token = process.env.GITHUB_TOKEN || "";
  if (!token) {
    return Promise.reject(new Error("GitHub 未配置（缺少 GITHUB_TOKEN）"));
  }
  const apiBase = "https://api.github.com";
  return new Promise((resolve, reject) => {
    const getUrl = `/repos/${repo}/contents/${encodeURIComponent(path).replace(
      /%2F/g,
      "/"
    )}`;
    const getOpt = {
      hostname: "api.github.com",
      path: getUrl,
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        "User-Agent": "huideng-sutra/1.0",
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    };
    // 先读 sha（文件不存在时视为已删除，直接返回成功）。
    const req = https.get(getOpt, (r) => {
      let body = "";
      r.on("data", (c) => (body += c));
      r.on("end", () => {
        if (r.statusCode === 200) {
          let sha = null;
          try {
            sha = JSON.parse(body).sha || null;
          } catch (e) {}
          if (!sha) return resolve({ ok: true });
          const delBody = JSON.stringify({
            message: message || "撤销经文排版",
            sha: sha,
          });
          const delOpt = {
            hostname: "api.github.com",
            path: getUrl,
            method: "DELETE",
            headers: {
              Authorization: `Bearer ${token}`,
              "User-Agent": "huideng-sutra/1.0",
              Accept: "application/vnd.github+json",
              "X-GitHub-Api-Version": "2022-11-28",
              "Content-Type": "application/json",
              "Content-Length": Buffer.byteLength(delBody),
            },
          };
          const delReq = https.request(delOpt, (res) => {
            let data = "";
            res.on("data", (c) => (data += c));
            res.on("end", () => {
              if (res.statusCode === 200 || res.statusCode === 204) {
                resolve({ ok: true });
              } else {
                let msg = "HTTP " + res.statusCode;
                try {
                  const j = JSON.parse(data);
                  msg = (j && j.message) || msg;
                } catch (e) {}
                reject(new Error("GitHub 删除失败：" + msg));
              }
            });
          });
          delReq.on("error", (e) =>
            reject(new Error("GitHub 删除失败：" + (e.code || e.message)))
          );
          delReq.end(delBody);
        } else {
          // 404：文件不存在，视为已删除。
          resolve({ ok: true });
        }
      });
    });
    req.on("error", (e) =>
      reject(new Error("GitHub 删除失败：" + (e.code || e.message)))
    );
  });
}

exports.main = async (event, context) => {
  const uid = await resolveUid(event, context);

  // 诊断日志：观察调用者身份从哪个渠道进来（首次部署时查看）
  try {
    const rawEnv = context.environment;
    console.log("[api] diag context.environment type:", typeof rawEnv);
    if (typeof rawEnv === "string") {
      console.log("[api] diag context.environment keys:", Object.keys(JSON.parse(rawEnv)).join(","));
      console.log("[api] diag context.environment.TCB_UUID:", (JSON.parse(rawEnv).TCB_UUID) || "");
    }
    const ctx = typeof app.parseContext === "function" ? app.parseContext(context) : (typeof cloudbase.parseContext === "function" ? cloudbase.parseContext(context) : {});
    console.log(
      "[api] diag ctx.environ keys:",
      ctx && ctx.environ ? Object.keys(ctx.environ).join(",") : "none"
    );
    console.log("[api] diag process.env.TCB_UUID:", process.env.TCB_UUID || "");
  } catch (e) {
    console.log("[api] diag error:", e.message);
  }

  const db = app.database();
  const notes = db.collection("notes");
  const likes = db.collection("noteLikes");
  const commentLikes = db.collection("noteCommentLikes");
  const comments = db.collection("noteComments");
  const reports = db.collection("noteReports");
  const favorites = db.collection("noteFavorites");
  const activities = db.collection("activities");
  const userData = db.collection("userData");
  const follows = db.collection("userFollows");
  const blocks = db.collection("userBlocks");
  const userAccounts = db.collection("userAccounts");
  const feedbacks = db.collection("feedbacks");
  const admins = db.collection("admins");
  const verifications = db.collection("userVerifications");
  const sutraDiscussions = db.collection("sutraDiscussions");
  const topicBans = db.collection("topicBans");
  // AI 译文缓存：同一段经文只生成一次，之后所有用户直接复用，避免重复计费。
  const aiTranslations = db.collection("aiTranslations");
  // 读经段落笔记/完成态：按 (user, sutraKey, index) 唯一，跨设备云端同步。
  const readingParagraphNotes = db.collection("readingParagraphNotes");
  // 管理员编辑的经文：按 id（规范 ID，如 T01n0031_001）唯一，存最新排版与版本时间戳。
  const sutraEdits = db.collection("sutraEdits");
  // 用户私有笔记（独立笔记 + 回收站）：一条笔记一个文档。
  // 与 userData 那个「所有 prefs 塞进一个文档」的存储彻底分开，单文档体积
  // 上限只约束单条笔记，不再随笔记条数线性增长，也就不会再撞上体积上限。
  const userNotes = db.collection("userNotes");
  // 用户时间线（画线 / 感想 / 笔记三类记录）：一条记录一个文档，recId 用
  // 客户端已有的稳定 id（h|经名|段|start|end、t|经名|段、n|<笔记id>）。
  // readingParagraphNotes 只能按 sutraKey 查单部经，做不了「本用户全部经
  // 按时间排」的全局视图，故时间线需要独立集合承载。
  const userRecords = db.collection("userRecords");

  // setUserData 的两个体积阈值。
  // 单 key 上限：宽松到足以放过 notes 这类正常的大 key（迁移期它还在
  // userData 里），只拦真正失控的 key；整包上限：平台单文档 16M，留足余量。
  const _maxPrefKeyChars = 3 * 1024 * 1024;
  const _maxUserDataChars = 6 * 1024 * 1024;

  // 确保 aiTranslations 集合存在。
  async function ensureAiTranslations() {
    try {
      await db.createCollection("aiTranslations");
    } catch (e) {
      // 已存在或其它错误均忽略。
    }
  }

  // 译文缓存版本号：提示词/翻译策略升级时递增，让旧的直译缓存自动失效，
  // 各端（生成、查缓存、客户端本地缓存键前缀）用同一版本，保证一致。
  const AI_TRANSLATE_PROMPT_VERSION = "v2";

  // 段落 → 缓存键：sha1(版本 + 段落)，同一段在同版本下全站复用一条译文。
  function paragraphTranslationHash(paragraph) {
    return crypto
      .createHash("sha1")
      .update(AI_TRANSLATE_PROMPT_VERSION + "\n" + paragraph)
      .digest("hex")
      .slice(0, 24);
  }

  // 清理模型输出：去掉行首「译文：」前缀与末尾「注：…」补充说明，
  // 让所有入口（阅读页弹层、段落查看页、菩提空间分享帖）拿到的都是纯正文。
  function cleanAiTranslation(raw) {
    let t = String(raw || "").replace(/^\s*(?:白话)?(?:译文|翻译)\s*[:：]\s*/, "");
    const noteRe =
      /(?:\r?\n|。|；)[　\s]*(?:【|\[|（|\(|〔|『)?(?:注\s*[:：]?\s*\d*|注\s*释[:：]|说明[:：]|备注[:：]|注释[:：])/;
    const m = noteRe.exec(t);
    if (m) t = t.slice(0, m.index);
    return t.trim();
  }

  // 确保 readingParagraphNotes 集合存在。
  async function ensureReadingParagraphNotes() {
    try {
      await db.createCollection("readingParagraphNotes");
    } catch (e) {
      // 已存在或其它错误均忽略。
    }
  }

  // 确保 userNotes 集合存在。
  async function ensureUserNotes() {
    try {
      await db.createCollection("userNotes");
    } catch (e) {
      // 已存在或其它错误均忽略。
    }
  }

  // 确保 userRecords 集合存在。
  async function ensureUserRecords() {
    try {
      await db.createCollection("userRecords");
    } catch (e) {
      // 已存在或其它错误均忽略。
    }
  }

  // 稳定的文档 id：客户端 recId / noteId 形态多样（含「|」「$经名」与中文），
  // 直接拼进 Mongo 文档 id 不安全（不能含 . 与 $），统一取 sha1 十六进制。
  // 同样的 (uid, kind, rawId) 永远得到同一个 id，批量 upsert 因此幂等，
  // 迁移重跑也不会产生重复文档。
  function stableDocId(uid, kind, rawId) {
    return crypto
      .createHash("sha1")
      .update(String(uid) + "|" + kind + "|" + String(rawId))
      .digest("hex");
  }

  // 并发受限的批量写：node-sdk 没有跨文档批量接口，按小组并发避免打爆配额。
  // 迁移几千条笔记时靠它把耗时压到可接受范围。
  async function writeDocsInBatches(col, entries, groupSize) {
    const size = Math.max(1, groupSize || 20);
    let written = 0;
    for (let i = 0; i < entries.length; i += size) {
      const slice = entries.slice(i, i + size);
      await Promise.all(slice.map((e) => col.doc(e.id).set(e.data)));
      written += slice.length;
    }
    return written;
  }

  // 确保 notes（菩提空间帖子）集合存在。
  async function ensureNotesCollection() {
    try {
      await db.createCollection("notes");
    } catch (e) {
      // 已存在或其它错误均忽略。
    }
  }

  // 按 (ownerUserId, sutraKey, index) 定位该段记录（无则 null）。index 统一存字符串，避免类型不一致。
  async function findReadingParagraph(owner, sutraKey, index) {
    const { data } = await readingParagraphNotes
      .where({ ownerUserId: owner, sutraKey, index: String(index) })
      .limit(2)
      .get();
    if (data && data.length > 0) return data[0];
    return null;
  }

  // 确保 userAccounts 集合存在（首次使用自动创建，避免 DATABASE_COLLECTION_NOT_EXIST）。
  async function ensureUserAccounts() {
    try {
      await db.createCollection("userAccounts");
    } catch (e) {
      // 已存在或其它错误均忽略，后续真实操作会再报出明确错误。
    }
  }

  // 确保 admins 集合存在。
  async function ensureAdmins() {
    try {
      await db.createCollection("admins");
    } catch (e) {
      // 已存在或其它错误均忽略。
    }
  }

  // 确保 feedbacks 集合存在。
  async function ensureFeedbacks() {
    try {
      await db.createCollection("feedbacks");
    } catch (e) {
      // 已存在或其它错误均忽略。
    }
  }

  // 判断是否为管理员：控制台数据库 → admins 集合中是否存在 { uid: 该用户 uid }。
  async function isAdminUser(uid) {
    if (!uid) return false;
    try {
      const { data } = await admins.where({ uid }).limit(1).get();
      return !!(data && data.length > 0);
    } catch (e) {
      return false;
    }
  }

  // 给反馈列表附加反馈者的账号名称（未设置返回空串）。
  async function attachFeedbackUsernames(feedbackList) {
    if (!feedbackList || feedbackList.length === 0) return;
    const ids = [...new Set(feedbackList.map((f) => f.userId).filter(Boolean))];
    if (ids.length === 0) return;
    const accounts = {};
    for (let i = 0; i < ids.length; i += 100) {
      const chunk = ids.slice(i, i + 100);
      try {
        const { data } = await userAccounts
          .where({ uid: _.in(chunk) })
          .get();
        for (const a of data || []) accounts[a.uid] = a.username || "";
      } catch (e) {}
    }
    for (const f of feedbackList) {
      f.username = accounts[f.userId] || "";
    }
  }

  // 确保 userVerifications 集合存在。
  async function ensureVerifications() {
    try {
      await db.createCollection("userVerifications");
    } catch (e) {
      // 已存在或其它错误均忽略，后续真实操作会再报出明确错误。
    }
  }

  // 确保 sutraDiscussions 集合存在。
  async function ensureSutraDiscussions() {
    try {
      await db.createCollection("sutraDiscussions");
    } catch (e) {
      // 已存在或其它错误均忽略，后续真实操作会再报出明确错误。
    }
  }

  // 确保 topicBans 集合存在（管理员删除的话题记录，用于全端隐藏与回收站恢复）。
  async function ensureTopicBans() {
    try {
      await db.createCollection("topicBans");
    } catch (e) {
      // 已存在或其它错误均忽略。
    }
  }

  // 确保 sutraEdits 集合存在（管理员编辑经文版本）。
  async function ensureSutraEdits() {
    try {
      await db.createCollection("sutraEdits");
    } catch (e) {
      // 已存在或其它错误均忽略，后续真实操作会再报出明确错误。
    }
  }

  // 确保 noteCommentLikes 集合存在（评论点赞记录，首次使用自动创建）。
  async function ensureCommentLikes() {
    try {
      await db.createCollection("noteCommentLikes");
    } catch (e) {
      // 已存在或其它错误均忽略。
    }
  }

  const _ = db.command;

  // 消息中心「收到的互动」类型：点赞/评论/回复评论/转发/收藏/关注/@提及。
  const receivedTypes = [
    "like_me",
    "reply",
    "comment_reply",
    "repost_me",
    "favorite_me",
    "follow_me",
    "mention",
  ];

  // 截取文本前 N 个字符作为帖子摘要（通知列表展示用）。
  function previewText(raw, max = 80) {
    const s = String(raw || "").replace(/\s+/g, " ").trim();
    return s.length > max ? s.slice(0, max) + "…" : s;
  }

  // 从评论/正文中解析 @账号 提及（账号规则与 normalizeUsername 一致）。
  function extractMentions(raw) {
    const text = String(raw || "");
    const re = /@([\u4e00-\u9fa5a-zA-Z0-9_]{2,20})/g;
    const out = [];
    let m;
    while ((m = re.exec(text)) !== null) {
      out.push(m[1]);
    }
    return out;
  }

  // 给笔记列表附加作者账号名（authorAccount），供客户端展示 @账号。
  async function attachAuthorAccounts(noteList) {
    if (!noteList || noteList.length === 0) return;
    const ids = [...new Set(noteList.map((n) => n.ownerUserId).filter(Boolean))];
    if (ids.length === 0) return;
    const accounts = {};
    try {
      await ensureUserAccounts();
    } catch (e) {}
    for (let i = 0; i < ids.length; i += 100) {
      const chunk = ids.slice(i, i + 100);
      try {
        const { data } = await userAccounts
          .where({ uid: _.in(chunk) })
          .get();
        for (const a of data || []) {
          // 同一 uid 可能存在多条历史记录（重复同步/迁移残留）：
          // 空用户名不得覆盖已有值，保证 @账号 的解析结果确定、不随查询顺序漂移。
          if (a.username) accounts[a.uid] = String(a.username);
        }
      } catch (e) {}
    }
    for (const n of noteList) {
      n.authorAccount = accounts[n.ownerUserId] || "";
    }
  }

  // 给笔记列表附加作者实名认证标记（authorVerified），供客户端展示认证图标。
  async function attachAuthorVerified(noteList) {
    if (!noteList || noteList.length === 0) return;
    const ids = [...new Set(noteList.map((n) => n.ownerUserId).filter(Boolean))];
    if (ids.length === 0) return;
    const verified = {};
    try {
      await ensureVerifications();
    } catch (e) {}
    for (let i = 0; i < ids.length; i += 100) {
      const chunk = ids.slice(i, i + 100);
      try {
        const { data } = await verifications
          .where({ uid: _.in(chunk) })
          .get();
        for (const v of data || []) verified[v.uid] = true;
      } catch (e) {}
    }
    for (const n of noteList) {
      n.authorVerified = !!verified[n.ownerUserId];
    }
  }

  // 给笔记列表附加作者「阅藏进度」原始数据（canonRead/canonTotal），
  // 客户端按经藏页同源算法（完成册数 ÷ 全藏总册数）自行计算百分比展示。
  async function attachAuthorCanonProgress(noteList) {
    if (!noteList || noteList.length === 0) return;
    const ids = [...new Set(noteList.map((n) => n.ownerUserId).filter(Boolean))];
    if (ids.length === 0) return;
    const reads = {};
    const totals = {};
    try {
      await ensureUserAccounts();
    } catch (e) {}
    for (let i = 0; i < ids.length; i += 100) {
      const chunk = ids.slice(i, i + 100);
      try {
        const { data } = await userAccounts
          .where({ uid: _.in(chunk) })
          .get();
        for (const a of data || []) {
          const read = Math.max(0, Number(a.canonRead) || 0);
          const total = Math.max(0, Number(a.canonTotal) || 0);
          // 历史残留记录可能没有进度字段（0），不得覆盖已有真实进度，
          // 否则阅藏百分比会随查询记录顺序在「正常/0%」间随机漂移。
          if (total > 0 || reads[a.uid] == null) reads[a.uid] = read;
          if (total > 0 || totals[a.uid] == null) totals[a.uid] = total;
        }
      } catch (e) {}
    }
    for (const n of noteList) {
      n.canonRead = reads[n.ownerUserId] || 0;
      n.canonTotal = totals[n.ownerUserId] || 0;
    }
  }

  // 给评论列表附加作者账号名（authorAccount）与实名认证标记（authorVerified）。
  // 详情页评论行要展示 @账号 与认证图标；此前 getComments 不返回这两项，
  // 客户端只能靠异步拉 profile 补齐，慢且不稳定。评论按 authorId 关联用户。
  async function attachCommentAuthorInfo(commentList) {
    if (!commentList || commentList.length === 0) return;
    const ids = [...new Set(commentList.map((c) => c.authorId).filter(Boolean))];
    if (ids.length === 0) return;
    const accounts = {};
    try {
      await ensureUserAccounts();
      for (let i = 0; i < ids.length; i += 100) {
        const chunk = ids.slice(i, i + 100);
        const { data } = await userAccounts
          .where({ uid: _.in(chunk) })
          .get();
        for (const a of data || []) accounts[a.uid] = a.username || "";
      }
    } catch (e) {}
    const verified = {};
    try {
      await ensureVerifications();
      for (let i = 0; i < ids.length; i += 100) {
        const chunk = ids.slice(i, i + 100);
        const { data } = await verifications
          .where({ uid: _.in(chunk) })
          .get();
        for (const v of data || []) verified[v.uid] = true;
      }
    } catch (e) {}
    for (const c of commentList) {
      c.authorAccount = accounts[c.authorId] || "";
      c.authorVerified = !!verified[c.authorId];
    }
  }

  const action = event.action;
  console.log(`[api] action=${action} uid=${uid} tokenPresent=${!!(event.__accessToken)}`);

  try {
    switch (action) {
      // 数据库连通性诊断：返回当前环境可用的凭证信息与一次真实查询结果
      case "dbProbe": {
        let tcbContextConfig = {};
        try {
          tcbContextConfig = JSON.parse(process.env.TCB_CONTEXT_CNFG || "{}");
        } catch (e) {}
        const creds = {
          TENCENTCLOUD_SECRETID: !!process.env.TENCENTCLOUD_SECRETID,
          TENCENTCLOUD_SECRETKEY: !!process.env.TENCENTCLOUD_SECRETKEY,
          TENCENTCLOUD_SESSIONTOKEN: !!process.env.TENCENTCLOUD_SESSIONTOKEN,
          CLOUDBASE_APIKEY: !!process.env.CLOUDBASE_APIKEY,
          TCB_CONTEXT_CNFG_URL: tcbContextConfig.URL || "",
          TCB_CONTEXT_KEYS: process.env.TCB_CONTEXT_KEYS || "",
        };
        try {
          const r = await notes.limit(1).get();
          const okResult = r && r.data && r.data.code !== "MISSING_CREDENTIALS";
          return ok({
            creds,
            db: okResult ? "ok" : "error",
            sample: r,
          });
        } catch (e) {
          return ok({
            creds,
            db: "error",
            error: e && e.message ? e.message : String(e),
          });
        }
      }

      // 身份诊断接口：返回当前识别到的调用者身份
      case "whoami": {
        // 诊断端点：帮助排查通知不显示问题
        let ctxEnvTcbUuid = "";
        try {
          const raw = context.environment;
          const env =
            typeof raw === "string" ? JSON.parse(raw) : raw && typeof raw === "object" ? raw : null;
          ctxEnvTcbUuid = (env && env.TCB_UUID) || "";
        } catch (e) {}
        let myNoteCount = -1;
        let myActivityCount = -1;
        let myActivitySample = [];
        let myNotifCount = -1;
        let myNotifSample = [];
        let notifByType = {};
        try {
          const noteRes = await notes.where({ ownerUserId: uid }).count();
          myNoteCount = noteRes.total;
          const actRes = await activities.where({ userId: uid }).orderBy("createdAt", "desc").limit(5).get();
          myActivitySample = (actRes.data || []).map((a) => ({
            type: a.type,
            noteId: a.noteId,
            actorId: a.actorId,
            createdAt: a.createdAt,
            viewed: a.viewed,
          }));
          const actCountRes = await activities.where({ userId: uid }).count();
          myActivityCount = actCountRes.total;
          // 兼容旧数据：查所有活动，内存过滤通知类型
          const allActRes = await activities
            .where({ userId: uid })
            .orderBy("createdAt", "desc")
            .limit(200)
            .get();
          const allNotifActs = (allActRes.data || []).filter((a) => {
            if (a.direction === "in") return true;
            if (!a.direction && receivedTypes.includes(a.type)) return true;
            return false;
          });
          myNotifCount = allNotifActs.length;
          for (const a of allNotifActs) {
            notifByType[a.type] = (notifByType[a.type] || 0) + 1;
          }
          myNotifSample = allNotifActs.slice(0, 5).map((a) => ({
            type: a.type,
            noteId: a.noteId,
            actorId: a.actorId,
            createdAt: a.createdAt,
            viewed: a.viewed,
          }));
        } catch (e) {}
        return ok({
          uid,
          tokenPresent: !!(event.__accessToken || (event.data && event.data.__accessToken)),
          ctxEnvTcbUuid,
          envTcbUuid: process.env.TCB_UUID || "",
          myNoteCount,
          myActivityCount,
          myActivitySample,
          myNotifCount,
          myNotifSample,
          notifByType,
        });
      }

      // ==================== 笔记 ====================

      case "createNote": {
        if (!uid) return fail("unauthorized");
        // 栏目社区页发的帖：记下所属社区，列表按它过滤即可，
        // 正文不用再塞 #话题 前缀（那样会被当成话题帖进话题榜）。
        const community = String(event.community || "").trim().slice(0, 50);
        const res = await notes.add({
          ownerUserId: uid,
          title: String(event.title || "无标题").slice(0, 100),
          content: String(event.content || ""),
          ...(community ? { community } : {}),
          visibility: event.visibility === "private" ? "private" : "public",
          authorName: String(event.authorName || "同修").slice(0, 30),
          likeCount: 0,
          commentCount: 0,
          viewCount: 0,
          repostCount: 0,
          status: "normal",
          createdAt: now(),
          updatedAt: now(),
        });
        await activities.add({
          userId: uid,
          type: "share",
          direction: "out",
          noteId: res.id,
          noteTitle: String(event.title || "无标题").slice(0, 100),
          content: String(event.content || ""),
          viewed: false,
          createdAt: now(),
        });
        // 新发布的笔记可能含尚未上过热门榜的 #话题/$经名，立即失效热门榜缓存，
        // 让下一次拉取能看到这些新话题/新经书。
        hotDiscussionsCache = null;
        hotSutraMentionsCache = null;
        return ok({ id: res.id });
      }

      case "updateNote": {
        if (!uid) return fail("unauthorized");
        const id = String(event.id || "");
        const patch = {};
        if (event.title != null) patch.title = String(event.title).slice(0, 100);
        if (event.content != null) patch.content = String(event.content);
        if (event.visibility != null) {
          patch.visibility =
            event.visibility === "private" ? "private" : "public";
        }
        if (event.status != null) {
          patch.status = event.status === "normal" ? "normal" : "hidden";
        }
        if (Object.keys(patch).length === 0) return fail("no_fields");
        patch.updatedAt = now();
        const note = await getOwnedNote(notes, id, uid);
        if (!note) return fail("not_found");
        // 帖子被隐藏（进回收站/下架）后不再出现在任何列表，等同删除处理：
        // 子回复重挂到父帖，避免回复链断开；恢复显示时链路保持有效。
        if (patch.status === "hidden" && note.status !== "hidden") {
          await reattachChildReplies(notes, id, String(note.repostOf || ""));
        }
        await notes.doc(id).update(patch);
        // 内容/可见性/状态改变会改变 #话题/$经名的贡献，重新聚合热门榜。
        if (event.content != null || event.visibility != null || event.status != null) {
          hotDiscussionsCache = null;
          hotSutraMentionsCache = null;
        }
        return ok({ id });
      }

      case "deleteNote": {
        if (!uid) return fail("unauthorized");
        const id = String(event.id || "");
        const note = await getOwnedNote(notes, id, uid);
        if (!note) return fail("not_found");
        // 先把子回复重新挂接再删除，保持回复链连通：
        // a→b→c 链中删掉中间的 b 时，c 的 repostOf 从 b 改指到 a（c/d 与原贴 a 保持头像连线）；
        // 被删的就是根帖（无父帖）时，子回复退化为独立的引用帖（quote 快照保留其回复对象），
        // 避免 c/d 悬空指向已删除的帖子、在广场/个人主页被拆成孤立的碎块。
        // 同时把被删 id 记入子帖 tombstoneAncestorIds，详情页渲染「已删除」占位。
        await reattachChildReplies(
          notes,
          id,
          String(note.repostOf || ""),
          Array.isArray(note.tombstoneAncestorIds)
            ? note.tombstoneAncestorIds
            : []
        );
        await notes.doc(id).remove();
        await likes.where({ noteId: id }).remove();
        await comments.where({ noteId: id }).remove();
        await reports.where({ noteId: id }).remove();
        await favorites.where({ noteId: id }).remove();
        // 删除笔记后其 #话题/$经名贡献消失，重新聚合热门榜。
        hotDiscussionsCache = null;
        hotSutraMentionsCache = null;
        return ok({});
      }

      case "getMyNotes": {
        if (!uid) return fail("unauthorized");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 50, 100);
        // 排除公告（kind: announcement），公告只在公告栏展示。
        const query = {
          ownerUserId: uid,
          kind: _.neq("announcement"),
        };
        // 可选按 repostKind 过滤（如「我的回复」只拉 reply 类型，避免客户端翻大量非回复帖）。
        if (event.repostKind) query.repostKind = String(event.repostKind);
        const base = notes.where(query);
        const res = await base
          .orderBy("updatedAt", "desc")
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        const { total } = await base.count();
        await attachAuthorAccounts(res.data);
        await attachAuthorVerified(res.data);
        await attachAuthorCanonProgress(res.data);
        return ok({
          notes: res.data,
          total,
          hasMore: (page - 1) * pageSize + res.data.length < total,
        });
      }

      // ==================== 广场 ====================

      case "getUserNotes": {
        const userId = String(event.userId || "");
        if (!userId) return fail("bad_request");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 20, 50);
        const base = notes.where({
          ownerUserId: userId,
          visibility: "public",
          status: "normal",
          kind: _.neq("announcement"),
        });
        const res = await base
          .orderBy("createdAt", "desc")
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        const { total } = await base.count();
        await attachAuthorAccounts(res.data);
        await attachAuthorVerified(res.data);
        await attachAuthorCanonProgress(res.data);
        return ok({
          notes: res.data,
          total,
          hasMore: (page - 1) * pageSize + res.data.length < total,
        });
      }

      case "getPlazaNotes": {
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 20, 100);
        const sort = event.sort === "hot" ? "hot" : "latest";
        // 可选话题过滤（话题页专用）：只返回含 #话题 的帖子。
        // 匹配精确到边界（#打坐 不误伤 #打坐中），与客户端词边界规则一致。
        const rawTopic = String(event.topic || "").trim().slice(0, 50);
        const topicFilter = rawTopic
          ? db.RegExp({
              regexp: `#${rawTopic.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?=[\\s#，。！？,;:!?（）()]|$)`,
              options: "",
            })
          : null;
        // 可选社区过滤（栏目社区页专用）：只返回 community 字段精确命中的帖子，
        // 与话题过滤可以叠加，也可以单独使用。
        const rawCommunity = String(event.community || "").trim().slice(0, 50);
        const communityFilter = rawCommunity || null;
        const base = notes.where(
          Object.assign(
            {
              visibility: "public",
              status: "normal",
              kind: _.neq("announcement"),
            },
            topicFilter ? { content: topicFilter } : {},
            communityFilter ? { community: communityFilter } : {}
          )
        );

        // 屏蔽的用户内容从广场隐藏
        let blocked = [];
        if (uid) {
          const br = await blocks.where({ blockerId: uid }).limit(1000).get();
          blocked = br.data.map((r) => r.blockedId);
        }
        const filterBlocked = (arr) =>
          blocked.length
            ? arr.filter(
                (n) =>
                  n.ownerUserId === uid || // 自己的内容（含评论）始终可见
                  (!blocked.includes(n.ownerUserId) &&
                    !(
                      n.repostSourceUserId &&
                      blocked.includes(n.repostSourceUserId)
                    ))
              )
            : arr;

        // 热门排序：阅读量 + 点赞×3 + 评论×5 + 转发×8 除以时间衰减因子
        // （ageHours + 2 的 1.3 次方），得分随帖子变老而衰减。
        // 效果：新帖子有机会冲到顶部，老帖子需要持续互动才能保持高位，
        // 避免热门榜永远被同一批帖子占满。
        // 另加规则：我或我关注的用户评论（回复帖）过的帖子获得置顶加权，
        // 加权值同样随该评论的新鲜程度衰减，不会长期霸榜；
        // 这些回复帖本身也小幅加权，保证与父帖出现在同一页，头像连线得以展示。
        if (sort === "hot") {
          const nowMs = Date.now();
          // 热门扫描只取最近 3 天的帖子（帖子成千上万时不再每次全表扫描，刷新更快）。
          // 若热门池不足三页（冷清时段），放宽到 7 天、再放宽到 30 天兜底，保证热门榜有内容。
          // 话题模式例外：带该话题的帖子总量有限，直接全量扫描（不限时间窗），
          // 冷清的老话题也能完整展示历史帖，再按同一套热度衰减公式排序。
          // 社区同理：一个社区的帖子量本来就小，全量扫描才排得全。
          const hotPoolMin = 60;
          let all = [];
          if (topicFilter || communityFilter) {
            let skip = 0;
            while (true) {
              const r = await base
                .orderBy("createdAt", "desc")
                .skip(skip)
                .limit(1000)
                .get();
              all.push(...(r.data || []));
              if ((r.data || []).length < 1000) break;
              skip += 1000;
            }
          } else {
            for (const days of [3, 7, 30]) {
              const since = nowMs - days * 24 * 3600000;
              const collected = [];
              let skip = 0;
              while (true) {
                const r = await base
                  .where({ createdAt: _.gte(since) })
                  .skip(skip)
                  .limit(1000)
                  .get();
                const batch = r.data || [];
                collected.push(...batch);
                if (batch.length < 1000) break;
                skip += 1000;
              }
              all = collected;
              if (collected.length >= hotPoolMin) break;
            }
          }
          // 我本人 + 我关注的用户发出的回复帖：{父帖id: 最新回复时间} 用于父帖置顶。
          const parentBoostTime = new Map();
          const myReplyIds = new Set();
          if (uid) {
            try {
              const fr = await follows
                .where({ followerId: uid })
                .limit(1000)
                .get();
              const authors = fr.data
                .map((r) => r.followeeId)
                .filter(Boolean);
              authors.push(uid); // 自己的评论同样置顶
              for (let i = 0; i < authors.length; i += 100) {
                const chunk = authors.slice(i, i + 100);
                const rr = await notes
                  .where({
                    ownerUserId: _.in(chunk),
                    repostOf: _.neq(""),
                    visibility: "public",
                    status: "normal",
                  })
                  .limit(1000)
                  .get();
                for (const rp of rr.data || []) {
                  if (!rp.repostOf || !rp._id) continue;
                  myReplyIds.add(rp._id);
                  const t = rp.createdAt || 0;
                  if (t > (parentBoostTime.get(rp.repostOf) || 0)) {
                    parentBoostTime.set(rp.repostOf, t);
                  }
                }
              }
            } catch (e) {}
          }
          // 置顶加权随评论时间衰减：刚评论时大幅置顶，约一天后基本消失。
          const boostVal = (t) =>
            t
              ? 45 /
                Math.pow(
                  Math.max(0, (nowMs - t) / 3600000) + 2,
                  1.3
                )
              : 0;
          const scored = filterBlocked(all).map((n) => {
            const ageHours =
              Math.max(0, (nowMs - (n.createdAt || nowMs)) / 3600000);
            const engagement =
              (n.viewCount || 0) +
              (n.likeCount || 0) * 3 +
              (n.commentCount || 0) * 5 +
              (n.repostCount || 0) * 8;
            const base = (1 + engagement) / Math.pow(ageHours + 2, 1.3);
            // 回复帖取半额加权，保证排在父帖下方；父帖取全额加权。
            const boost = myReplyIds.has(n.id)
              ? boostVal(n.createdAt || 0) * 0.5
              : boostVal(parentBoostTime.get(n.id) || 0);
            return {
              ...n,
              _hotScore: base + boost,
            };
          });
          scored.sort(
            (a, b) => b._hotScore - a._hotScore || (b.createdAt || 0) - (a.createdAt || 0)
          );
          const total = scored.length;
          // 话题发起人帖：可见帖子里最早的一条（服务端权威查询，
          // 客户端不再受「前 N 条里挑最早」的截断影响）。
          let firstNoteId = "";
          if (topicFilter && scored.length) {
            let first = scored[0];
            for (const n of scored) {
              if ((n.createdAt || 0) < (first.createdAt || 0)) first = n;
            }
            firstNoteId = String(first._id || first.id || "");
          }
          const pageNotes = scored.slice((page - 1) * pageSize, (page - 1) * pageSize + pageSize);
          const notesOut = pageNotes.map(({ _hotScore, ...rest }) => rest);
          await attachAuthorAccounts(notesOut);
        await attachAuthorVerified(notesOut);
        await attachAuthorCanonProgress(notesOut);
        return ok({
            notes: notesOut,
            total,
            hasMore: (page - 1) * pageSize + pageNotes.length < total,
            firstNoteId,
          });
        }

        const res = await base
          .orderBy("createdAt", "desc")
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        const filtered = filterBlocked(res.data);
        const { total } = await base.count();
        await attachAuthorAccounts(filtered);
        await attachAuthorVerified(filtered);
        await attachAuthorCanonProgress(filtered);
        // 话题模式（latest 排序）同样附带发起人帖 id：单独按 createdAt asc 查最早一条。
        let firstNoteId = "";
        if (topicFilter) {
          try {
            const fr = await base.orderBy("createdAt", "asc").limit(1).get();
            const f = (fr.data || [])[0];
            if (f) firstNoteId = String(f._id || f.id || "");
          } catch (e) {}
        }
        return ok({
          notes: filtered,
          total,
          hasMore: (page - 1) * pageSize + res.data.length < total,
          firstNoteId,
        });
      }

      case "getFollowingNotes": {
        if (!uid) return fail("unauthorized");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 20, 100);
        // 获取关注的用户 ID 列表
        const fr = await follows.where({ followerId: uid }).limit(1000).get();
        const followedIds = fr.data.map((r) => r.followeeId);
        if (followedIds.length === 0)
          return ok({ notes: [], total: 0, hasMore: false });
        // 屏蔽的用户内容过滤
        const br = await blocks.where({ blockerId: uid }).limit(1000).get();
        const blocked = br.data.map((r) => r.blockedId);
        const filterBlocked = (arr) =>
          blocked.length
            ? arr.filter(
                (n) =>
                  !blocked.includes(n.ownerUserId) &&
                  !(
                    n.repostSourceUserId &&
                    blocked.includes(n.repostSourceUserId)
                  )
              )
            : arr;
        const base = notes.where({
          ownerUserId: _.in(followedIds),
          visibility: "public",
          status: "normal",
          kind: _.neq("announcement"),
          // 关注页不显示回复帖子（发现页已经展示了）
          repostKind: _.neq("reply"),
        });
        const res = await base
          .orderBy("createdAt", "desc")
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        // 关注页只显示：直接发的帖子、转发、引用转发
        // 不显示回复帖子（发现页已经展示了）
        const filtered = filterBlocked(res.data).filter(
          (n) => n.repostKind !== 'reply'
        );
        const { total } = await base.count();
        await attachAuthorAccounts(filtered);
        await attachAuthorVerified(filtered);
        await attachAuthorCanonProgress(filtered);
        return ok({
          notes: filtered,
          total,
          hasMore: (page - 1) * pageSize + res.data.length < total,
        });
      }

      // ==================== 话题管理（管理员） ====================

      // 删除话题：加入封禁表，客户端全端隐藏含该话题的帖子；可从回收站恢复。
      case "deleteTopic": {
        if (!uid || !(await isAdminUser(uid))) return fail("forbidden");
        await ensureTopicBans();
        const name = String(event.name || "").trim().slice(0, 30);
        if (!name) return fail("bad_request");
        const exists = await topicBans.where({ name }).limit(1).get();
        if (!(exists.data && exists.data.length > 0)) {
          await topicBans.add({ name, adminId: uid, createdAt: now() });
        }
        // 热门榜缓存立即失效：被删除的话题不能继续出现在热门榜。
        hotDiscussionsCache = null;
        return ok({ name });
      }

      // 恢复话题：从封禁表中移除，相关帖子自动重新可见。
      case "restoreTopic": {
        if (!uid || !(await isAdminUser(uid))) return fail("forbidden");
        await ensureTopicBans();
        const name = String(event.name || "").trim().slice(0, 30);
        if (!name) return fail("bad_request");
        const res = await topicBans.where({ name }).get();
        for (const r of res.data || []) {
          if (r._id) await topicBans.doc(r._id).remove();
        }
        // 热门榜缓存同步失效：恢复的话题重新参与热度统计。
        hotDiscussionsCache = null;
        return ok({ name });
      }

      // 获取全部被封禁的话题（含删除时间），供客户端隐藏与回收站展示。
      case "getBannedTopics": {
        await ensureTopicBans();
        const res = await topicBans.orderBy("createdAt", "desc").limit(1000).get();
        return ok({
          topics: (res.data || []).map((r) => ({
            name: String(r.name || ""),
            createdAt: r.createdAt || 0,
          })),
        });
      }

      // 宗门菜单页顶部展示位：统计「前一天」各栏目社区的发帖数，
      // 返回按发帖数降序的社区列表（最多 20 个，正好是八大宗派 + 十二法门），
      // 每个社区附一条该时间窗内最热的帖子，供卡片直接展示其内容。
      // 并列第一（发帖数相同）时不做取舍：客户端在并列者里随机挑一个展示。
      // 只统计 community 字段非空的公开帖（社区页发出的帖），广场普通帖不计入。
      case "getCommunityDailyTop": {
        const nowMs = Date.now();
        const until = Number(event.until) || nowMs;
        const since = Number(event.since) || until - 24 * 3600000;
        // 只接受 0~7 天的窗口，防止这个接口被拿去当全表统计用。
        const span = until - since;
        if (!(span > 0) || span > 7 * 24 * 3600000) return fail("bad_range");
        const cacheKey = `${since}-${until}`;
        if (
          communityDailyTopCache &&
          communityDailyTopCache.key === cacheKey &&
          nowMs - communityDailyTopCache.at < 10 * 60 * 1000
        ) {
          return ok({ ...communityDailyTopCache.data, cached: true });
        }

        // community 用 _.gt("") 而不是 _.neq("")：字段缺失的广场帖在 $ne 语义下
        // 也会被匹配上（缺失即「不等于空串」），$gt 则不会，连锁住查询范围。
        // 循环里再兜一次 trim 判空，两处都不依赖对方的数据库语义。
        const base = notes.where({
          visibility: "public",
          status: "normal",
          kind: _.neq("announcement"),
          community: _.gt(""),
          createdAt: _.gte(since).and(_.lt(until)),
        });
        let all = [];
        let skip = 0;
        // 一天内的社区帖量很小，1000 一批翻完即可；20000 封底兜住异常膨胀。
        while (skip < 20000) {
          const r = await base.skip(skip).limit(1000).get();
          const batch = r.data || [];
          all.push(...batch);
          if (batch.length < 1000) break;
          skip += 1000;
        }

        // 与广场同款：屏蔽过的用户，其帖子不进入展示位。
        let blocked = [];
        if (uid) {
          try {
            const br = await blocks.where({ blockerId: uid }).limit(1000).get();
            blocked = br.data.map((r) => r.blockedId);
          } catch (e) {}
        }
        const visible = blocked.length
          ? all.filter(
              (n) =>
                n.ownerUserId === uid ||
                (!blocked.includes(n.ownerUserId) &&
                  !(
                    n.repostSourceUserId &&
                    blocked.includes(n.repostSourceUserId)
                  ))
            )
          : all;

        // 当窗内的互动热度：与 getPlazaNotes 热门榜同一套权重
        //（阅读 +1、赞×3、评论×5、转发×8）。时间衰减在同一天内差异很小，
        // 省略掉，这样「谁更热」完全由互动量决定，不会被发帖时间带偏。
        const engagementOf = (n) =>
          (n.viewCount || 0) +
          (n.likeCount || 0) * 3 +
          (n.commentCount || 0) * 5 +
          (n.repostCount || 0) * 8;

        const groups = new Map();
        for (const n of visible) {
          const community = String(n.community || "").trim();
          if (!community) continue;
          let g = groups.get(community);
          if (!g) {
            g = { community, posts: 0, best: null, bestScore: -1 };
            groups.set(community, g);
          }
          g.posts += 1;
          const score = engagementOf(n);
          const bestCreatedAt = (g.best && g.best.createdAt) || 0;
          // 热度相同取更晚发的那条，同分时的展示结果也确定。
          if (
            score > g.bestScore ||
            (score === g.bestScore && (n.createdAt || 0) > bestCreatedAt)
          ) {
            g.bestScore = score;
            g.best = n;
          }
        }
        const ranked = [...groups.values()].sort(
          (a, b) => b.posts - a.posts || b.bestScore - a.bestScore
        );
        // 展示位只需要标题/正文/作者/互动数，正文截断到 200 字即可，
        // 避免把整篇长文搬上接口。
        const spotNote = (n, community) =>
          n
            ? {
                id: String(n._id || n.id || ""),
                community,
                title: String(n.title || "").slice(0, 100),
                content: String(n.content || "").slice(0, 200),
                authorName: String(n.authorName || ""),
                ownerUserId: String(n.ownerUserId || ""),
                likeCount: n.likeCount || 0,
                commentCount: n.commentCount || 0,
                viewCount: n.viewCount || 0,
                createdAt: n.createdAt || 0,
              }
            : null;
        const communities = ranked.slice(0, 20).map((g) => ({
          community: g.community,
          posts: g.posts,
          note: spotNote(g.best, g.community),
        }));
        const notesOut = communities.map((c) => c.note).filter(Boolean);
        await attachAuthorAccounts(notesOut);
        await attachAuthorVerified(notesOut);
        const data = { communities, updatedAt: nowMs };
        communityDailyTopCache = { at: nowMs, key: cacheKey, data };
        return ok(data);
      }

      // 讨论页热门榜：聚合公开帖子中的 #话题 与 $经名 引用热度，
      // 返回全量话题 + 全量经文（最多各 200 条；客户端卡片取前几名做当日轮换，「更多」页展示全榜）。
      case "getHotDiscussions": {
        const nowMs = Date.now();
        // 15 分钟 TTL 缓存：避免每次请求都全表扫描。
        if (hotDiscussionsCache && nowMs - hotDiscussionsCache.at < 15 * 60 * 1000) {
          return ok({ ...hotDiscussionsCache.data, cached: true });
        }
        const topicRe = /#([^\s#，。！？,;:!?（）()]+)/g;
        // 经文引用识别与客户端 referencesSutra 完全一致：
        // - $经名 / @经名 两种标记都识别（旧版 @经名 引用同样计入）；
        // - 标记前一个字符不能是汉字/字母/数字（避免「读$金刚经」之外的长词误判，
        //   与讨论页筛选相关帖子的规则相同，保证榜单数与点进去看到的条数一致）；
        // - 排除 [@账号](user:...) 用户提及；
        // - 经名后允许粘连正文（「$金刚经真好」），客户端按经书目录最长前缀归一。
        const sutraRe = /[@$]([^\s#$，。！？,;:!?（）()@[\]]+)/g;
        const sutraBeforeRe = /[0-9A-Za-z\u4e00-\u9fa5]/;
        // 含数字的话题（如 #20240808、#第3天、#abc123）不入榜，避免污染榜单。
        const noiseTopicRe = /\d/;
        const topics = new Map();
        const sutras = new Map();
        // 管理员删除的话题不再进入热门榜。
        let bannedTopics = new Set();
        try {
          await ensureTopicBans();
          const br = await topicBans.limit(1000).get();
          bannedTopics = new Set((br.data || []).map((r) => String(r.name || "")));
        } catch (e) {}
        // 不按时间窗口截断（旧逻辑只统计最近 14 天，导致 14 天没新帖的话题
        // 整体掉出榜单、「更多」页时有时无）。改为全量扫描最新 cap 条公开帖子，
        // 所有出现过的话题/经文都稳定在榜，长时间没有新讨论也不会消失。
        // 排序由「累计互动热度」决定，时间只作为一个有界乘数参与（见
        // aggregateRecord 里的公式），保证老热门的名次不会被时间稀释掉。
        // 单条记录对热度榜的贡献（话题帖、经书讨论都复用同款聚合逻辑）：
        // - engagement 越高（累计互动越多）得分越高；新帖额外乘一个随时间
        //   收敛到 1 的有界系数，保证老热门不被稀释、同时新帖仍有机会上榜；
        // - 经书讨论（sutraDiscussions）只按 sutraTitle 字段计入对应经书——
        //   讨论正文里提到的其它 $经名 不计入（那条讨论不会出现在被提及经书的
        //   讨论页），content 中的 #话题 仍按话题帖一样计分；
        // - 广场帖子按正文（不含标题）里的 $经名 引用计入，识别规则与客户端讨论页
        //   筛选相关帖子完全一致，保证榜单数 == 点进去看到的条数。
        const addSutra = (name, score, createdAt) => {
          const cur = sutras.get(name) || { score: 0, posts: 0, last: 0 };
          cur.score += score;
          cur.posts += 1;
          if ((createdAt || 0) > cur.last) cur.last = createdAt || 0;
          sutras.set(name, cur);
        };
        const aggregateRecord = (createdAt, likeCount, viewCount, commentCount, repostCount, /* 话题扫描文本 */ topicText, /* 经书讨论专属 */ sutraTitle, /* 经文引用扫描文本（仅正文） */ sutraText) => {
          const ageHours = Math.max(0, (nowMs - (createdAt || nowMs)) / 3600000);
          // 热度按「累计互动量」统计，不做时间窗口截断，时间也不进分母：
          // 出现一次即计 4 点基础热度，再叠加各互动量加权。
          const engagement =
            4 +
            (viewCount || 0) +
            (likeCount || 0) * 3 +
            (commentCount || 0) * 5 +
            (repostCount || 0) * 8;
          // 新鲜度只作为一个有界乘数：刚发布最高 4 倍（1 + 6/2），随小时数
          // 增长迅速收敛到 1。这样老热门的累计热度不会被时间稀释掉（不会像
          // 旧公式那样被 /Math.pow(ageHours+2, 1.3) 压到 0、退化成纯时间排序），
          // 长期没有新讨论时榜单名次也保持稳定；新帖仍能凭新鲜度挤进榜。
          const score = engagement * (1 + 6 / (ageHours + 2));
          // 经书讨论：直接以 sutraTitle 字段计入经文榜（正文不再重复计 $经名）。
          if (sutraTitle) {
            const s = String(sutraTitle).trim();
            if (s && s.length <= 24) addSutra(s, score, createdAt);
          }
          // 通用：从文本中识别 #话题，每个去重后累加。
          if (topicText) {
            topicRe.lastIndex = 0;
            const seenT = new Set();
            let m;
            while ((m = topicRe.exec(topicText)) !== null) {
              const t = m[1];
              if (t.length > 24 ||
                  seenT.has(t) ||
                  bannedTopics.has(t) ||
                  noiseTopicRe.test(t)) {
                continue;
              }
              seenT.add(t);
              const cur = topics.get(t) || { score: 0, posts: 0, last: 0 };
              cur.score += score;
              cur.posts += 1;
              if ((createdAt || 0) > cur.last) cur.last = createdAt || 0;
              topics.set(t, cur);
            }
          }
          // 经文引用：$经名/@经名，与客户端 referencesSutra 同款规则。
          if (sutraText) {
            sutraRe.lastIndex = 0;
            const seenS = new Set();
            let m;
            while ((m = sutraRe.exec(sutraText)) !== null) {
              const markerIdx = m.index;
              const before = markerIdx > 0 ? sutraText[markerIdx - 1] : "";
              if (sutraBeforeRe.test(before)) continue;
              // [@账号](user:...) 是用户提及，不是经文引用。
              if (sutraText.startsWith("](user:", markerIdx + m[0].length)) continue;
              const s = m[1];
              if (!s || s.length > 24 || seenS.has(s)) continue;
              seenS.add(s);
              addSutra(s, score, createdAt);
            }
          }
        };
        const hotBase = notes.where({
          visibility: "public",
          status: "normal",
          kind: _.neq("announcement"),
        });
        const cap = 3000;
        let scanned = 0;
        let skip = 0;
        while (scanned < cap) {
          const r = await hotBase
            .orderBy("createdAt", "desc")
            .skip(skip)
            .limit(1000)
            .get();
          const batch = r.data || [];
          if (batch.length === 0) break;
          for (const n of batch) {
            if (++scanned > cap) break;
            aggregateRecord(
              n.createdAt,
              n.likeCount,
              n.viewCount,
              n.commentCount,
              n.repostCount,
              `${n.title || ""}\n${n.content || ""}`,
              null,
              n.content || "" // 经文引用只按正文统计（与讨论页筛选口径一致，标题不计）
            );
          }
          if (batch.length < 1000 || scanned >= cap) break;
          skip += 1000;
        }
        // 也聚合「经书讨论」集合：sutraTitle 计入经文榜，content 里若含 #话题
        // 也计入话题榜，使经书讨论页与话题讨论页在同款热度榜上按热度排序展示。
        try {
          await ensureSutraDiscussions();
          let sdSkip = 0;
          const sdCap = 2000;
          let sdScanned = 0;
          while (sdScanned < sdCap) {
            const sr = await sutraDiscussions
              .orderBy("createdAt", "desc")
              .skip(sdSkip)
              .limit(1000)
              .get();
            const sBatch = sr.data || [];
            if (sBatch.length === 0) break;
            for (const d of sBatch) {
              if (++sdScanned > sdCap) break;
              aggregateRecord(
                d.createdAt,
                d.likeCount,
                0, // 经书讨论没有 viewCount
                0, // 没有 commentCount
                0, // 没有 repostCount
                d.content || "", // 正文里的 #话题 仍计入话题榜
                d.sutraTitle || "",
                null // 讨论正文里的 $经名 不再重复计入经文榜（与讨论页展示口径一致）
                // 注：经书讨论没有浏览/评论/转发数，engagement 只由「4 点基础
                // 热度 + 赞×3」构成，不会是 0 分——只出现在经书讨论里的 #话题
                // 也能正常进榜（旧公式下无赞即 0 分，永远垫底）。
              );
            }
            if (sBatch.length < 1000 || sdScanned >= sdCap) break;
            sdSkip += 1000;
          }
        } catch (e) {
          // 经书讨论集合读取失败时静默降级：话题榜不受影响。
        }
        const sortBy = (a, b) => b[1].score - a[1].score || b[1].last - a[1].last;
        const topTopics = [...topics.entries()]
          .sort(sortBy)
          .slice(0, 200)
          .map(([name, v]) => ({
            name,
            posts: v.posts,
            score: Math.round(v.score * 10) / 10,
          }));
        const topSutras = [...sutras.entries()]
          .sort(sortBy)
          .slice(0, 200)
          .map(([name, v]) => ({
            name,
            posts: v.posts,
            score: Math.round(v.score * 10) / 10,
          }));
        const data = { topics: topTopics, sutras: topSutras, updatedAt: nowMs };
        hotDiscussionsCache = { at: nowMs, data };
        return ok(data);
      }

      // 菩提空间热门经文榜：按「累计提及数」统计，不设时间窗口，
      // 规则与经书讨论页展示口径一致：
      // - 广场帖子正文里的 $经名/@经名 引用（识别规则与客户端 referencesSutra 相同），
      //   同一帖子多次提及同一经书只算一次（按帖去重）；
      // - 经书讨论页里发布的每条讨论（sutraDiscussions）算对该经书的一次提及
      //   （讨论自动挂在其 sutraTitle 下，讨论正文里的其它 $经名 不重复计入）；
      // - 阅读页右下角发出的笔记本质是带 $经名 的广场帖，已包含在第一条里。
      // 只要有 1 次提及就入榜；提及次数越多热度越高，score 即累计提及次数。
      // 不设窗口是为了让榜单常驻：早期最冷的 30 天里若没人发新讨论，旧逻辑
      // 会让整张经文榜清空、经文行直接从界面消失。改为扫全库最新记录后，
      // 只要历史上被提及过一次就一直在榜，长期没有新讨论也照常显示。
      case "getHotSutraMentions": {
        const nowMs = Date.now();
        if (hotSutraMentionsCache && nowMs - hotSutraMentionsCache.at < 15 * 60 * 1000) {
          return ok({ ...hotSutraMentionsCache.data, cached: true });
        }
        const sutraRe = /[@$]([^\s#$，。！？,;:!?（）()@[\]]+)/g;
        const sutraBeforeRe = /[0-9A-Za-z\u4e00-\u9fa5]/;
        const mentions = new Map(); // name -> { posts, last }
        const addMention = (name, createdAt) => {
          const cur = mentions.get(name) || { posts: 0, last: 0 };
          cur.posts += 1;
          if ((createdAt || 0) > cur.last) cur.last = createdAt || 0;
          mentions.set(name, cur);
        };
        // 广场帖子：公开帖按 createdAt 倒序扫，正文含 $经名 引用即计一次（按帖去重）。
        // 不加时间窗口条件，扫描量与旧实现一致（最多 mentionCap 条），
        // 查询形状也与 getHotDiscussions 的 hotBase 完全同形，复用同一复合索引。
        // 边界：全库公开帖超过 mentionCap 后，最老的帖子扫不到，其经书
        // 若近期无新提及就不会入榜——这是为「成本零增加」刻意接受的取舍。
        const mentionBase = notes.where({
          visibility: "public",
          status: "normal",
          kind: _.neq("announcement"),
        });
        const mentionCap = 10000;
        let mScanned = 0;
        let mSkip = 0;
        while (mScanned < mentionCap) {
          const r = await mentionBase
            .orderBy("createdAt", "desc")
            .skip(mSkip)
            .limit(1000)
            .get();
          const batch = r.data || [];
          if (batch.length === 0) break;
          for (const n of batch) {
            if (++mScanned > mentionCap) break;
            const text = n.content || "";
            if (!text) continue;
            sutraRe.lastIndex = 0;
            const seen = new Set();
            let m;
            while ((m = sutraRe.exec(text)) !== null) {
              const markerIdx = m.index;
              const before = markerIdx > 0 ? text[markerIdx - 1] : "";
              if (sutraBeforeRe.test(before)) continue;
              // [@账号](user:...) 是用户提及，不是经文引用。
              if (text.startsWith("](user:", markerIdx + m[0].length)) continue;
              const s = m[1];
              if (!s || s.length > 24 || seen.has(s)) continue;
              seen.add(s);
              addMention(s, n.createdAt);
            }
          }
          if (batch.length < 1000 || mScanned >= mentionCap) break;
          mSkip += 1000;
        }
        // 经书讨论页的讨论：每条讨论算对其 sutraTitle 的一次提及。
        // 同样去掉时间窗口，只按 createdAt 倒序扫，扫描量上限 dCap 不变。
        try {
          await ensureSutraDiscussions();
          let dSkip = 0;
          const dCap = 5000;
          let dScanned = 0;
          while (dScanned < dCap) {
            const dr = await sutraDiscussions
              .orderBy("createdAt", "desc")
              .skip(dSkip)
              .limit(1000)
              .get();
            const dBatch = dr.data || [];
            if (dBatch.length === 0) break;
            for (const d of dBatch) {
              if (++dScanned > dCap) break;
              const s = String(d.sutraTitle || "").trim();
              if (s && s.length <= 24) addMention(s, d.createdAt);
            }
            if (dBatch.length < 1000 || dScanned >= dCap) break;
            dSkip += 1000;
          }
        } catch (e) {
          // 经书讨论集合读取失败时静默降级：广场帖的提及计数不受影响。
        }
        const topMentions = [...mentions.entries()]
          .sort((a, b) => b[1].posts - a[1].posts || b[1].last - a[1].last)
          .slice(0, 200)
          .map(([name, v]) => ({ name, posts: v.posts, score: v.posts }));
        const mData = { sutras: topMentions, updatedAt: nowMs };
        hotSutraMentionsCache = { at: nowMs, data: mData };
        return ok(mData);
      }

      case "getPopularSutras": {
        const nowMs = Date.now();
        if (popularSutrasCache && nowMs - popularSutrasCache.at < 15 * 60 * 1000) {
          return ok({ ...popularSutrasCache.data, cached: true });
        }
        const sutraCounts = new Map(); // title -> count
        const sutraPaths = new Map();  // title -> most common filePath
        const cap = 5000;
        let scanned = 0;
        let skip = 0;
        while (scanned < cap) {
          const r = await userData.orderBy("createdAt", "desc").skip(skip).limit(1000).get();
          const batch = r.data || [];
          if (batch.length === 0) break;
          for (const row of batch) {
            if (++scanned > cap) break;
            const prefs = (row.payload && row.payload.prefs) || {};
            const locked = prefs.locked_sutras;
            if (!Array.isArray(locked)) continue;
            const seen = new Set();
            for (const e of locked) {
              const s = String(e || "");
              if (!s) continue;
              const idx = s.indexOf("|||");
              const title = idx > 0 ? s.slice(0, idx) : s;
              const filePath = idx > 0 ? s.slice(idx + 3) : "";
              if (seen.has(title)) continue;
              seen.add(title);
              sutraCounts.set(title, (sutraCounts.get(title) || 0) + 1);
              if (filePath && !sutraPaths.has(title)) sutraPaths.set(title, filePath);
            }
          }
          if (batch.length < 1000 || scanned >= cap) break;
          skip += 1000;
        }
        const top = [...sutraCounts.entries()]
          .sort((a, b) => b[1] - a[1])
          .slice(0, 50)
          .map(([title, count]) => ({
            title,
            count,
            filePath: sutraPaths.get(title) || "",
          }));
        const pdata = { sutras: top, updatedAt: nowMs };
        popularSutrasCache = { at: nowMs, data: pdata };
        return ok(pdata);
      }

      case "getNoteById": {
        const id = String(event.id || "");
        const { data } = await notes.doc(id).get();
        const note = data && data[0];
        if (!note) return fail("not_found");
        if (note.status === "hidden" && note.ownerUserId !== uid) {
          return fail("not_found");
        }
        if (note.visibility !== "public" && note.ownerUserId !== uid) {
          return fail("not_found");
        }
        await attachAuthorAccounts([note]);
        await attachAuthorVerified([note]);
        await attachAuthorCanonProgress([note]);
        return ok({ note });
      }

      // 阅读量 +1（打开详情页时调用一次）。数值类型强制为数字，避免历史脏数据（字符串）导致串接。
      case "incView": {
        const id = String(event.id || "");
        const { data } = await notes.doc(id).get();
        const note = data && data[0];
        if (!note) return fail("not_found");
        if (note.visibility !== "public" && note.ownerUserId !== uid) {
          return fail("not_found");
        }
        const prev = Math.floor(Number(note.viewCount) || 0);
        const viewCount = Number.isFinite(prev) ? prev + 1 : 1;
        await notes.doc(id).update({ viewCount });
        return ok({ viewCount });
      }

      // 转发：以当前用户身份创建一条新笔记，并关联原笔记。
      // quote 为空 → 直接转发（内容与原笔记相同）；quote 非空 → 引用转发（内容为用户的引言 + 原笔记快照）。
      case "repostNote": {
        if (!uid) return fail("unauthorized");
        const id = String(event.id || "");
        const quote = String(event.quote || "").trim().slice(0, 500);
        const repostKind =
          event.kind === "reply"
            ? "reply"
            : quote
              ? "quote"
              : "forward";
        const { data } = await notes.doc(id).get();
        const src = data && data[0];
        if (!src) return fail("not_found");
        if (src.visibility !== "public" || src.status !== "normal") {
          return fail("not_found");
        }
        const base = {
          ownerUserId: uid,
          visibility: "public",
          authorName: String(event.authorName || "同修").slice(0, 30),
          likeCount: 0,
          commentCount: 0,
          viewCount: 0,
          repostCount: 0,
          repostOf: id,
          repostSourceAuthor: String(src.authorName || "同修").slice(0, 30),
          repostSourceUserId: String(src.ownerUserId || ""),
          repostKind,
          status: "normal",
          createdAt: now(),
          updatedAt: now(),
        };
        if (quote) {
          base.title = String(src.title || "无标题").slice(0, 100);
          base.content = quote;
          base.quoteContent = quote;
          base.quoteOfTitle = String(src.title || "无标题").slice(0, 100);
          base.quoteOfContent = String(src.content || "").slice(0, 500);
        } else {
          // 直接转发：正文留空（只转发不附内容），保留原帖快照供展示。
          base.title = String(src.title || "无标题").slice(0, 100);
          base.content = "";
          base.quoteOfTitle = String(src.title || "无标题").slice(0, 100);
          base.quoteOfContent = String(src.content || "").slice(0, 500);
        }
        const res = await notes.add(base);
        // 转发量只统计「直接转发/引用转发」；回复帖（kind='reply'）属于评论行为，
        // 评论量已由 createComment 增加，这里不再重复累计原帖转发量。
        if (repostKind !== "reply") {
          await notes.doc(id).update({
            repostCount: (src.repostCount || 0) + 1,
          });
        }
        const newTitle = String(base.title || "无标题").slice(0, 100);
        const reposterName = String(event.authorName || "同修").slice(0, 30);
        await activities.add({
          userId: uid,
          type: "repost",
          direction: "out",
          noteId: res.id,
          noteTitle: newTitle,
          sourceTitle: String(src.title || "无标题").slice(0, 100),
          content: quote,
          viewed: false,
          createdAt: now(),
        });
        // 回复帖（kind='reply'）：作者已在 createComment 中收到「回复」通知，不再重复发「转发」通知。
        if (src.ownerUserId && src.ownerUserId !== uid && repostKind !== "reply") {
          await activities.add({
            userId: src.ownerUserId,
            type: "repost_me",
            direction: "in",
            noteId: res.id,
            noteTitle: newTitle,
            sourceTitle: String(src.title || "无标题").slice(0, 100),
            content: quote,
            contentPreview: previewText(src.content),
            actorId: uid,
            actorName: reposterName,
            viewed: false,
            createdAt: now(),
          });
          console.log(`[api/repostNote] repost_me notification created: noteOwner=${src.ownerUserId} actor=${uid} repostKind=${repostKind}`);
        } else {
          console.log(`[api/repostNote] repost_me notification skipped: ownerUserId=${src.ownerUserId || "(empty)"} uid=${uid} self=${src.ownerUserId === uid} repostKind=${repostKind}`);
        }
        return ok({ id: res.id });
      }

      // ==================== 笔记收藏 ====================

      case "getFavoriteNoteIds": {
        if (!uid) return ok({ ids: [] });
        const res = await favorites
          .where({ userId: uid })
          .limit(1000)
          .get();
        return ok({ ids: res.data.map((r) => r.noteId) });
      }

      case "toggleNoteFavorite": {
        if (!uid) return fail("unauthorized");
        const noteId = String(event.noteId || "");
        const { data } = await notes.doc(noteId).get();
        const note = data && data[0];
        if (!note) return fail("not_found");
        const existing = await favorites.where({ noteId, userId: uid }).get();
        if (existing.data.length > 0) {
          await favorites.doc(existing.data[0]._id).remove();
          const fActs = await activities
            .where({ userId: note.ownerUserId, type: "favorite_me", noteId, actorId: uid })
            .limit(100)
            .get();
          for (const a of fActs.data || []) {
            await activities.doc(a._id).remove();
          }
          // 同时删除我收藏的"out"记录
          const myFavActs = await activities
            .where({ userId: uid, type: "favorite", noteId })
            .limit(100)
            .get();
          for (const a of myFavActs.data || []) {
            await activities.doc(a._id).remove();
          }
          return ok({ favorited: false });
        }
        await favorites.add({ noteId, userId: uid, createdAt: now() });
        // 记录我收藏了别人的帖子（用于"我的动态"）
        await activities.add({
          userId: uid,
          type: "favorite",
          direction: "out",
          noteId,
          noteTitle: String(note.title || "无标题").slice(0, 100),
          viewed: false,
          createdAt: now(),
        });
        if (note.ownerUserId && note.ownerUserId !== uid) {
          await activities.add({
            userId: note.ownerUserId,
            type: "favorite_me",
            direction: "in",
            noteId,
            noteTitle: String(note.title || "无标题").slice(0, 100),
            contentPreview: previewText(note.content),
            actorId: uid,
            actorName: String(event.authorName || "同修").slice(0, 30),
            viewed: false,
            createdAt: now(),
          });
        }
        return ok({ favorited: true });
      }

      case "getFavoriteNotes": {
        if (!uid) return fail("unauthorized");
        const res = await favorites
          .where({ userId: uid })
          .orderBy("createdAt", "desc")
          .limit(1000)
          .get();
        const ids = res.data.map((r) => r.noteId);
        const list = [];
        for (const nid of ids) {
          try {
            const { data: ndata } = await notes.doc(nid).get();
            const n = ndata && ndata[0];
            if (n && n.visibility === "public" && n.status === "normal") {
              list.push(n);
            }
          } catch (e) {}
        }
        await attachAuthorAccounts(list);
        await attachAuthorVerified(list);
        await attachAuthorCanonProgress(list);
        return ok({ notes: list });
      }

      // ==================== 关注 / 屏蔽 ====================

      case "getFollowingUserIds": {
        if (!uid) return ok({ ids: [] });
        const res = await follows
          .where({ followerId: uid })
          .limit(1000)
          .get();
        return ok({ ids: res.data.map((r) => r.followeeId) });
      }

      case "getFollowerUserIds": {
        if (!uid) return ok({ ids: [] });
        const res = await follows
          .where({ followeeId: uid })
          .limit(1000)
          .get();
        return ok({ ids: res.data.map((r) => r.followerId) });
      }

      // 批量获取用户展示信息（昵称/签名/加入时间）。名字取该用户最新一篇公开笔记的署名。
      case "getUserProfiles": {
        const ids = (Array.isArray(event.ids) ? event.ids.map(String) : [])
          .filter(Boolean)
          .slice(0, 200);
        const verified = {};
        if (ids.length > 0) {
          try {
            const { data } = await verifications
              .where({ uid: _.in(ids) })
              .get();
            for (const v of data || []) verified[v.uid] = true;
          } catch (e) {}
        }
        // 账号名称：userAccounts 中登记的 username；阅藏进度：同表 canonRead/canonTotal；
        // 读经时长：同表 readingSeconds（他人主页徽章点亮依据）；
        // ★ userAccounts.createdAt：用户首次创建 @账户 时写入，比同步 prefs 更接近真实注册时间。
        const accounts = {};
        const accountCreatedAt = {};
        const canonRead = {};
        const canonTotal = {};
        const readingSeconds = {};
        if (ids.length > 0) {
          try {
            await ensureUserAccounts();
            for (let i = 0; i < ids.length; i += 100) {
              const { data } = await userAccounts
                .where({ uid: _.in(ids.slice(i, i + 100)) })
                .get();
              for (const a of data || []) {
                // 同一 uid 存在多条历史记录时，空用户名/0 进度不得覆盖有效值，
                // 保证 @账号、阅藏百分比、读经时长的解析结果确定、不随查询顺序漂移。
                if (a.username) accounts[a.uid] = String(a.username);
                const read = Math.max(0, Number(a.canonRead) || 0);
                const total = Math.max(0, Number(a.canonTotal) || 0);
                const seconds = Math.max(0, Number(a.readingSeconds) || 0);
                if (total > 0 || canonRead[a.uid] == null) canonRead[a.uid] = read;
                if (total > 0 || canonTotal[a.uid] == null) canonTotal[a.uid] = total;
                if (seconds > 0 || readingSeconds[a.uid] == null) {
                  readingSeconds[a.uid] = seconds;
                }
                // 首次创建 @账户 的时间戳：多条记录时取最早（最接近真实注册时间）。
                const t = Number(a.createdAt) || 0;
                if (t > 0 &&
                    (accountCreatedAt[a.uid] == null ||
                     t < accountCreatedAt[a.uid])) {
                  accountCreatedAt[a.uid] = t;
                }
              }
            }
          } catch (e) {}
        }
        // ★ 最早笔记时间：仅当该用户连 userAccounts.createdAt 都没有时才需要扫
        //   notes 表兜底计算加入时间（有 @账户 的用户直接跳过）。此前每次调用都
        //   无脑拉 5000 条，数据量上来后云函数容易被拖到超时被杀，连带账号/认证/
        //   昵称全部不返回——这正是评论 @账号 与主页 @账户 时而丢失的根源。
        const notesFirstCreatedAt = {};
        if (ids.length > 0) {
          try {
            const needFallback = ids.filter((id) => !accountCreatedAt[id]);
            for (let i = 0; i < needFallback.length; i += 100) {
              const chunk = needFallback.slice(i, i + 100);
              if (chunk.length === 0) continue;
              // 上限 500：只需找到最早一条作为加入时间候选，足够。
              const { data } = await notes
                .where({ ownerUserId: _.in(chunk), status: "normal" })
                .orderBy("createdAt", "asc")
                .limit(500)
                .get();
              for (const n of data || []) {
                const t = Number(n.createdAt) || 0;
                if (t <= 0 || !n.ownerUserId) continue;
                const cur = notesFirstCreatedAt[n.ownerUserId];
                if (cur == null || t < cur) notesFirstCreatedAt[n.ownerUserId] = t;
              }
            }
          } catch (e) {}
        }
        // 昵称/签名/头像/横幅：从 userData.payload 取（由 SyncService 定期推送）。
        // ★ userData.createdAt（即 row.createdAt）= 用户首次同步时的写入时间戳，
        //   优先级高于 prefs.user_created_at（后者会被旧版本客户端的"兜底写入当前日期"污染）。
        const profiles = {};
        if (ids.length > 0) {
          try {
            const { data: ud } = await userData
              .where({ uid: _.in(ids) })
              .limit(1000)
              .get();
            for (const row of ud || []) {
              const payload = (row && row.payload) || {};
              const prefs = payload.prefs || {};
              const files = payload.files || {};
              const avatar = files.avatar;
              const banner = files.banner;
              // ★ 权威链：所有候选时间取「最老（最小）」的那个，
              //   即用户第一次在系统里留下痕迹的真实时间 = 实际"加入时间"。
              //   1) userAccounts.createdAt   （首次创建 @账户 时间，永不修改）
              //   2) notes 最早 createdAt       （第一篇笔记/回复时间，行为证据）
              //   3) userData.row.createdAt    （新部署后首次同步时间）
              //   4) prefs.user_created_at     （客户端同步备份，兼容历史）
              //   注意：**禁止用 userData.updatedAt**，它每次 push 都会刷新。
              const uid = row.uid;
              const c1 = accountCreatedAt[uid] || 0;
              const c2 = notesFirstCreatedAt[uid] || 0;
              const c3 = (row && row.createdAt) ? Number(row.createdAt) || 0 : 0;
              const c4 = Number(prefs.user_created_at) || 0;
              const candidates = [c1, c2, c3, c4].filter((v) => v > 0);
              const joinTime = candidates.length > 0 ? Math.min(...candidates) : 0;
              profiles[uid] = {
                nickname: String(prefs.user_nickname || "").slice(0, 30),
                tagline: String(prefs.user_tagline || "").slice(0, 60),
                joinTime,
                avatar:
                  avatar && typeof avatar.data === "string" && avatar.data
                    ? avatar.data
                    : "",
                banner:
                  banner && typeof banner.data === "string" && banner.data
                    ? banner.data
                    : "",
                // ★ 调试字段：查看是哪个源头决定了最终 joinTime。
                // 生产验证完可以删除，不影响客户端正常显示（客户端忽略多余字段）。
                _debugJoinCandidates: {
                  "① userAccounts.createdAt（首次创建@账号）": c1,
                  "② notes 最早 createdAt（第一篇笔记）": c2,
                  "③ userData.createdAt（首次同步）": c3,
                  "④ prefs.user_created_at（备份，可能被污染）": c4,
                  "最终 min（即显示的 joinTime）": joinTime,
                },
              };
            }
          } catch (e) {}
        }
        const users = [];
        for (const id of ids) {
          // 昵称优先取云同步的 user_nickname；未设置时回退到最近公开笔记的 authorName。
          const p = profiles[id] || {};
          let name = p.nickname || "同修";
          if (!name || name === "同修") {
            try {
              const { data: ndata } = await notes
                .where({ ownerUserId: id, visibility: "public", status: "normal" })
                .orderBy("createdAt", "desc")
                .limit(1)
                .get();
              const n = ndata && ndata[0];
              if (n && n.authorName) name = String(n.authorName);
            } catch (e) {}
          }
          // ★ 兜底：极个别极端用户既没有 userData 记录也没有昵称 fallback 的场景，
          //   仍然在最外层按同样规则计算一次 joinTime，避免显示"加入时间为 0"。
          let finalJoinTime = p.joinTime || 0;
          const c1Out = accountCreatedAt[id] || 0;
          const c2Out = notesFirstCreatedAt[id] || 0;
          if (finalJoinTime <= 0) {
            const candidates = [c1Out, c2Out, 0, 0].filter((v) => v > 0);
            if (candidates.length > 0) finalJoinTime = Math.min(...candidates);
          }
          const debug = p._debugJoinCandidates || {
            "① userAccounts.createdAt（首次创建@账号）": c1Out,
            "② notes 最早 createdAt（第一篇笔记）": c2Out,
            "③ userData.createdAt（首次同步）": 0,
            "④ prefs.user_created_at（备份，可能被污染）": 0,
            "最终 min（即显示的 joinTime）": finalJoinTime,
            "⚠️ 说明": "此用户无 userData 记录，仅返回外层兜底候选",
          };
          users.push({
            id,
            name,
            account: accounts[id] || "",
            verified: !!verified[id],
            tagline: p.tagline || "",
            joinTime: finalJoinTime,
            canonRead: canonRead[id] || 0,
            canonTotal: canonTotal[id] || 0,
            readingSeconds: readingSeconds[id] || 0,
            avatar: p.avatar || "",
            banner: p.banner || "",
            // ★ 调试字段：查看是哪个源头决定了最终 joinTime。
            // 部署验证完可以安全删除，客户端 UserProfile.fromJson 会忽略未知字段。
            _debugJoinCandidates: debug,
          });
        }
        return ok({ users });
      }

      // 查看他人主页的「精读/功课」数据（受隐私开关 privacy_show_reading / privacy_show_checkin 控制）。
      case "getUserHomeData": {
        const id = String(event.userId || "");
        if (!id) return ok({ readingAllowed: false, checkinAllowed: false, reading: [], checkin: null });
        const { data } = await userData.where({ uid: id }).limit(1).get();
        const row = data && data[0];
        const prefs = (row && row.payload && row.payload.prefs) || {};

        const readingAllowed = prefs.privacy_show_reading === true;
        const checkinAllowed = prefs.privacy_show_checkin === true;

        // 精读：该用户锁定过（含当前锁定）的经文，多本；当前锁定的一本置于最前。
        const reading = [];
        if (readingAllowed) {
          const items = [];
          if (Array.isArray(prefs.locked_sutras)) {
            for (const e of prefs.locked_sutras) {
              const s = String(e || "");
              if (!s) continue;
              const idx = s.indexOf("|||");
              items.push(
                idx > 0
                  ? { title: s.slice(0, idx), filePath: s.slice(idx + 3) }
                  : { title: s, filePath: "" }
              );
            }
          }
          const current = String(prefs.locked_sutra_title || "");
          // 旧版本数据兜底：有当前锁定但尚无锁定历史时，补上当前锁定。
          if (items.length === 0 && current) {
            items.push({
              title: current,
              filePath: String(prefs.locked_sutra_file_path || ""),
            });
          }
          items.sort((a, b) =>
            (a.title === current ? 0 : 1) - (b.title === current ? 0 : 1)
          );
          for (const it of items) reading.push(it);
        }
        const currentLockedTitle = readingAllowed
          ? String(prefs.locked_sutra_title || "")
          : "";

        // 功课：仅回传展示需要的打卡配置键，避免整包 payload 泄露其它数据。
        let checkin = null;
        if (checkinAllowed) {
          const keys = [
            "setting_meditation_minutes",
            "setting_reading_titles",
            "setting_mantra_items",
            "setting_buddha_items",
            "setting_copying_titles",
            "custom_checkin_types",
            "checkin_goals",
            "checkin_records",
          ];
          checkin = {};
          for (const k of keys) {
            if (prefs[k] != null) checkin[k] = prefs[k];
          }
        }
        return ok({ readingAllowed, checkinAllowed, reading, checkin, currentLockedTitle });
      }

      // 搜索用户账号：按账号前缀/包含匹配 userAccounts，返回匹配用户的账号与 uid。
      case "searchUsers": {
        const q = String(event.query || "").trim().toLowerCase();
        if (!q) return ok({ users: [] });
        await ensureUserAccounts();
        const esc = q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const { data } = await userAccounts
          .where({
            usernameKey: db.RegExp({ regexp: `^${esc}`, options: "i" }),
          })
          .limit(30)
          .get();
        const users = [];
        for (const a of data || []) {
          const uname = String(a.username || "");
          if (!uname) continue;
          users.push({ id: a.uid || "", account: uname, username: uname });
        }
        return ok({ users });
      }

      case "toggleFollow": {
        if (!uid) return fail("unauthorized");
        const target = String(event.targetUserId || "");
        if (!target || target === uid) return fail("invalid_target");
        const existing = await follows
          .where({ followerId: uid, followeeId: target })
          .get();
        if (existing.data.length > 0) {
          await follows.doc(existing.data[0]._id).remove();
          const fActs = await activities
            .where({ userId: target, type: "follow_me", actorId: uid })
            .limit(100)
            .get();
          for (const a of fActs.data || []) {
            await activities.doc(a._id).remove();
          }
          // 同时删除我关注的"out"记录
          const myFollowActs = await activities
            .where({ userId: uid, type: "follow" })
            .limit(100)
            .get();
          for (const a of myFollowActs.data || []) {
            await activities.doc(a._id).remove();
          }
          return ok({ following: false });
        }
        await follows.add({
          followerId: uid,
          followeeId: target,
          createdAt: now(),
        });
        // 记录我关注了别人（用于"我的动态"）
        await activities.add({
          userId: uid,
          type: "follow",
          direction: "out",
          noteId: "",
          noteTitle: "",
          viewed: false,
          createdAt: now(),
        });
        await activities.add({
          userId: target,
          type: "follow_me",
          direction: "in",
          noteId: "",
          noteTitle: "",
          contentPreview: "",
          actorId: uid,
          actorName: String(event.authorName || "同修").slice(0, 30),
          viewed: false,
          createdAt: now(),
        });
        console.log(`[api/toggleFollow] follow_me notification created: target=${target} actor=${uid}`);
        return ok({ following: true });
      }

      case "getBlockedUserIds": {
        if (!uid) return ok({ ids: [] });
        const res = await blocks
          .where({ blockerId: uid })
          .limit(1000)
          .get();
        return ok({ ids: res.data.map((r) => r.blockedId) });
      }

      case "toggleBlockUser": {
        if (!uid) return fail("unauthorized");
        const target = String(event.targetUserId || "");
        if (!target || target === uid) return fail("invalid_target");
        const existing = await blocks
          .where({ blockerId: uid, blockedId: target })
          .get();
        if (existing.data.length > 0) {
          await blocks.doc(existing.data[0]._id).remove();
          return ok({ blocked: false });
        }
        await blocks.add({
          blockerId: uid,
          blockedId: target,
          createdAt: now(),
        });
        return ok({ blocked: true });
      }

      // ==================== 点赞 ====================

      case "getLikedNoteIds": {
        if (!uid) return ok({ ids: [] });
        const res = await likes
          .where({ userId: uid })
          .limit(1000)
          .get();
        return ok({ ids: res.data.map((r) => r.noteId) });
      }

      case "getLikedNotes": {
        if (!uid) return fail("unauthorized");
        const lres = await likes
          .where({ userId: uid })
          .orderBy("createdAt", "desc")
          .limit(1000)
          .get();
        const ids = lres.data.map((r) => r.noteId);
        const list = [];
        for (const nid of ids) {
          try {
            const { data: ndata } = await notes.doc(nid).get();
            const n = ndata && ndata[0];
            if (n && n.visibility === "public" && n.status === "normal") {
              list.push(n);
            }
          } catch (e) {}
        }
        await attachAuthorAccounts(list);
        await attachAuthorVerified(list);
        await attachAuthorCanonProgress(list);
        return ok({ notes: list });
      }

      case "toggleLike": {
        if (!uid) return fail("unauthorized");
        const noteId = String(event.noteId || "");
        const { data } = await notes.doc(noteId).get();
        const note = data && data[0];
        if (!note) return fail("not_found");
        const existing = await likes.where({ noteId, userId: uid }).get();
        let likeCount;
        if (existing.data.length > 0) {
          await likes.doc(existing.data[0]._id).remove();
          likeCount = Math.max(0, (note.likeCount || 0) - 1);
          const likeActs = await activities
            .where({ userId: note.ownerUserId, type: "like_me", noteId, actorId: uid })
            .limit(100)
            .get();
          for (const a of likeActs.data || []) {
            await activities.doc(a._id).remove();
          }
          // 同时删除我点赞的"out"记录
          const myLikeActs = await activities
            .where({ userId: uid, type: "like", noteId })
            .limit(100)
            .get();
          for (const a of myLikeActs.data || []) {
            await activities.doc(a._id).remove();
          }
        } else {
          await likes.add({ noteId, userId: uid, createdAt: now() });
          likeCount = (note.likeCount || 0) + 1;
          // 记录我点赞了别人的帖子（用于"我的动态"）
          await activities.add({
            userId: uid,
            type: "like",
            direction: "out",
            noteId,
            noteTitle: String(note.title || "无标题").slice(0, 100),
            viewed: false,
            createdAt: now(),
          });
          if (note.ownerUserId && note.ownerUserId !== uid) {
            await activities.add({
              userId: note.ownerUserId,
              type: "like_me",
              direction: "in",
              noteId,
              noteTitle: String(note.title || "无标题").slice(0, 100),
              content: "",
              contentPreview: previewText(note.content),
              repostKind: String(note.repostKind || ""),
              actorId: uid,
              actorName: String(event.authorName || "同修").slice(0, 30),
              viewed: false,
              createdAt: now(),
            });
            console.log(`[api/toggleLike] notification created: noteOwner=${note.ownerUserId} actor=${uid} noteId=${noteId}`);
          } else {
            console.log(`[api/toggleLike] notification skipped: ownerUserId=${note.ownerUserId || "(empty)"} uid=${uid} self=${note.ownerUserId === uid}`);
          }
        }
        await notes.doc(noteId).update({ likeCount });
        return ok({ likeCount, liked: existing.data.length === 0 });
      }

      // ==================== 评论 ====================

      case "createComment": {
        if (!uid) return fail("unauthorized");
        const noteId = String(event.noteId || "");
        const content = String(event.content || "").slice(0, 200);
        if (!content) return fail("empty_comment");
        const { data } = await notes.doc(noteId).get();
        const note = data && data[0];
        if (!note) return fail("not_found");
        const res = await comments.add({
          noteId,
          authorId: uid,
          authorName: String(event.authorName || "同修").slice(0, 30),
          content,
          likeCount: 0,
          createdAt: now(),
        });
        await notes.doc(noteId).update({
          commentCount: (note.commentCount || 0) + 1,
        });
        const noteTitle = String(note.title || "无标题").slice(0, 100);
        const actorName = String(event.authorName || "同修").slice(0, 30);
        await activities.add({
          userId: uid,
          type: "comment",
          direction: "out",
          noteId,
          noteTitle,
          content,
          commentId: res.id,
          actorId: uid,
          actorName,
          viewed: false,
          createdAt: now(),
        });
        if (note.ownerUserId && note.ownerUserId !== uid) {
          await activities.add({
            userId: note.ownerUserId,
            type: "reply",
            direction: "in",
            noteId,
            noteTitle,
            content,
            contentPreview: previewText(note.content),
            commentId: res.id,
            actorId: uid,
            actorName,
            viewed: false,
            createdAt: now(),
          });
          console.log(`[api/createComment] reply notification created: noteOwner=${note.ownerUserId} actor=${uid} noteId=${noteId}`);
        } else {
          console.log(`[api/createComment] reply notification skipped: ownerUserId=${note.ownerUserId || "(empty)"} uid=${uid} self=${note.ownerUserId === uid}`);
        }
        // @提及：评论中 @其他同修时给对方发通知。
        // 若该同修已在同帖评论过，则视为「回复我的评论」；否则为「@提及我」。
        const mentioned = extractMentions(content);
        for (const uname of mentioned) {
          let acc = null;
          try {
            const { data: ua } = await userAccounts
              .where({ usernameKey: uname.toLowerCase() })
              .limit(1)
              .get();
            acc = ua && ua[0];
          } catch (e) {}
          if (!acc || !acc.uid || acc.uid === uid) continue;
          if (acc.uid === note.ownerUserId) continue; // 帖子作者已有 reply 通知
          let type = "mention";
          try {
            const cBefore = await comments
              .where({ noteId, authorId: acc.uid })
              .limit(1)
              .get();
            if (cBefore.data.length > 0) type = "comment_reply";
          } catch (e) {}
          await activities.add({
            userId: acc.uid,
            type,
            direction: "in",
            noteId,
            noteTitle,
            content,
            contentPreview: previewText(note.content),
            commentId: res.id,
            actorId: uid,
            actorName,
            viewed: false,
            createdAt: now(),
          });
        }
        // 记录我在评论中@了别人（用于"我的动态"）
        if (mentioned.length > 0) {
          await activities.add({
            userId: uid,
            type: "mention_out",
            direction: "out",
            noteId,
            noteTitle,
            content,
            commentId: res.id,
            viewed: false,
            createdAt: now(),
          });
        }
        return ok({ comment: { _id: res.id, noteId, authorId: uid, authorName: actorName, authorAccount: await getAccountName(uid), content, likeCount: 0, createdAt: now() } });
      }

      // ==================== 菩提空间：我的互动动态 ====================

      case "getMyActivities": {
        if (!uid) return fail("unauthorized");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 20, 50);
        // 分批拉取：每批1000条活动，内存过滤出"我的动态"，直到凑够当前页所需数量。
        const needed = page * pageSize;
        const allMy = [];
        let skip = 0;
        const batchSize = 1000;
        const maxBatches = 3;

        for (let i = 0; i < maxBatches && allMy.length < needed; i++) {
          const res = await activities
            .where({ userId: uid })
            .orderBy("createdAt", "desc")
            .skip(skip)
            .limit(batchSize)
            .get();
          const rows = res.data || [];
          const batch = rows.filter((a) => {
            if (a.direction === "out") return true;
            if (!a.direction && !receivedTypes.includes(a.type)) return true;
            return false;
          });
          allMy.push(...batch);
          skip += batchSize;
          if (rows.length < batchSize) break;
        }

        const total = allMy.length;
        const start = (page - 1) * pageSize;
        const items = allMy.slice(start, start + pageSize);
        return ok({
          activities: items,
          total,
          hasMore: start + items.length < total,
        });
      }

      // ==================== 我的主页角标：互动未读数 / 关注数 / 粉丝数 ====================

      case "getMyCounts": {
        if (!uid) return ok({ following: 0, followers: 0, unread: 0 });
        const [f, fl, ...unreadCounts] = await Promise.all([
          follows.where({ followerId: uid }).limit(1000).get(),
          follows.where({ followeeId: uid }).limit(1000).get(),
          ...receivedTypes.map((t) =>
            activities
              .where({ userId: uid, type: t, viewed: false })
              .count()
          ),
        ]);
        return ok({
          following: f.data.length,
          followers: fl.data.length,
          unread: unreadCounts.reduce((s, r) => s + (r.total || 0), 0),
        });
      }

      case "getComments": {
        const noteId = String(event.noteId || "");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 50, 100);
        const res = await comments
          .where({ noteId })
          .orderBy("createdAt", "asc")
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        const list = res.data || [];
        // 附加每条评论作者的账号名与认证标记，供详情页展示 @账号 与认证图标。
        await attachCommentAuthorInfo(list);
        // 附加当前用户对每条评论的点赞状态，供详情页恢复点亮状态。
        if (uid && list.length > 0) {
          try {
            await ensureCommentLikes();
            const ids = list.map((c) => c._id);
            const { data: cl } = await commentLikes
              .where({ userId: uid, commentId: _.in(ids) })
              .limit(100)
              .get();
            const likedSet = new Set((cl || []).map((l) => l.commentId));
            for (const c of list) c.liked = likedSet.has(c._id);
          } catch (e) {}
        }
        return ok({ comments: list });
      }

      // 某帖子的回复帖列表（含所有层级的回复，最早在前）。
      // 广场列表只展示自己/关注用户的回复，他人回复统一在本接口按帖聚合，供详情页成链展示。
      case "getNoteReplies": {
        const noteId = String(event.noteId || "");
        if (!noteId) return fail("not_found");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 50, 100);
        // 递归收集所有后代回复（含对回复的回复），按时间正序。
        const collected = [];
        const seen = new Set([noteId]);
        let frontier = [noteId];
        let level = 0;
        while (frontier.length > 0 && level < 12) {
          const next = [];
          for (let i = 0; i < frontier.length; i += 10) {
            const chunk = frontier.slice(i, i + 10);
            const r = await notes
              .where({
                repostOf: _.in(chunk),
                visibility: "public",
                status: "normal",
              })
              .limit(1000)
              .get();
            for (const n of r.data || []) {
              if (n._id && !seen.has(n._id)) {
                seen.add(n._id);
                collected.push(n);
                next.push(n._id);
              }
            }
          }
          frontier = next;
          level++;
        }
        collected.sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));
        let blocked = [];
        if (uid) {
          const br = await blocks.where({ blockerId: uid }).limit(1000).get();
          blocked = br.data.map((r) => r.blockedId);
        }
        const filterBlocked = (arr) =>
          blocked.length
            ? arr.filter(
                (n) =>
                  n.ownerUserId === uid ||
                  (!blocked.includes(n.ownerUserId) &&
                    !(
                      n.repostSourceUserId &&
                      blocked.includes(n.repostSourceUserId)
                    ))
              )
            : arr;
        const filtered = filterBlocked(collected);
        const total = filtered.length;
        const pageNotes = filtered.slice(
          (page - 1) * pageSize,
          (page - 1) * pageSize + pageSize
        );
        await attachAuthorAccounts(pageNotes);
        await attachAuthorVerified(pageNotes);
        await attachAuthorCanonProgress(pageNotes);
        return ok({
          notes: pageNotes,
          total,
          hasMore: (page - 1) * pageSize + pageNotes.length < total,
        });
      }

      case "toggleCommentLike": {
        if (!uid) return fail("unauthorized");
        await ensureCommentLikes();
        const commentId = String(event.commentId || "");
        const { data } = await comments.doc(commentId).get();
        const comment = data && data[0];
        if (!comment) return fail("not_found");
        const existing = await commentLikes
          .where({ commentId, userId: uid })
          .get();
        let likeCount;
        if (existing.data.length > 0) {
          await commentLikes.doc(existing.data[0]._id).remove();
          likeCount = Math.max(0, (comment.likeCount || 0) - 1);
        } else {
          await commentLikes.add({ commentId, userId: uid, createdAt: now() });
          likeCount = (comment.likeCount || 0) + 1;
        }
        await comments.doc(commentId).update({ likeCount });
        return ok({ likeCount, liked: existing.data.length === 0 });
      }

      // ==================== 消息中心 ====================

      // 拉取「收到的互动」通知列表（分页，最新在前）。不自动标记已读，
      // 只有用户真正查看对应通知或执行「全部标记已读」后未读数才减少。
      // 按 direction:"in" 从数据库直接过滤，拉到的全部是有效通知。
      case "getNotifications": {
        if (!uid) return fail("unauthorized");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 20, 50);

        // 分批拉取：每批1000条活动，内存过滤出通知，直到凑够当前页所需数量。
        // 解决"我的动态"太多导致1000条里通知只覆盖最近1-2天的问题。
        // 通常1-2批就够（第1页只需20条通知），不会明显变慢。
        const needed = page * pageSize;
        const allNotif = [];
        let skip = 0;
        const batchSize = 1000;
        const maxBatches = 3; // 最多拉3批（3000条活动），平衡速度和覆盖范围

        for (let i = 0; i < maxBatches && allNotif.length < needed; i++) {
          const res = await activities
            .where({ userId: uid })
            .orderBy("createdAt", "desc")
            .skip(skip)
            .limit(batchSize)
            .get();
          const rows = res.data || [];
          const batch = rows.filter((a) => {
            if (a.direction === "in") return true;
            if (!a.direction && receivedTypes.includes(a.type)) return true;
            return false;
          });
          allNotif.push(...batch);
          skip += batchSize;
          // 这批返回不足1000条，说明没有更多数据了
          if (rows.length < batchSize) break;
        }

        const total = allNotif.length;

        // 内存分页
        const start = (page - 1) * pageSize;
        const items = allNotif.slice(start, start + pageSize);

        console.log(`[api/getNotifications] uid=${uid} page=${page} returned=${items.length} total=${total}`);
        // 拉取互动用户头像（base64，存于 userData.payload.files.avatar）、
        // 账号名与认证状态，消息页直接展示真实头像而非默认 App 图标。
        const actorIds = [...new Set(items.map((a) => a.actorId).filter(Boolean))];
        const avatars = {};
        const accounts = {};
        const verified = {};
        const nicknames = {};
        if (actorIds.length > 0) {
          try {
            await ensureUserAccounts();
            for (let i = 0; i < actorIds.length; i += 100) {
              const chunk = actorIds.slice(i, i + 100);
              const { data: ua } = await userAccounts
                .where({ uid: _.in(chunk) })
                .get();
              for (const a of ua || []) accounts[a.uid] = a.username || "";
            }
          } catch (e) {}
          try {
            const { data: vd } = await verifications
              .where({ uid: _.in(actorIds) })
              .get();
            for (const v of vd || []) verified[v.uid] = true;
          } catch (e) {}
          try {
            const { data: ud } = await userData
              .where({ uid: _.in(actorIds) })
              .limit(1000)
              .get();
            for (const row of ud || []) {
              const payload = (row && row.payload) || {};
              const files = payload.files || {};
              const prefs = payload.prefs || {};
              const av = files.avatar;
              if (av && typeof av.data === "string" && av.data) {
                avatars[row.uid] = av.data;
              }
              // 补全真实昵称：修复历史 activity 记录中 actorName 为"同修"的问题。
              const nick = String(prefs.user_nickname || "").slice(0, 30);
              if (nick) nicknames[row.uid] = nick;
            }
          } catch (e) {}
        }
        for (const a of items) {
          if (avatars[a.actorId]) a.actorAvatar = avatars[a.actorId];
          if (accounts[a.actorId]) a.actorAccount = accounts[a.actorId];
          if (verified[a.actorId]) a.actorVerified = true;
          // actorName 为"同修"或空时，用 userData 中的真实昵称补全。
          if (nicknames[a.actorId] && (!a.actorName || a.actorName === "同修")) {
            a.actorName = nicknames[a.actorId];
          }
        }
        return ok({
          activities: items,
          total,
          hasMore: (page - 1) * pageSize + items.length < total,
        });
      }

      // 消息中心未读数（覆盖点赞/评论/回复评论/转发/收藏/关注/@提及）。
      case "getNotificationUnreadCount": {
        if (!uid) return ok({ unread: 0 });
        // 兼容旧数据：旧记录没有 direction 字段。
        // receivedTypes 只含通知类型（like_me/reply/...），新"out"记录用不同类型名（like/favorite/...），
        // 所以不加 direction 过滤也不会误计"我的动态"。
        const counts = await Promise.all(
          receivedTypes.map((t) =>
            activities.where({ userId: uid, type: t, viewed: false }).count()
          )
        );
        let unread = 0;
        for (const r of counts) unread += r.total || 0;
        return ok({ unread });
      }

      // 标记通知已读：传 ids 标记指定通知；all=true 全部标记已读。
      case "markNotificationsRead": {
        if (!uid) return fail("unauthorized");
        if (event.all === true) {
          // 兼容旧数据：标记所有通知类型未读记录为已读。
          // receivedTypes 只含通知类型，新"out"记录用不同类型名，不会误标。
          await Promise.all(
            receivedTypes.map((t) =>
              activities
                .where({ userId: uid, type: t, viewed: false })
                .update({ viewed: true })
            )
          );
          return ok({});
        }
        const ids = (Array.isArray(event.ids) ? event.ids : [])
          .map(String)
          .filter(Boolean);
        for (const id of ids) {
          try {
            await activities.doc(id).update({ viewed: true });
          } catch (e) {}
        }
        return ok({});
      }

      // 删除通知（长按删除指定通知）。
      case "deleteNotifications": {
        if (!uid) return fail("unauthorized");
        const ids = (Array.isArray(event.ids) ? event.ids : [])
          .map(String)
          .filter(Boolean);
        for (const id of ids) {
          try {
            await activities.doc(id).remove();
          } catch (e) {}
        }
        return ok({});
      }

      case "deleteComment": {
        if (!uid) return fail("unauthorized");
        const commentId = String(event.commentId || "");
        const { data } = await comments.doc(commentId).get();
        const comment = data && data[0];
        if (!comment) return fail("not_found");
        if (comment.authorId !== uid) {
          const note = await getOwnedNote(notes, comment.noteId, uid);
          if (!note) return fail("forbidden");
        }
        await comments.doc(commentId).remove();
        const linked = await activities.where({ commentId }).limit(100).get();
        for (const a of linked.data || []) {
          await activities.doc(a._id).remove();
        }
        const note = await getNote(notes, comment.noteId);
        if (note) {
          await notes.doc(comment.noteId).update({
            commentCount: Math.max(0, (note.commentCount || 0) - 1),
          });
        }
        return ok({});
      }

      // ==================== 经书讨论（跨用户共享） ====================

      // 拉取某本经书的讨论（公开可读，最新在前）。
      case "getSutraDiscussions": {
        const sutraTitle = String(event.sutraTitle || "").trim().slice(0, 200);
        if (!sutraTitle) return fail("bad_request");
        await ensureSutraDiscussions();
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 50, 100);
        const base = sutraDiscussions.where({ sutraTitle });
        const res = await base
          .orderBy("createdAt", "desc")
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        const { total } = await base.count();
        await attachAuthorAccounts(res.data);
        await attachAuthorVerified(res.data);
        await attachAuthorCanonProgress(res.data);
        return ok({
          discussions: res.data,
          total,
          hasMore: (page - 1) * pageSize + res.data.length < total,
        });
      }

      // 发表经书讨论（需登录）。
      case "createSutraDiscussion": {
        if (!uid) return fail("unauthorized");
        await ensureSutraDiscussions();
        const sutraTitle = String(event.sutraTitle || "").trim().slice(0, 200);
        const content = String(event.content || "").trim().slice(0, 500);
        if (!sutraTitle) return fail("bad_request");
        if (!content) return fail("empty_comment");
        const createdAt = now();
        const res = await sutraDiscussions.add({
          sutraTitle,
          ownerUserId: uid,
          authorName: String(event.authorName || "同修").slice(0, 30),
          content,
          likeCount: 0,
          createdAt,
          updatedAt: createdAt,
        });
        // 新经书讨论会按 sutraTitle 计入经文热度榜，立即失效缓存让下次拉取能看到新讨论。
        hotDiscussionsCache = null;
        hotSutraMentionsCache = null;
        return ok({ id: res.id, createdAt });
      }

      // 删除自己的经书讨论。
      case "deleteSutraDiscussion": {
        if (!uid) return fail("unauthorized");
        const discussionId = String(event.discussionId || "");
        if (!discussionId) return fail("bad_request");
        const doc = sutraDiscussions.doc(discussionId);
        const existing = await doc.get();
        if (!existing.data || !existing.data._id) return fail("not_found");
        if (existing.data.ownerUserId !== uid) return fail("forbidden");
        await doc.remove();
        // 经书讨论删除会影响经文热度榜，重新聚合。
        hotDiscussionsCache = null;
        hotSutraMentionsCache = null;
        return ok({});
      }

      // ==================== 管理员编辑经文 / 用户更新排版 ====================

      // 管理员保存「编辑经文」的最新排版。
      // 1. 写入 GitHub 仓库 assets/sutras_edited/<卷>/<ID>.txt（原始版 sutras_ascii 不动）
      // 2. 在云端 sutraEdits 记录版本时间戳与内容，供「更新排版」实时判断是否有新版。
      case "sutraEditSave": {
        if (!uid) return fail("unauthorized");
        await ensureAdmins();
        if (!(await isAdminUser(uid))) return fail("forbidden");
        const id = String(event.id || "").trim();
        const content = String(event.content ?? "");
        if (!/^T\d{2}n\d{4}[A-Za-z]?_\d{3}$/.test(id)) return fail("bad_request");
        if (!content.trim()) return fail("empty_content");
        const vol = id.substring(0, 3);
        const gitPath = `assets/sutras_edited/${vol}/${id}.txt`;
        const gitMsg = `编辑经文 ${id}：更新排版`;
        try {
          await githubWriteFile({
            repo: "dalidakun/huideng",
            path: gitPath,
            content,
            message: gitMsg,
          });
        } catch (e) {
          return fail("github_write_failed:" + (e && e.message ? e.message : ""));
        }
        // 正文全文只存 GitHub（sutras_edited），与现有下载模式一致。
        // 云端 sutraEdits 仅记录每部经的轻量版本时间戳（几十字节），
        // 供「更新排版」实时判断是否有新版，避免 GitHub CDN 缓存导致判断滞后。
        await ensureSutraEdits();
        const updatedAt = now();
        const existing = await sutraEdits.where({ id }).limit(1).get();
        if (existing.data && existing.data.length > 0) {
          await sutraEdits.doc(existing.data[0]._id).update({
            updatedAt,
            updatedBy: uid,
          });
        } else {
          await sutraEdits.add({
            id,
            updatedAt,
            updatedBy: uid,
            createdAt: updatedAt,
          });
        }
        return ok({ updatedAt });
      }

      // 取某部经文的编辑版元信息（是否有管理员编辑版及其更新时间）。
      // 供「更新排版」判断：updatedAt 比本地记录的版本新，即代表有新版可用。
      case "sutraEditMeta": {
        const id = String(event.id || "").trim();
        if (!id) return fail("bad_request");
        await ensureSutraEdits();
        const existing = await sutraEdits.where({ id }).limit(1).get();
        if (existing.data && existing.data.length > 0) {
          const r = existing.data[0];
          return ok({ found: true, updatedAt: r.updatedAt || 0 });
        }
        return ok({ found: false, updatedAt: 0 });
      }

      // 管理员撤销「完成排版」：删除 GitHub 编辑版文件 + 云端 sutraEdits 记录，
      // 使该经恢复「未编辑」状态（所有用户显示原始版）。
      case "sutraEditDelete": {
        if (!uid) return fail("unauthorized");
        await ensureAdmins();
        if (!(await isAdminUser(uid))) return fail("forbidden");
        const id = String(event.id || "").trim();
        if (!/^T\d{2}n\d{4}[A-Za-z]?_\d{3}$/.test(id)) return fail("bad_request");
        const vol = id.substring(0, 3);
        const gitPath = `assets/sutras_edited/${vol}/${id}.txt`;
        try {
          await githubDeleteFile({
            repo: "dalidakun/huideng",
            path: gitPath,
            message: `撤销经文排版 ${id}`,
          });
        } catch (e) {
          return fail("github_delete_failed:" + (e && e.message ? e.message : ""));
        }
        await ensureSutraEdits();
        const existing = await sutraEdits.where({ id }).limit(1).get();
        if (existing.data && existing.data.length > 0) {
          await sutraEdits.doc(existing.data[0]._id).remove();
        }
        return ok({ removed: true });
      }

      // ==================== 举报 ====================

      case "reportNote": {
        if (!uid) return fail("unauthorized");
        const noteId = String(event.noteId || "");
        const reason = String(event.reason || "").slice(0, 100);
        const existing = await reports.where({ noteId, userId: uid }).get();
        if (existing.data.length > 0) return ok({ already: true });
        await reports.add({ noteId, userId: uid, reason, createdAt: now() });
        const { total } = await reports.where({ noteId }).count();
        if (total >= 3) {
          await notes.doc(noteId).update({ status: "hidden" });
        }
        return ok({ total });
      }

      // ==================== 用户数据云同步 ====================

      case "getUserData": {
        if (!uid) return fail("unauthorized");
        const { data } = await userData.where({ uid }).limit(1).get();
        const row = data && data[0];
        return ok({
          hasData: !!row,
          payload: row ? row.payload || {} : {},
          updatedAt: row ? row.updatedAt || 0 : 0,
        });
      }

      // ==================== 用户私有笔记（一条笔记一个文档） ====================

      // 拉取个人笔记（含/不含回收站），按 (updatedAt, _id) 复合游标分页。
      // 不用纯 updatedAt 游标：同一毫秒写入的两条笔记会被漏掉或重复。
      case "getUserNotes": {
        if (!uid) return fail("unauthorized");
        const pageSize = Math.min(Number(event.pageSize) || 200, 500);
        const before = Number(event.updatedBefore) || 0;
        const beforeId = String(event.beforeId || "");
        const query = { ownerUserId: uid };
        // 回收站用 deletedAt > 0 表达，笔记本身没有被移动到别的集合，
        // 所以「拉回收站」只是把过滤条件放开。
        if (event.includeTrash !== true) query.deletedAt = _.eq(0);
        let base = userNotes.where(query);
        if (before > 0) {
          base = base.where(
            _.or([
              _.and([{ updatedAt: _.lt(before) }]),
              _.and([{ updatedAt: before }, { _id: _.lt(beforeId) }]),
            ])
          );
        }
        const res = await base
          .orderBy("updatedAt", "desc")
          .orderBy("_id", "desc")
          .limit(pageSize)
          .get();
        const rows = res.data || [];
        const last = rows.length > 0 ? rows[rows.length - 1] : null;
        // 拿不满一页说明已经到末尾，nextCursor 置空让客户端停止翻页。
        const hasMore = rows.length === pageSize;
        return ok({
          notes: rows,
          nextCursor:
            hasMore && last
              ? { updatedBefore: last.updatedAt, beforeId: last._id }
              : null,
        });
      }

      // 批量写入个人笔记。迁移几千条笔记必须走批量，逐条 upsert 会把云函数拖到
      // 超时。createdAt 只在首次写入时确定：已存在的文档沿用旧值，防止客户端
      // 重装后重传导致时间线顺序整体后移。
      case "upsertUserNotes": {
        if (!uid) return fail("unauthorized");
        const incoming = Array.isArray(event.notes) ? event.notes : [];
        if (incoming.length === 0) return ok({ written: 0 });
        if (incoming.length > 500) return fail("too_many");
        try {
          await ensureUserNotes();
          const nowMs = now();
          const clean = [];
          for (const raw of incoming) {
            if (!raw || typeof raw !== "object") continue;
            const noteId = String(raw.noteId || "").trim();
            if (!noteId || noteId.length > 128) continue;
            clean.push({
              noteId,
              title: String(raw.title == null ? "" : raw.title).slice(0, 200),
              content: String(raw.content == null ? "" : raw.content).slice(
                0,
                50000
              ),
              createdAt: Number(raw.createdAt) || 0,
              updatedAt: Number(raw.updatedAt) || nowMs,
              sutraKeys: Array.isArray(raw.sutraKeys)
                ? raw.sutraKeys
                    .map((k) => String(k))
                    .filter((k) => k && k.length <= 200)
                    .slice(0, 32)
                : [],
              shared: raw.shared === true,
              cloudId: raw.cloudId ? String(raw.cloudId).slice(0, 128) : "",
              deletedAt: Number(raw.deletedAt) || 0,
            });
          }
          if (clean.length === 0) return ok({ written: 0 });

          // 墓碑（回收站里彻底删除）：content 为空且 deletedAt > 0。
          // 这类条目不进 userNotes——回收站里清空后它已不存在，留在集合里
          // 只会让笔记计数越攒越多。真要删就删文档。
          const tombstones = clean.filter(
            (n) => n.deletedAt > 0 && n.content === ""
          );
          if (tombstones.length > 0) {
            const tIds = tombstones.map((n) => stableDocId(uid, "note", n.noteId));
            for (let i = 0; i < tIds.length; i += 20) {
              const slice = tIds.slice(i, i + 20);
              await Promise.all(
                slice.map((id) => userNotes.doc(id).remove())
              );
            }
          }
          const alive = clean.filter((n) => !(n.deletedAt > 0 && n.content === ""));
          if (alive.length === 0) {
            return ok({ written: 0, removed: tombstones.length });
          }

          // 一次查询取回这批 id 已有的文档，只为保住 createdAt，避免逐条读。
          const ids = alive.map((n) => stableDocId(uid, "note", n.noteId));
          const existingRes = await userNotes
            .where({ _id: _.in(ids) })
            .limit(500)
            .get();
          const prev = {};
          for (const row of existingRes.data || []) prev[row._id] = row;

          const entries = alive.map((n) => {
            const id = stableDocId(uid, "note", n.noteId);
            const old = prev[id];
            const createdAt =
              n.createdAt > 0
                ? n.createdAt
                : old && old.createdAt
                ? old.createdAt
                : n.updatedAt;
            return {
              id,
              data: {
                ownerUserId: uid,
                noteId: n.noteId,
                title: n.title,
                content: n.content,
                createdAt,
                updatedAt: n.updatedAt,
                sutraKeys: n.sutraKeys,
                shared: n.shared,
                cloudId: n.cloudId,
                deletedAt: n.deletedAt,
                serverAt: nowMs,
              },
            };
          });
          const written = await writeDocsInBatches(userNotes, entries, 20);
          return ok({ written });
        } catch (e) {
          console.error(
            "[api] upsertUserNotes error:",
            e && e.message ? e.message : e
          );
          return fail(e && e.message ? e.message : "笔记保存失败");
        }
      }

      // ==================== 用户时间线（一条记录一个文档） ====================

      // 按 (createdAt, _id) 复合游标倒序翻页。
      // 复合游标是必需的：同一段落里画线与感想可能落在同一毫秒，
      // 只按 createdAt 过滤会漏掉或重复这些条目，也就丢了段内先后顺序。
      case "getUserRecords": {
        if (!uid) return fail("unauthorized");
        const pageSize = Math.min(Number(event.pageSize) || 50, 200);
        const before = Number(event.createdBefore) || 0;
        const beforeId = String(event.beforeId || "");
        let base = userRecords.where({ ownerUserId: uid });
        if (before > 0) {
          base = base.where(
            _.or([
              _.and([{ createdAt: _.lt(before) }]),
              _.and([{ createdAt: before }, { _id: _.lt(beforeId) }]),
            ])
          );
        }
        const res = await base
          .orderBy("createdAt", "desc")
          .orderBy("_id", "desc")
          .limit(pageSize)
          .get();
        const rows = res.data || [];
        const last = rows.length > 0 ? rows[rows.length - 1] : null;
        const hasMore = rows.length === pageSize;
        return ok({
          records: rows,
          nextCursor:
            hasMore && last
              ? { createdBefore: last.createdAt, beforeId: last._id }
              : null,
        });
      }

      // 按「段落完整集合」同步时间线。
      //
      // 客户端只上报本段落当前存在的 recId 全集，由服务端删掉不在集合里的文档。
      // 不让客户端显式报「删了哪些 id」：那样漏报一次，云端就会留下永久幽灵条目。
      // 用全集比对天然幂等、可自愈，重复推送同一份数据结果一致。
      case "upsertUserRecords": {
        if (!uid) return fail("unauthorized");
        const records = Array.isArray(event.records) ? event.records : [];
        const groups = Array.isArray(event.groups) ? event.groups : [];
        if (records.length > 500) return fail("too_many");
        if (groups.length > 200) return fail("too_many");
        try {
          await ensureUserRecords();
          const nowMs = now();

          const entries = [];
          for (const raw of records) {
            if (!raw || typeof raw !== "object") continue;
            const recId = String(raw.recId || "");
            if (!recId || recId.length > 400) continue;
            const t = Number(raw.type);
            if (!Number.isInteger(t) || t < 0 || t > 2) continue;
            const keys = Array.isArray(raw.sutraKeys)
                ? raw.sutraKeys
                    .map((k) => String(k))
                    .filter((k) => k && k.length <= 200)
                    .slice(0, 32)
                : [];
            // 主经名单独存一份字符串字段：下面按段落做差集删除时要拿它做
            // 等值查询，而 sutraKeys 是数组，按数组字段等值匹配不到东西。
            const primarySutraKey = keys.length > 0 ? keys[0] : "";
            entries.push({
              id: stableDocId(uid, "rec", recId),
              data: {
                ownerUserId: uid,
                recId,
                type: t,
                sutraKey: primarySutraKey,
                sutraKeys: keys,
                para: Number(raw.para) || -1,
                text: String(raw.text == null ? "" : raw.text).slice(0, 20000),
                paraText: String(raw.paraText == null ? "" : raw.paraText).slice(
                  0,
                  20000
                ),
                // createdAt 是「动作发生时刻」，首次写入后由下次同步沿用：
                // 它是时间线唯一的排序依据，被覆盖就等于丢失历史顺序。
                createdAt: Number(raw.createdAt) || nowMs,
                updatedAt: Number(raw.updatedAt) || nowMs,
                shared: raw.shared === true,
                serverAt: nowMs,
              },
            });
          }
          const written = await writeDocsInBatches(userRecords, entries, 20);

          // 逐段做差集删除。只清 type 0/1（画线/感想）：笔记记录 para 为 -1、
          // id 以 n| 开头，不属于任何段落，段落同步绝不能碰它们。
          let removed = 0;
          for (const g of groups) {
            if (!g || typeof g !== "object") continue;
            const sutraKey = String(g.sutraKey || "");
            const para = Number(g.para);
            if (!sutraKey || !Number.isInteger(para) || para < 0) continue;
            const keep = new Set(
              (Array.isArray(g.ids) ? g.ids : []).map((x) => String(x))
            );
            const cur = await userRecords
              .where({ ownerUserId: uid, sutraKey, para, type: _.in([0, 1]) })
              .limit(500)
              .get();
            const doomed = (cur.data || []).filter((r) => !keep.has(r.recId));
            if (doomed.length === 0) continue;
            for (let i = 0; i < doomed.length; i += 20) {
              const slice = doomed.slice(i, i + 20);
              await Promise.all(
                slice.map((r) => userRecords.doc(r._id).remove())
              );
              removed += slice.length;
            }
          }
          return ok({ written, removed });
        } catch (e) {
          console.error(
            "[api] upsertUserRecords error:",
            e && e.message ? e.message : e
          );
          return fail(e && e.message ? e.message : "记录保存失败");
        }
      }

      case "setUserData": {
        if (!uid) return fail("unauthorized");
        const payload = event.payload && typeof event.payload === "object" ? event.payload : null;
        if (!payload) return fail("empty_payload");
        const { data } = await userData.where({ uid }).limit(1).get();
        const row = data && data[0];
        // 合并而非整包覆盖：客户端是增量全量推送，某次推送缺少某类文件
        //（如横幅压缩后仍超限被跳过）时，不能把云端已有的头像/横幅/经书列表清掉。
        const prev = row && row.payload && typeof row.payload === "object" ? row.payload : {};
        const merged = {
          prefs: { ...(prev.prefs || {}), ...(payload.prefs || {}) },
          files: { ...(prev.files || {}), ...(payload.files || {}) },
        };
        for (const k of Object.keys(payload)) {
          if (!(k in merged)) merged[k] = payload[k];
        }
        // 单个 key 超限时只跳过它，不让整次同步失败。
        // 原来只要整包超限就整个 fail，于是一个大 key 就能把打卡记录、阅读
        // 进度等所有数据一起拖停；而客户端又把这个失败静默吞掉，用户毫无
        // 察觉，等卸载重装才发现数据停在很久以前。
        const skippedKeys = [];
        for (const group of ["prefs", "files"]) {
          const bucket = merged[group];
          for (const k of Object.keys(bucket)) {
            if (JSON.stringify(bucket[k]).length > _maxPrefKeyChars) {
              skippedKeys.push(group + "." + k);
              delete bucket[k];
            }
          }
        }
        const json = JSON.stringify(merged);
        if (json.length > _maxUserDataChars) return fail("payload_too_large");
        const nowMs = now();
        const record = {
          uid,
          payload: merged,
          updatedAt: nowMs,
        };
        if (row) {
          await userData.doc(row._id).update(record);
        } else {
          // ★ 首次同步时写入 createdAt = 注册后首次联网时间戳。
          //   用于 getUserProfiles 做 joinTime 的 fallback，比被污染的 prefs 可靠。
          record.createdAt = nowMs;
          await userData.add(record);
        }
        popularSutrasCache = null;
        return ok({ updatedAt: record.updatedAt, skippedKeys });
      }

      // ==================== 账号名称 + 密码登录 ====================

      // 设置/修改账号名称与密码（需已登录）。账号名称全局唯一。
      case "setAccount": {
        if (!uid) return fail("unauthorized");
        await ensureUserAccounts();
        const username = normalizeUsername(event.username);
        if (!username) return fail("invalid_username");
        // 密码可空：为空表示仅修改账号名称、保留原密码（编辑资料页场景）。
        const password = String(event.password || "");
        if (password && (password.length < 6 || password.length > 64)) {
          return fail("invalid_password");
        }
        const usernameKey = username.toLowerCase();
        // 新名称是否被其他用户占用。
        const { data } = await userAccounts
          .where({ usernameKey })
          .limit(1)
          .get();
        const taken = data && data[0];
        if (taken && taken.uid !== uid) return fail("username_taken");

        // 按 uid 找到当前用户自己的记录（而不是按名称），改名为更新而非新建，
        // 避免同一 uid 产生多条记录导致展示旧名称。
        const mine = await userAccounts.where({ uid }).get();
        const myDocs = mine.data || [];
        // 清理历史可能产生的重复记录（同一 uid 只保留一条）。
        for (const d of myDocs.slice(1)) {
          await userAccounts.doc(d._id).remove();
        }
        const myDoc = myDocs[0];
        const updateData = {
          username,
          usernameKey,
          updatedAt: now(),
        };
        if (password) {
          const salt = crypto.randomBytes(16).toString("hex");
          updateData.salt = salt;
          updateData.passwordHash = hashPassword(password, salt);
          updateData.hasPassword = true;
        }
        if (myDoc) {
          await userAccounts.doc(myDoc._id).update(updateData);
        } else {
          updateData.uid = uid;
          updateData.createdAt = now();
          if (!updateData.hasPassword) updateData.hasPassword = false;
          await userAccounts.add(updateData);
        }
        return ok({ username });
      }

      // 手机号登录后自动生成默认账号（随机数字+尾号，并随机生成密码）：
      // 已有账号则原样返回，不覆盖；没有则创建一条已设随机密码的记录。
      case "ensureDefaultAccount": {
        if (!uid) return fail("unauthorized");
        await ensureUserAccounts();
        const username = normalizeUsername(event.username);
        if (!username) return fail("invalid_username");
        const password = String(event.password || "");
        const mine = await userAccounts.where({ uid }).get();
        const myDocs = mine.data || [];
        if (myDocs.length > 0) {
          for (const d of myDocs.slice(1)) {
            await userAccounts.doc(d._id).remove();
          }
          return ok({ username: myDocs[0].username || "" });
        }
        const usernameKey = username.toLowerCase();
        const { data } = await userAccounts
          .where({ usernameKey })
          .limit(1)
          .get();
        const taken = data && data[0];
        if (taken && taken.uid !== uid) return fail("username_taken");
        let salt = "";
        let passwordHash = "";
        let hasPassword = false;
        if (password.length >= 6 && password.length <= 64) {
          salt = crypto.randomBytes(16).toString("hex");
          passwordHash = hashPassword(password, salt);
          hasPassword = true;
        }
        await userAccounts.add({
          username,
          usernameKey,
          salt,
          passwordHash,
          hasPassword,
          uid,
          createdAt: now(),
          updatedAt: now(),
        });
        return ok({ username });
      }

      // 账号 + 密码登录（兼注册）：
      //  - 账号存在但从未设置密码（手机号登录生成的默认账号）→ 本次视为注册，设置密码并登录。
      //  - 已设置过密码 → 校验密码后登录。
      case "loginWithAccount": {
        await ensureUserAccounts();
        const username = String(event.username || "").trim().toLowerCase();
        if (!username) return fail("bad_request");
        const password = String(event.password || "");
        const { data } = await userAccounts
          .where({ usernameKey: username })
          .limit(1)
          .get();
        const acc = data && data[0];
        if (!acc) return fail("account_not_found");
        let registered = false;
        // 以是否存有密码哈希为准（兼容早期记录没有 hasPassword 字段的情况）。
        if (!acc.passwordHash) {
          if (password.length < 6 || password.length > 64) {
            return fail("invalid_password");
          }
          const salt = crypto.randomBytes(16).toString("hex");
          const passwordHash = hashPassword(password, salt);
          await userAccounts.doc(acc._id).update({
            salt,
            passwordHash,
            hasPassword: true,
            updatedAt: now(),
          });
          registered = true;
        } else if (hashPassword(password, acc.salt) !== acc.passwordHash) {
          return fail("wrong_password");
        }
        let ticket = "";
        try {
          // 需要云开发环境开启「自定义登录」。
          ticket = await app.auth().createTicket(acc.uid, { refresh: 604800 });
        } catch (e) {
          console.log("[api] createTicket error:", e.message);
          return fail("ticket_error");
        }
        return ok({ uid: acc.uid, ticket, registered });
      }

      // 查询当前登录用户的账号名称（未设置返回空串）。
      case "getMyAccount": {
        if (!uid) return ok({ username: "" });
        await ensureUserAccounts();
        const { data } = await userAccounts.where({ uid }).limit(1).get();
        const acc = data && data[0];
        return ok({ username: acc ? acc.username : "" });
      }

      // ==================== 反馈 ====================

      // 用户反馈（未登录也可提交，匿名记录 uid 为空串）。
      // 收集方式：云开发控制台 → 数据库 → feedbacks 集合查看/导出。
      case "submitFeedback": {
        await ensureFeedbacks();
        const content = String(event.content || "").trim().slice(0, 1000);
        if (!content) return fail("empty_content");
        await feedbacks.add({
          userId: uid || "",
          content,
          contact: String(event.contact || "").slice(0, 100),
          status: "new",
          createdAt: now(),
        });
        return ok({});
      }

      // 当前登录用户是否为管理员（admins 集合中登记了 uid）。
      case "isAdmin": {
        await ensureAdmins();
        return ok({ isAdmin: await isAdminUser(uid) });
      }

      // 管理员拉取反馈列表（分页，新反馈优先）。status 可选：new | handled，缺省返回全部。
      case "getFeedbacks": {
        await ensureFeedbacks();
        if (!(await isAdminUser(uid))) return fail("forbidden");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 20, 50);
        const status = String(event.status || "").trim();
        const validStatus = status === "new" || status === "handled";
        const base = validStatus
          ? feedbacks.where({ status }).orderBy("createdAt", "desc")
          : feedbacks.orderBy("createdAt", "desc");
        const res = await base
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        const total = validStatus
          ? (await feedbacks.where({ status }).count()).total
          : (await feedbacks.count()).total;
        const { total: unread } = await feedbacks
          .where({ status: "new" })
          .count();
        await attachFeedbackUsernames(res.data);
        return ok({
          feedbacks: res.data,
          total,
          unread,
          hasMore: (page - 1) * pageSize + res.data.length < total,
        });
      }

      // 管理员标记反馈为已处理 / 待处理。
      case "markFeedbackHandled": {
        if (!(await isAdminUser(uid))) return fail("forbidden");
        const id = String(event.id || "");
        const status = event.handled === true ? "handled" : "new";
        const patch = { status };
        if (status === "handled") patch.handledAt = now();
        await feedbacks.doc(id).update(patch);
        return ok({});
      }

      // ==================== 公告 ====================
      // 公告以「广场笔记」形式存储（kind: announcement），可像普通帖子一样评论/转发/点赞。

      // 拉取公告列表（所有用户可读，主页公告栏展示，最新在前）。
      case "getAnnouncements": {
        const res = await notes
          .where({ kind: "announcement", visibility: "public", status: "normal" })
          .orderBy("createdAt", "desc")
          .limit(100)
          .get();
        return ok({ announcements: res.data });
      }

      // 管理员发布公告（同时生成一条广场笔记，供详情页评论/转发/点赞）。
      case "addAnnouncement": {
        if (!(await isAdminUser(uid))) return fail("forbidden");
        const title = String(event.title || "").trim().slice(0, 60);
        const content = String(event.content || "").trim().slice(0, 2000);
        if (!title) return fail("empty_title");
        if (!content) return fail("empty_content");
        const authorName = (await getAccountName(uid)) || "管理员";
        const res = await notes.add({
          kind: "announcement",
          ownerUserId: uid,
          title,
          content,
          authorName,
          visibility: "public",
          status: "normal",
          likeCount: 0,
          commentCount: 0,
          viewCount: 0,
          repostCount: 0,
          createdAt: now(),
          updatedAt: now(),
        });
        return ok({ id: res.id });
      }

      // 管理员删除公告（连带清理其点赞/评论/收藏/举报）。
      case "deleteAnnouncement": {
        if (!(await isAdminUser(uid))) return fail("forbidden");
        const id = String(event.id || "").trim();
        if (!id) return fail("bad_request");
        const note = await getNote(notes, id);
        if (!note || note.kind !== "announcement") return fail("not_found");
        await notes.doc(id).remove();
        await likes.where({ noteId: id }).remove();
        await comments.where({ noteId: id }).remove();
        await reports.where({ noteId: id }).remove();
        await favorites.where({ noteId: id }).remove();
        return ok({});
      }

      // ==================== 管理员管理 ====================

      // 管理员列表（含账号名称，供手机端直接管理）。
      case "getAdmins": {
        if (!(await isAdminUser(uid))) return fail("forbidden");
        await ensureAdmins();
        const res = await admins.limit(1000).get();
        const list = res.data || [];
        const accounts = {};
        const ids = [...new Set(list.map((a) => a.uid).filter(Boolean))];
        for (let i = 0; i < ids.length; i += 100) {
          try {
            const { data } = await userAccounts
              .where({ uid: _.in(ids.slice(i, i + 100)) })
              .get();
            for (const a of data || []) accounts[a.uid] = a.username || "";
          } catch (e) {}
        }
        return ok({
          admins: list.map((a) => ({
            uid: a.uid || "",
            username: accounts[a.uid] || "",
            createdAt: a.createdAt || 0,
          })),
        });
      }

      // 添加管理员：输入是账号名称（2-20 位中英文/数字/下划线）→ 查 userAccounts 取 uid；
      // 否则视为用户 uid 直接添加。仅管理员可操作。
      case "addAdmin": {
        if (!(await isAdminUser(uid))) return fail("forbidden");
        await ensureAdmins();
        const input = String(event.username || event.uid || "").trim();
        if (!input) return fail("bad_request");
        let targetUid = "";
        if (/^[\u4e00-\u9fa5a-zA-Z0-9_]{2,20}$/.test(input)) {
          const { data } = await userAccounts
            .where({ usernameKey: input.toLowerCase() })
            .limit(1)
            .get();
          const acc = data && data[0];
          if (!acc || !acc.uid) return fail("user_not_found");
          targetUid = acc.uid;
        } else {
          targetUid = input;
        }
        if (!targetUid) return fail("bad_request");
        const existing = await admins.where({ uid: targetUid }).limit(1).get();
        if (existing.data.length > 0) return fail("already_admin");
        await admins.add({ uid: targetUid, createdBy: uid, createdAt: now() });
        return ok({});
      }

      // 移除管理员：至少保留一位（防止把所有管理员都移除导致无人能管理）。
      case "removeAdmin": {
        if (!(await isAdminUser(uid))) return fail("forbidden");
        await ensureAdmins();
        const targetUid = String(event.uid || "").trim();
        if (!targetUid) return fail("bad_request");
        const existing = await admins.where({ uid: targetUid }).limit(1).get();
        const doc = existing.data && existing.data[0];
        if (!doc) return fail("not_admin");
        const { total } = await admins.count();
        if (total <= 1) return fail("last_admin");
        await admins.doc(doc._id).remove();
        return ok({});
      }

      // ==================== 实名认证 ====================

      // 提交实名认证：服务端再次校验姓名与身份证号格式（地区码/出生日期/校验位），
      // 只保存姓名的脱敏形式与身份证号哈希，不保存明文；同一账号只认证一次（幂等）。
      case "verifyIdentity": {
        if (!uid) return fail("unauthorized");
        await ensureVerifications();
        const realName = String(event.realName || "").trim();
        const idCard = String(event.idCard || "").trim().toUpperCase();
        const nameErr = validateRealName(realName);
        if (nameErr) return fail(nameErr);
        const idErr = validateIdCard(idCard);
        if (idErr) return fail(idErr);
        const existing = await verifications.where({ uid }).limit(1).get();
        if (existing.data.length > 0) {
          const v = existing.data[0];
          return ok({ verified: true, realNameMasked: v.realNameMasked || "" });
        }
        const masked = maskRealName(realName);
        const idHash = crypto.createHash("sha256").update(idCard).digest("hex");
        await verifications.add({
          uid,
          realNameMasked: masked,
          idHash,
          verifiedAt: now(),
        });
        return ok({ verified: true, realNameMasked: masked });
      }

      // 查询当前登录用户的实名认证状态。
      case "getMyVerification": {
        if (!uid) return ok({ verified: false });
        await ensureVerifications();
        const { data } = await verifications.where({ uid }).limit(1).get();
        const v = data && data[0];
        return ok({
          verified: !!v,
          realNameMasked: v ? v.realNameMasked || "" : "",
          verifiedAt: v ? v.verifiedAt || 0 : 0,
        });
      }

      // ==================== 阅藏进度上报（广场帖子百分比） ====================

      // 上报「阅藏进度」原始数据：标记完成阅读的经书册数 + 全藏总册数。
      // 存到 userAccounts.canonRead/canonTotal；广场帖子头部据此展示百分比
      // （百分比由客户端按经藏页同源算法计算，服务端不再取整，保证精度）。
      case "reportCanonProgress": {
        if (!uid) return fail("unauthorized");
        const read = Math.min(Math.max(Math.floor(Number(event.read)) || 0, 0), 100000);
        const total = Math.min(Math.max(Math.floor(Number(event.total)) || 0, 0), 100000);
        if (total <= 0) return ok({ canonRead: 0, canonTotal: 0 });
        await ensureUserAccounts();
        const { data } = await userAccounts.where({ uid }).limit(1).get();
        const row = data && data[0];
        if (!row) return ok({ canonRead: 0, canonTotal: 0 });
        await userAccounts.doc(row._id).update({
          canonRead: read,
          canonTotal: total,
          canonUpdatedAt: now(),
        });
        return ok({ canonRead: read, canonTotal: total });
      }

      // ==================== 读经时长上报（他人主页徽章） ====================

      // 上报读经时长增量（秒）：累加到 userAccounts.readingSeconds，
      // 他人主页据此展示该用户点亮的修学徽章。
      // 单次增量上限 24 小时（一天），防止异常/恶意数据刷爆；幂等由客户端游标保证。
      case "reportReadingTime": {
        if (!uid) return fail("unauthorized");
        const raw = Number(event.delta);
        if (!isFinite(raw) || raw <= 0) return ok({ accepted: 0 });
        const delta = Math.min(Math.floor(raw), 24 * 60 * 60);
        await ensureUserAccounts();
        const { data } = await userAccounts.where({ uid }).limit(1).get();
        const row = data && data[0];
        if (!row) return ok({ accepted: 0 });
        const total = Math.max(0, Number(row.readingSeconds) || 0) + delta;
        await userAccounts.doc(row._id).update({
          readingSeconds: total,
          readingUpdatedAt: now(),
        });
        return ok({ accepted: delta, readingSeconds: total });
      }

      // ==================== 管理 ====================

      case "hideNote": {
        const id = String(event.id || "");
        const { data: hd } = await notes.doc(id).get();
        const hideTarget = hd && hd[0];
        if (hideTarget && hideTarget.status !== "hidden") {
          // 隐藏前先把子回复重挂到父帖（同 deleteNote），保持回复链连通。
          await reattachChildReplies(notes, id, String(hideTarget.repostOf || ""));
        }
        await notes.doc(id).update({ status: "hidden" });
        return ok({});
      }

      // ==================== AI 经文翻译/讨论 ====================
      // 以「段」为单位：把整段古文翻译成白话，并在面板里可围绕该段继续追问。
      // 输入：{ paragraph, action: "translate"|"discuss", history?: [...] }
      // history 用于追问时带上原文、已生成的译文与过往对话。
      case "aiTranslate": {
        const paragraph = String(event.paragraph || "").trim();
        const mode = String(event.mode || "translate");
        const history = Array.isArray(event.history) ? event.history : [];
        if (!paragraph) return fail("缺少需要翻译的经文段落");
        if (paragraph.length > 4000) return fail("段落过长，请分段后重试");
        // 同一段经文只生成一次译文，之后所有用户直接复用（省 API 费用）。
        const paraHash = paragraphTranslationHash(paragraph);

        // 白话翻译提示词：重点是「重组语序的意译」而不是逐词对译，
        // 否则译文会残留文言句式、读起来仍然费解。
        const sysPrompt =
          "你是一位资深的佛经白话译者，长期为现代读者做汉传佛教经典的今译，译文要像现代人写的流畅散文。\n" +
          "任务：把用户提供的佛经古文整段译成现代汉语白话文。\n\n" +
          "硬性要求：\n" +
          "1) 忠于原意：不增删义理、不改动因果、次第与并列关系；但必须重组语序、拆分长句、补出古文省略的主语和连接词，让它读起来是通顺的现代句子，而不是逐词对应的文言直译。\n" +
          "2) 消除直译腔：不要保留「所谓……者，……也」「其义为」「即是」这类生硬套式；「夫、盖、乃、者、也、欤、乎」等虚字不要硬译出来；古文里的判断句、被动句要改写成现代汉语说法。\n" +
          "3) 佛学名相（五蕴、八正道、真如、菩提、涅槃等）保留原词；同一段中某个名相第一次出现时，用括号极简补充一次（不超过12个字），例如「三界（欲界、色界、无色界）」「二谛（世俗谛、胜义谛）」，第二次出现起不再括注。普通词语一律不要括注。\n" +
          "4) 数量、次第、分条必须显式译出（如「有三点：第一……第二……第三……」），不要合并、省略或改写成模糊表达。\n" +
          "5) 语气连贯自然，可以用「就、那么、也就是说、其实、只要」等现代口语连接词过渡；但不得添加原文没有的解释、评论、例子或引申。\n" +
          "6) 只输出译文正文：禁止输出「注：」「说明：」「译者按」「原文」等任何标注、标题、前缀，也不要输出与翻译无关的内容。\n\n" +
          "风格示例（只示范语气与处理方式，不要照抄内容）：\n" +
          "原文：一切众生之类，若卵生、若胎生、若湿生、若化生，若有色、若无色，若有想、若无想，若非有想非无想，我皆令入无余涅槃而灭度之。\n" +
          "译文：一切众生，不论是从卵里出生的、母胎里出生的、湿气中出生的，还是变化而生的；不论是有形体的还是没有形体的，有念头的、没有念头的，乃至既非有念也非无念的，我都要帮助他们进入无余涅槃，彻底得到解脱。\n" +
          "现在请翻译用户提供的段落。";

        // 输出长度按段落长度给足：古文段落最长 4000 字，
        // 固定 800 token 会在长段落中途截断，导致译文残缺难懂。
        const maxTokens = Math.min(6000, Math.max(800, Math.ceil(paragraph.length * 1.8) + 300));

        // 讨论模式：本质是普通聊天。译文只是开场背景，但回答要像正常对话一样，
        // 直接回答用户的问题，不要把话题强拉回经文，也不要重复附带译文。
        const discussSysPrompt =
          "你是一位知识渊博、亲切耐心的佛学研究者兼通用对话助手，正在与一位读者聊天。\n" +
          "读者刚刚阅读了一段佛经，并看到它的白话翻译。仅供你作背景参考：\n" +
          "经文原文：\n" + paragraph + "\n" +
          "（背景）读者已看过该段的现代白话译文。\n\n" +
          "对话原则：\n" +
          "1) 读者接下来提出的问题，请像正常聊天一样直接、自然地回答，不要刻意重申或附上整段译文；\n" +
          "2) 如果读者的问题与这段经文有关（含义、名相、背景、修行启示等），结合经文并适当扩展到佛教整体义理回答；\n" +
          "3) 如果读者的问题与这段经文无关，就直接回答他的问题本身，当作普通对话；\n" +
          "4) 回答要准确、通俗、流畅，语气自然。";

        try {
          if (mode === "discuss") {
            const messages = [{ role: "system", content: discussSysPrompt }];
            for (const h of history) {
              if (!h || typeof h.role !== "string" || typeof h.content !== "string") continue;
              const role = h.role === "user" ? "user" : "assistant";
              if (h.content && h.content.length <= 8000) {
                messages.push({ role, content: h.content });
              }
            }
            // 兜底：保证最后一条是 user 消息（即待回答的问题）。
            // 若历史为空或最后一条不是用户提问，模型会停在「你说，我听着」，
            // 这里补上显式提问，确保它直接回答用户当前的问题。
            const last = messages[messages.length - 1];
            const isUserLast = last && last.role === "user";
            if (!isUserLast) {
              messages.push({
                role: "user",
                content: "请现在直接回答我刚才提出的问题，不要敷衍，不要问我要问什么。",
              });
            }
            const text = await callDeepSeek({ model: "deepseek-chat", messages, maxTokens: 800, timeoutMs: 60000 });
            return ok({ text, actor: text.length > 0 ? "ai" : "user", type: "discuss", done: true });
          }

          // 默认：白话翻译（带跨用户共享缓存）
          // 1) 先查缓存：命中直接返回，不重复调用 API。
          // 含替换字符（历史版本逐块解码把汉字切断产生的问号）的缓存视为脏数据，
          // 跳过并重新生成，之后覆盖回缓存，实现自愈。
          let cachedDoc = null;
          try {
            const { data } = await aiTranslations.where({ h: paraHash }).limit(1).get();
            if (data && data.length > 0) cachedDoc = data[0];
            if (cachedDoc && cachedDoc.text && !cachedDoc.text.includes("\uFFFD")) {
              return ok({ text: cachedDoc.text, type: "translate", done: true, cached: true });
            }
          } catch (e) {
            // 缓存查询失败不阻塞：当作未命中继续调用 API。
            console.log("[api] aiTranslate 缓存查询失败，直接生成:", e.message);
          }

          const text = await callDeepSeek({
            model: "deepseek-chat",
            messages: [
              { role: "system", content: sysPrompt },
              { role: "user", content: "请把下面这段佛经古文翻译成现代白话文：\n\n" + paragraph },
            ],
            maxTokens,
            // 长段落输出可达数千 token，60s 不够用；控制台函数超时需 ≥150s。
            timeoutMs: 120000,
            // 略高于默认 0.3：让句式更自然流畅，同时仍足以保证忠实。
            temperature: 0.4,
          });

          const cleaned = cleanAiTranslation(text);

          // 2) 生成成功后写入缓存，供后续所有用户复用。
          // 命中的是脏缓存则原地覆盖（用 update），否则新增。
          try {
            await ensureAiTranslations();
            if (cachedDoc && cachedDoc.id) {
              await aiTranslations.doc(cachedDoc.id).update({ text: cleaned, createdAt: now() });
            } else {
              await aiTranslations.add({ h: paraHash, paragraph, text: cleaned, createdAt: now() });
            }
          } catch (e) {
            console.log("[api] aiTranslate 缓存写入失败（不影响本次返回）:", e.message);
          }

          return ok({ text: cleaned, type: "translate", done: true, cached: false });
        } catch (e) {
          console.error("[api] aiTranslate error:", e && e.message ? e.message : e);
          return fail(e && e.message ? e.message : "AI翻译失败，请稍后重试");
        }
      }

      // 读取某段经文已缓存的白话翻译（其他同修/自己之前翻译过的结果），
      // 只查 aiTranslations 共享缓存，不调用 DeepSeek API。
      // 输入：{ paragraph } 输出：{ text?: string, found: boolean }
      case "getParagraphTranslation": {
        const paragraph = String(event.paragraph || "").trim();
        if (!paragraph) return fail("缺少需要查询的经文段落");
        try {
          const paraHash = paragraphTranslationHash(paragraph);
          await ensureAiTranslations();
          const { data } = await aiTranslations.where({ h: paraHash }).limit(1).get();
          // 含替换字符的缓存视为未命中，让客户端走重新生成以自愈。
          if (data && data.length > 0 && data[0].text && !data[0].text.includes("\uFFFD")) {
            return ok({ text: cleanAiTranslation(data[0].text), found: true });
          }
          return ok({ text: "", found: false });
        } catch (e) {
          console.error("[api] getParagraphTranslation error:", e && e.message ? e.message : e);
          return ok({ text: "", found: false });
        }
      }

      // AI 网络自诊断：不发起真正的翻译请求，只检测云函数到 DeepSeek 的连通性，
      // 返回精确根因，便于定位「socket hang up / 网络异常」。客户端错误面板可调用。
      case "aiNetProbe": {
        const dns = require("dns");
        const net = require("net");
        const tls = require("tls");
        const host = "api.deepseek.com";
        const result = { host, keyConfigured: !!process.env.DEEPSEEK_API_KEY };

        // 1. DNS 解析
        try {
          await new Promise((resolve, reject) => {
            dns.lookup(host, { family: 0 }, (err, address, family) => {
              if (err) return reject(err);
              result.ip = address;
              result.ipFamily = family;
              resolve();
            });
          });
          result.dns = "ok";
        } catch (e) {
          result.dns = "fail";
          result.dnsError = e.code + " " + e.message;
        }

        // 2. TCP 连接 :443
        if (result.dns === "ok") {
          try {
            await new Promise((resolve, reject) => {
              const sock = net.connect(443, host);
              sock.setTimeout(8000, () => { sock.destroy(); reject(new Error("TCP_TIMEOUT")); });
              sock.on("connect", () => { sock.destroy(); resolve(); });
              sock.on("error", (e) => reject(e));
            });
            result.tcp = "ok";
          } catch (e) {
            result.tcp = "fail";
            result.tcpError = e.code || e.message;
          }
        }

        // 3. TLS 握手 :443
        if (result.tcp === "ok") {
          try {
            await new Promise((resolve, reject) => {
              const socket = tls.connect({
                host,
                port: 443,
                servername: host,
                rejectUnauthorized: true,
              });
              socket.setTimeout(8000, () => { socket.destroy(); reject(new Error("TLS_TIMEOUT")); });
              socket.on("secureConnect", () => { socket.destroy(); resolve(); });
              socket.on("error", (e) => reject(e));
            });
            result.tls = "ok";
          } catch (e) {
            result.tls = "fail";
            result.tlsError = e.code || e.message;
          }
        }

        // 4. 真实 HTTP POST /chat/completions（与翻译同款请求，最小文本）：
        //    验证「握手通但发送带 body 的 POST 是否被重置」——这正是 socket hang up 的场景。
        if (result.tls === "ok" && process.env.DEEPSEEK_API_KEY) {
          try {
            const text = await callDeepSeek({
              model: "deepseek-chat",
              messages: [
                { role: "system", content: "你是佛经翻译助手。" },
                { role: "user", content: "翻译：如是我闻。一时佛在舍卫国祇树给孤独园。" },
              ],
              maxTokens: 60,
              timeoutMs: 20000,
            });
            result.post = "ok";
            result.sample = String(text).slice(0, 40);
          } catch (e) {
            result.post = "fail";
            result.postError = e && e.message ? e.message : String(e);
          }
        }

        if (result.post === "ok") {
          result.network = "ok";
          result.conclusion = "云函数到 DeepSeek 完整通路正常（含真实翻译请求)，网络与密钥均正常。";
        } else if (result.tls === "ok") {
          result.conclusion = "TLS 握手可达，但发送真实翻译 POST 请求时失败（" + (result.postError || "") + "）——这是 socket hang up 的根因，多为云函数出网代理对大请求/长连接重置。";
        } else if (result.dns !== "ok") {
          result.conclusion = "云函数无法解析 api.deepseek.com（DNS 失败）——出网受限或 DNS 配置问题。";
        } else if (result.tcp !== "ok") {
          result.conclusion = "云函数无法建立到 api.deepseek.com:443 的 TCP 连接——出网/防火墙受限。";
        } else {
          result.conclusion = "TCP 可达但 TLS 握手失败——多为出网被中间设备重置。";
        }

        console.log("[api] aiNetProbe:", JSON.stringify(result));
        return ok(result);
      }

      // ==================== 读经段落笔记 / 完成态 ====================
      // 以 (ownerUserId, sutraKey, 段落index) 唯一。sutraKey 一般为经名（widget.title），
      // 同一用户同一本经的每段各有一条记录，跨设备云端同步。
      // 可选 userId：菩提空间分享帖以「作者当前最新画线/感想」为准时，按作者查询。
      // 为避免变成可枚举任意用户读经笔记的接口，非本人请求要求该作者确实公开分享过
      // 这本经的「画线/感想」页面帖（content 以 $经名 开头且带 \u00a7\u00a7HS\u00a7\u00a7 /
      // \u00a7\u00a7TS\u00a7\u00a7 哨兵）。
      case "getParagraphNotes": {
        const sutraKey = event.sutraKey;
        if (!sutraKey) return fail("缺少经名参数");
        const target = String(event.userId || "").trim() || uid;
        // 未登录且未指定查看对象（拿自己数据）时拒绝；未登录查看他人分享的帖子，
        // 走下方「确有公开页面分享帖」的隐私校验后放行。
        if (!target) return fail("unauthorized");
        try {
          await ensureReadingParagraphNotes();
          if (target !== uid) {
            // 作者本人以外：确认该作者确有这本经的「画线/感想」页面分享帖后才放行。
            // 帖子标题是展示名（基础经名 / 基础经名+「卷X」），而读经页保存段笔记的
            // key 可能是带 CBETA 编号的完整标题 / 加「卷X」的完整标题；核对时先归一到
            // 「基础经名」再匹配，避免同一部经因 key 形态不同被误判为 unauthorized，
            // 让分享帖实时同步能取到作者以其它 key 保存的当前画线/感想。
            const dollar = "$";
            const hs = "\u00a7\u00a7HS\u00a7\u00a7";
            const ts = "\u00a7\u00a7TS\u00a7\u00a7";
            const baseKey = String(sutraKey)
              .replace(/T\d+n[0-9A-Za-z]+_\d+$/, "")
              .replace(/卷[\u4e00-\u9fa5]+$/, "")
              .trim() || sutraKey;
            await ensureNotesCollection();
            const { data: pubs } = await notes
              .where({ ownerUserId: target, status: "normal" })
              .limit(50)
              .get();
            const pageShared = (pubs || []).some((n) => {
              const c = String(n.content || "");
              return (c.includes(hs) || c.includes(ts)) &&
                (c.includes(dollar + sutraKey) || c.includes(dollar + baseKey));
            });
            if (!pageShared) return fail("forbidden");
          }
          const { data } = await readingParagraphNotes
            .where({ ownerUserId: target, sutraKey })
            .limit(1000)
            .get();
          const list = (data || []).map((d) => ({
            index: parseInt(d.index, 10),
            note: d.note || "",
            underlines: Array.isArray(d.underlines) ? d.underlines : [],
            done: !!d.done,
            shared: !!d.shared,
            cloudId: d.cloudId || "",
            updatedAt: d.updatedAt || 0,
          }));
          return ok({ items: list });
        } catch (e) {
          console.error("[api] getParagraphNotes error:", e && e.message ? e.message : e);
          return fail(e && e.message ? e.message : "获取段落笔记失败");
        }
      }

      // 拉取某本经所有有感想（任意用户）的段落下标集合，用于阅读页操作栏「所有感想」变绿。
      // 返回 {indices: [int]} — 只含下标，不含笔记内容，轻量高效。
      case "getParagraphsWithThoughts": {
        const sutraKey = event.sutraKey;
        if (!sutraKey) return fail("缺少经名参数");
        try {
          await ensureReadingParagraphNotes();
          // 查所有用户对该经有非空 note 的记录，只取 index 字段。
          const { data } = await readingParagraphNotes
            .where({
              sutraKey,
              note: _.neq(""),
            })
            .field({ index: true })
            .limit(5000)
            .get();
          const indices = (data || [])
            .map((d) => parseInt(d.index, 10))
            .filter((n) => !isNaN(n));
          return ok({ indices: [...new Set(indices)] });
        } catch (e) {
          console.error("[api] getParagraphsWithThoughts error:", e && e.message ? e.message : e);
          return ok({ indices: [] });
        }
      }

      // 保存某段的备注文本（note 为 '' 表示清除该段备注）。
      // 按「段原文」聚合所有用户对该段的读经想法（菩提空间公开帖中
      // 符合 $经名\n\n段原文\n\n想法 格式、且段原文与给定段落匹配的帖子）。
      // 返回分页列表 + 总数，未登录也可浏览。
      case "searchParagraphThoughts": {
        const rawParagraph = (event.paragraph || "").toString();
        const paragraph = rawParagraph.trim();
        if (!paragraph) return fail("缺少段原文参数");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 20, 100);
        try {
          // 段原文是该段特有的完整句子，通常足够唯一；用整段做右侧包含匹配，
          // 命中后再用读经笔记格式解析，确保返回的都是真正的段落想法帖。
          const escaped = paragraph.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
          const paraRe = db.RegExp({
            regexp: `\\$[^\\n]+\\s*\\n\\s*\\n${escaped}`,
            options: "",
          });
          const base = notes.where({
            visibility: "public",
            status: "normal",
            kind: _.neq("announcement"),
            content: paraRe,
          });

          // 屏蔽的用户内容隐藏（与广场口径一致）。
          let blocked = [];
          if (uid) {
            try {
              const br = await blocks.where({ blockerId: uid }).limit(1000).get();
              blocked = br.data.map((r) => r.blockedId);
            } catch (e) {}
          }

          let list = [];
          let skip = 0;
          while (true) {
            const r = await base
              .orderBy("createdAt", "desc")
              .skip(skip)
              .limit(1000)
              .get();
            list.push(...(r.data || []));
            if ((r.data || []).length < 1000) break;
            skip += 1000;
          }
          const total = list.length;
          // 段想法按「喜欢的数量」从高到低排序（最多喜欢排最前）。
          list.sort(
            (a, b) => (b.likeCount || 0) - (a.likeCount || 0)
          );
          if (blocked.length) {
            list = list.filter(
              (n) =>
                n.ownerUserId === uid ||
                (!blocked.includes(n.ownerUserId) &&
                  !(
                    n.repostSourceUserId &&
                    blocked.includes(n.repostSourceUserId)
                  ))
            );
          }
          const pageNotes = list.slice(
            (page - 1) * pageSize,
            (page - 1) * pageSize + pageSize
          );
          const notesOut = pageNotes.map(({ _hotScore, ...rest }) => rest);
          await attachAuthorAccounts(notesOut);
          await attachAuthorVerified(notesOut);
          await attachAuthorCanonProgress(notesOut);
          return ok({
            notes: notesOut,
            total,
            hasMore: (page - 1) * pageSize + pageNotes.length < total,
          });
        } catch (e) {
          console.error(
            "[api] searchParagraphThoughts error:",
            e && e.message ? e.message : e
          );
          return fail(
            e && e.message ? e.message : "获取段落想法失败"
          );
        }
      }

      case "saveParagraphNote": {
        if (!uid) return fail("unauthorized");
        const sutraKey = event.sutraKey;
        const index = event.index;
        const note = (event.note || "").toString().trim();
        const shared = !!event.shared;
        const cloudId = (event.cloudId || "").toString();
        const rawUnderlines = Array.isArray(event.underlines) ? event.underlines : [];
        const underlines = rawUnderlines
          .filter((u) => u && typeof u === "object")
          .map((u) => ({
            start: Number.isInteger(u.start) ? u.start : 0,
            end: Number.isInteger(u.end) ? u.end : 0,
          }))
          .filter((u) => u.start >= 0 && u.end >= u.start);
        if (!sutraKey || index === undefined || index === null) {
          return fail("缺少参数");
        }
        try {
          await ensureReadingParagraphNotes();
          const existing = await findReadingParagraph(uid, sutraKey, String(index));
          if (existing) {
            await readingParagraphNotes.doc(existing._id).update({
              note,
              underlines,
              shared,
              cloudId,
              updatedAt: now(),
            });
          } else {
            await readingParagraphNotes.add({
              ownerUserId: uid,
              sutraKey,
              index: String(index),
              text: (event.text || "").toString().slice(0, 200),
              note,
              underlines,
              shared,
              cloudId,
              done: false,
              updatedAt: now(),
            });
          }
          return ok({ note });
        } catch (e) {
          console.error("[api] saveParagraphNote error:", e && e.message ? e.message : e);
          return fail(e && e.message ? e.message : "保存段落笔记失败");
        }
      }

      // 切换某段的「已读完/学完」完成态。
      case "toggleParagraphDone": {
        if (!uid) return fail("unauthorized");
        const sutraKey = event.sutraKey;
        const index = event.index;
        const done = !!event.done;
        if (!sutraKey || index === undefined || index === null) {
          return fail("缺少参数");
        }
        try {
          await ensureReadingParagraphNotes();
          const existing = await findReadingParagraph(uid, sutraKey, String(index));
          if (existing) {
            await readingParagraphNotes.doc(existing._id).update({
              done,
              updatedAt: now(),
            });
            // 若已完成且无备注，可保留该记录（用于记住完成态）。
          } else {
            await readingParagraphNotes.add({
              ownerUserId: uid,
              sutraKey,
              index: String(index),
              text: (event.text || "").toString().slice(0, 200),
              note: "",
              done,
              updatedAt: now(),
            });
          }
          return ok({ done });
        } catch (e) {
          console.error("[api] toggleParagraphDone error:", e && e.message ? e.message : e);
          return fail(e && e.message ? e.message : "更新段落状态失败");
        }
      }

      // 删除某段的全部数据（备注 + 完成态）。
      case "deleteParagraphNote": {
        if (!uid) return fail("unauthorized");
        const sutraKey = event.sutraKey;
        const index = event.index;
        if (!sutraKey || index === undefined || index === null) {
          return fail("缺少参数");
        }
        try {
          await ensureReadingParagraphNotes();
          const existing = await findReadingParagraph(uid, sutraKey, String(index));
          if (existing) {
            await readingParagraphNotes.doc(existing._id).remove();
          }
          return ok({ deleted: true });
        } catch (e) {
          console.error("[api] deleteParagraphNote error:", e && e.message ? e.message : e);
          return fail(e && e.message ? e.message : "删除段落笔记失败");
        }
      }

      default:
        return fail(`unknown action: ${action}`);
    }
  } catch (e) {
    console.error("[api] error:", e);
    return fail(e && e.message ? e.message : "internal_error");
  }
};

async function getOwnedNote(notesColl, id, uid) {
  const { data } = await notesColl.doc(id).get();
  const note = data && data[0];
  if (!note || note.ownerUserId !== uid) return null;
  return note;
}

async function getNote(notesColl, id) {
  const { data } = await notesColl.doc(id).get();
  return data && data[0];
}

// 把直接子回复（repostOf == id）重新挂到 [parentOf] 上，保持回复链连通。
// - parentOf 非空：删/隐中间回复 b 时，c/d 的 repostOf 从 b 改指到 b 的父帖 a，
//   广场/个人主页的分组逻辑能继续把 c/d 归到原贴 a 下方连线展示。
// - parentOf 为空（删/隐的就是根帖）：子回复没有可挂靠的上游，转为独立引用帖
//   （repostOf 置空 + repostKind 改为 quote，quoteOf 快照保留其原回复对象），避免悬空引用。
// 失败不抛出：重挂只是显示优化，不能阻塞删除/隐藏主流程。
async function reattachChildReplies(notesColl, id, parentOf, deletedTombstones) {
  try {
    // 参考 X 的 tombstone_ancestor_ids：祖先 id 不可变，被删祖先显式记录在
    // 子帖的 tombstoneAncestorIds 里（nearest-first，紧邻父帖在前），
    // 客户端详情页据此渲染「已删除帖子」占位并保持回复链连线不断。
    // 重挂本身仍保留：广场/个人主页列表依赖 repostOf 指向存在的帖子，
    // 避免拆成孤立碎块；墓碑只在详情页链路上展示。
    const delTs = Array.isArray(deletedTombstones) ? deletedTombstones : [];
    const children = await notesColl.where({ repostOf: id }).get();
    for (const child of children.data || []) {
      const prev = Array.isArray(child.tombstoneAncestorIds)
        ? child.tombstoneAncestorIds
        : [];
      const patch = {
        // child 原有墓碑（原本就贴着 child）在前，其次才是本次被删节点，
        // 最后是被删节点自身携带的更上层墓碑——整体保持 nearest-first。
        tombstoneAncestorIds: [...prev, id, ...delTs],
      };
      if (parentOf) {
        patch.repostOf = parentOf;
      } else {
        patch.repostOf = "";
        patch.repostKind = "quote";
      }
      await notesColl.doc(child._id).update(patch);
    }
  } catch (e) {
    console.error(`[api] reattachChildReplies failed for ${id}:`, e);
  }
}

// 查询账号名称（userAccounts 中登记的 username），无则返回空串。
async function getAccountName(targetUid) {
  if (!targetUid) return "";
  try {
    const { data } = await userAccounts
      .where({ uid: targetUid })
      .limit(1)
      .get();
    return (data && data[0] && data[0].username) || "";
  } catch (e) {
    return "";
  }
}

// 账号名称规则：2-20 位，中英文、数字、下划线。
function normalizeUsername(raw) {
  const u = String(raw || "").trim();
  if (!/^[\u4e00-\u9fa5a-zA-Z0-9_]{2,20}$/.test(u)) return null;
  return u;
}

// 真实姓名：2-20 位汉字，允许少数民族姓名中的间隔号 ·。合法返回空串。
function validateRealName(raw) {
  const n = String(raw || "").trim();
  if (!n) return "请输入真实姓名";
  if (n.length < 2 || n.length > 20) return "姓名长度需为 2-20 个汉字";
  if (!/^[\u4e00-\u9fa5·]+$/.test(n)) return "姓名仅支持汉字与间隔号 ·";
  return "";
}

// 18 位身份证号校验（GB 11643-1999）：长度、地区码、出生日期、校验位。合法返回空串。
function validateIdCard(raw) {
  const id = String(raw || "").trim().toUpperCase();
  if (!id) return "请输入身份证号";
  if (!/^\d{17}[\dX]$/.test(id)) return "身份证号需为 18 位数字，末位可为 X";
  const region = Number(id.slice(0, 2));
  if (region < 11 || region > 82) return "身份证号前两位地区码无效";
  const y = Number(id.slice(6, 10));
  const m = Number(id.slice(10, 12));
  const d = Number(id.slice(12, 14));
  const dt = new Date(y, m - 1, d);
  if (
    dt.getFullYear() !== y ||
    dt.getMonth() !== m - 1 ||
    dt.getDate() !== d ||
    dt.getTime() > Date.now()
  ) {
    return "身份证号中的出生日期无效";
  }
  const weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  const codes = "10X98765432";
  let sum = 0;
  for (let i = 0; i < 17; i++) sum += Number(id[i]) * weights[i];
  if (codes[sum % 11] !== id[17]) return "身份证号校验位不正确，请核对";
  return "";
}

// 姓名脱敏：2 字「张*」，3 字「李**」，4 字及以上保留首末字「欧**娜」。
function maskRealName(raw) {
  const n = String(raw || "").trim();
  if (n.length <= 1) return "***";
  if (n.length === 2) return n[0] + "*";
  if (n.length === 3) return n[0] + "**";
  return n[0] + "**" + n[n.length - 1];
}

// scrypt + 随机盐哈希密码，只存哈希不存明文。
function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 32).toString("hex");
}
