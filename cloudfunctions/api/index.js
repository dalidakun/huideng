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
      let body = "";
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => {
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
    for (let i = 0; i < ids.length; i += 100) {
      const chunk = ids.slice(i, i + 100);
      try {
        const { data } = await userAccounts
          .where({ uid: _.in(chunk) })
          .get();
        for (const a of data || []) accounts[a.uid] = a.username || "";
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
    for (let i = 0; i < ids.length; i += 100) {
      const chunk = ids.slice(i, i + 100);
      try {
        const { data } = await userAccounts
          .where({ uid: _.in(chunk) })
          .get();
        for (const a of data || []) {
          reads[a.uid] = Math.max(0, Number(a.canonRead) || 0);
          totals[a.uid] = Math.max(0, Number(a.canonTotal) || 0);
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
          // 按类型统计通知数（单次查询 + 内存过滤，避免 14 次查询超时）
          const receivedSet = new Set(receivedTypes);
          const allActRes = await activities
            .where({ userId: uid })
            .orderBy("createdAt", "desc")
            .limit(200)
            .get();
          const allNotifActs = (allActRes.data || []).filter((a) => receivedSet.has(a.type));
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
        const res = await notes.add({
          ownerUserId: uid,
          title: String(event.title || "无标题").slice(0, 100),
          content: String(event.content || ""),
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
          noteId: res.id,
          noteTitle: String(event.title || "无标题").slice(0, 100),
          content: String(event.content || ""),
          viewed: false,
          createdAt: now(),
        });
        // 新发布的笔记可能含尚未上过热门榜的 #话题/$经名，立即失效热门榜缓存，
        // 让下一次拉取能看到这些新话题/新经书。
        hotDiscussionsCache = null;
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
        await notes.doc(id).update(patch);
        // 内容/可见性/状态改变会改变 #话题/$经名的贡献，重新聚合热门榜。
        if (event.content != null || event.visibility != null || event.status != null) {
          hotDiscussionsCache = null;
        }
        return ok({ id });
      }

      case "deleteNote": {
        if (!uid) return fail("unauthorized");
        const id = String(event.id || "");
        const note = await getOwnedNote(notes, id, uid);
        if (!note) return fail("not_found");
        await notes.doc(id).remove();
        await likes.where({ noteId: id }).remove();
        await comments.where({ noteId: id }).remove();
        await reports.where({ noteId: id }).remove();
        await favorites.where({ noteId: id }).remove();
        // 删除笔记后其 #话题/$经名贡献消失，重新聚合热门榜。
        hotDiscussionsCache = null;
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
        const base = notes
          .where({
            visibility: "public",
            status: "normal",
            kind: _.neq("announcement"),
          });

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
          const hotPoolMin = 60;
          let all = [];
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
          const pageNotes = scored.slice((page - 1) * pageSize, (page - 1) * pageSize + pageSize);
          const notesOut = pageNotes.map(({ _hotScore, ...rest }) => rest);
          await attachAuthorAccounts(notesOut);
        await attachAuthorVerified(notesOut);
        await attachAuthorCanonProgress(notesOut);
        return ok({
            notes: notesOut,
            total,
            hasMore: (page - 1) * pageSize + pageNotes.length < total,
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
        return ok({
          notes: filtered,
          total,
          hasMore: (page - 1) * pageSize + res.data.length < total,
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
        });
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

      // 讨论页热门榜：聚合公开帖子中的 #话题 与 $经名 引用热度，
      // 返回 top50 话题 + top50 经文（客户端卡片取前 3 + 当日轮换，「更多」页展示全榜）。
      case "getHotDiscussions": {
        const nowMs = Date.now();
        // 15 分钟 TTL 缓存：避免每次请求都全表扫描。
        if (hotDiscussionsCache && nowMs - hotDiscussionsCache.at < 15 * 60 * 1000) {
          return ok({ ...hotDiscussionsCache.data, cached: true });
        }
        const topicRe = /#([^\s#，。！？,;:!?（）()]+)/g;
        const sutraRe = /\$([^\s#$，。！？,;:!?（）()@]+)/g;
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
        // 滚动窗口只统计最近 14 天的公开帖子（更早的帖子完全不进入榜单），
        // 避免热门话题/经文靠历史存量霸顶——必须持续有近期讨论才能保持上榜。
        // 按最新在前扫描；因按 createdAt 倒序，一旦出现早于窗口的帖子即停止，
        // 并设置扫描上限控制冷启动耗时。
        const window = nowMs - 14 * 24 * 3600000;
        // 单条记录对热度榜的贡献（话题帖、经书讨论都复用同款聚合逻辑）：
        // - ageHours 小（新发布）且 engagement 越高，得分越高；
        // - 经书讨论（sutraDiscussions）的 sutraTitle 字段视作一条 $经名 引用，
        //   content 中的 #话题 也按话题帖一样计分，确保经书讨论页与话题讨论页
        //   「在同一份热门榜上」按热度排序展示。
        const aggregateRecord = (createdAt, likeCount, viewCount, commentCount, repostCount, /* regex content */ text, /* 经书讨论专属 */ sutraTitle) => {
          const ageHours = Math.max(0, (nowMs - (createdAt || nowMs)) / 3600000);
          const engagement =
            (viewCount || 0) +
            (likeCount || 0) * 3 +
            (commentCount || 0) * 5 +
            (repostCount || 0) * 8;
          // 得分完全由互动量驱动：0 互动 → 0 分（垫底显示，保证新话题/经书仍在总榜但排在后面），
          // 有互动 → 按互动量除以时间衰减因子，新互动比老互动更值钱。
          // 不再用 (1 + engagement)：避免 0 互动的新帖凭"新鲜度"白拿 ~0.4 分冲到前三。
          const score = engagement / Math.pow(ageHours + 2, 1.3);
          // 经书讨论：直接以 sutraTitle 字段为 $经名 引用计入经文榜。
          if (sutraTitle) {
            const s = String(sutraTitle).trim();
            if (s && s.length <= 24) {
              const cur = sutras.get(s) || { score: 0, posts: 0, last: 0 };
              cur.score += score;
              cur.posts += 1;
              if ((createdAt || 0) > cur.last) cur.last = createdAt || 0;
              sutras.set(s, cur);
            }
          }
          // 通用：从正文中识别 #话题 / $经名，每个去重后累加。
          if (text) {
            topicRe.lastIndex = 0;
            const seenT = new Set();
            let m;
            while ((m = topicRe.exec(text)) !== null) {
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
            sutraRe.lastIndex = 0;
            const seenS = new Set();
            while ((m = sutraRe.exec(text)) !== null) {
              const s = m[1];
              if (s.length > 24 || seenS.has(s)) continue;
              seenS.add(s);
              const cur = sutras.get(s) || { score: 0, posts: 0, last: 0 };
              cur.score += score;
              cur.posts += 1;
              if ((createdAt || 0) > cur.last) cur.last = createdAt || 0;
              sutras.set(s, cur);
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
        let done = false;
        let skip = 0;
        while (scanned < cap && !done) {
          const r = await hotBase
            .orderBy("createdAt", "desc")
            .skip(skip)
            .limit(1000)
            .get();
          const batch = r.data || [];
          if (batch.length === 0) break;
          for (const n of batch) {
            if ((n.createdAt || 0) < window) {
              done = true;
              break;
            }
            if (++scanned > cap) break;
            aggregateRecord(
              n.createdAt,
              n.likeCount,
              n.viewCount,
              n.commentCount,
              n.repostCount,
              `${n.title || ""}\n${n.content || ""}`
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
          let sdDone = false;
          while (sdScanned < sdCap && !sdDone) {
            const sr = await sutraDiscussions
              .orderBy("createdAt", "desc")
              .skip(sdSkip)
              .limit(1000)
              .get();
            const sBatch = sr.data || [];
            if (sBatch.length === 0) break;
            for (const d of sBatch) {
              if ((d.createdAt || 0) < window) {
                sdDone = true;
                break;
              }
              if (++sdScanned > sdCap) break;
              aggregateRecord(
                d.createdAt,
                d.likeCount,
                0, // 经书讨论没有 viewCount
                0, // 没有 commentCount
                0, // 没有 repostCount
                d.content || "",
                d.sutraTitle || ""
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
        await notes.doc(id).update({
          repostCount: (src.repostCount || 0) + 1,
        });
        const newTitle = String(base.title || "无标题").slice(0, 100);
        const reposterName = String(event.authorName || "同修").slice(0, 30);
        await activities.add({
          userId: uid,
          type: "repost",
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
          return ok({ favorited: false });
        }
        await favorites.add({ noteId, userId: uid, createdAt: now() });
        if (note.ownerUserId && note.ownerUserId !== uid) {
          await activities.add({
            userId: note.ownerUserId,
            type: "favorite_me",
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
                accounts[a.uid] = a.username || "";
                canonRead[a.uid] = Math.max(0, Number(a.canonRead) || 0);
                canonTotal[a.uid] = Math.max(0, Number(a.canonTotal) || 0);
                readingSeconds[a.uid] = Math.max(0, Number(a.readingSeconds) || 0);
                // 首次设置 @账户 时的写入时间戳（毫秒），作为注册时间一级候选。
                if (a.createdAt) accountCreatedAt[a.uid] = Number(a.createdAt) || 0;
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
          return ok({ following: false });
        }
        await follows.add({
          followerId: uid,
          followeeId: target,
          createdAt: now(),
        });
        await activities.add({
          userId: target,
          type: "follow_me",
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
        } else {
          await likes.add({ noteId, userId: uid, createdAt: now() });
          likeCount = (note.likeCount || 0) + 1;
          if (note.ownerUserId && note.ownerUserId !== uid) {
            await activities.add({
              userId: note.ownerUserId,
              type: "like_me",
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
        return ok({ comment: { _id: res.id, noteId, authorId: uid, authorName: actorName, authorAccount: await getAccountName(uid), content, likeCount: 0, createdAt: now() } });
      }

      // ==================== 菩提空间：我的互动动态 ====================

      case "getMyActivities": {
        if (!uid) return fail("unauthorized");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 20, 50);
        const res = await activities
          .where({ userId: uid })
          .orderBy("createdAt", "desc")
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        // 拉取到的「收到的互动」视为已查看。
        const received = ["reply", "repost_me", "like_me"];
        const toMark = (res.data || []).filter(
          (a) => received.includes(a.type) && a.viewed !== true
        );
        await Promise.all(
          toMark.map((a) => activities.doc(a._id).update({ viewed: true }))
        );
        const { total } = await activities.where({ userId: uid }).count();
        return ok({
          activities: res.data,
          total,
          hasMore: (page - 1) * pageSize + res.data.length < total,
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
      // 注意：CloudBase SDK 的 _.in() 对 type 字段可能不生效，
      // 但逐个类型查询（14 次数据库调用）会导致云函数超时。
      // 改为单次查询 userId 的所有活动，内存中过滤 receivedTypes 类型。
      case "getNotifications": {
        if (!uid) return fail("unauthorized");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 20, 50);

        // 单次查询：拉取用户所有活动（最多 500 条），内存中过滤通知类型。
        // 比逐个类型查询快 10 倍以上，避免云函数超时。
        const receivedSet = new Set(receivedTypes);
        const fetchLimit = Math.max(page * pageSize, 200);
        const res = await activities
          .where({ userId: uid })
          .orderBy("createdAt", "desc")
          .limit(fetchLimit)
          .get();
        const allNotif = (res.data || []).filter((a) => receivedSet.has(a.type));
        const total = allNotif.length;

        // 内存分页
        const start = (page - 1) * pageSize;
        const items = allNotif.slice(start, start + pageSize);

        console.log(`[api/getNotifications] uid=${uid} page=${page} returned=${items.length} total=${total} fetched=${(res.data || []).length}`);
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
        // 并行查询 7 种类型，总耗时约等于 1 次查询。
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
          // 单次更新所有未读活动（含自己发的 share/comment 等，无副作用）。
          await activities
            .where({ userId: uid, viewed: false })
            .update({ viewed: true });
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
        return ok({});
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
        const json = JSON.stringify(merged);
        if (json.length > 2 * 1024 * 1024) return fail("payload_too_large");
        const nowMs = now();
        const record = {
          uid,
          payload: merged,
          payloadJson: json,
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
        return ok({ updatedAt: record.updatedAt });
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
        await notes.doc(id).update({ status: "hidden" });
        return ok({});
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
