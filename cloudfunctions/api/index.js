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

async function resolveUid(event, context) {
  // 1) 新架构：context.environment（JSON 字符串）里的 TCB_UUID
  try {
    const raw = context.environment;
    const env =
      typeof raw === "string" ? JSON.parse(raw) : raw && typeof raw === "object" ? raw : null;
    if (env && env.TCB_UUID) return String(env.TCB_UUID);
  } catch (e) {}

  // 2) 旧架构：parseContext().environ 里的 TCB_UUID
  try {
    const ctx = app.parseContext(context);
    if (ctx && ctx.environ && ctx.environ.TCB_UUID) {
      return String(ctx.environ.TCB_UUID);
    }
  } catch (e) {}

  // 3) 进程级环境变量（旧架构实例级）
  if (process.env.TCB_UUID) return String(process.env.TCB_UUID);

  // 4) 客户端显式传入的 access token → 官方接口解析调用者
  const token = event.__accessToken || (event.data && event.data.__accessToken);
  if (token) {
    try {
      const envId = process.env.TCB_ENV || "randeng-d8gs968w22a3d98e8";
      const res = await fetch(
        `https://${envId}.api.tcloudbasegateway.com/auth/v1/user/me`,
        { headers: { Authorization: `Bearer ${token}` } }
      );
      if (res.ok) {
        const profile = await res.json();
        const u = profile.user_id || profile.sub || profile.uid || "";
        if (u) return String(u);
      } else {
        console.log("[api] user/me status:", res.status);
      }
    } catch (e) {
      console.log("[api] token resolve error:", e.message);
    }
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
        return ok({
          uid,
          tokenPresent: !!(event.__accessToken || (event.data && event.data.__accessToken)),
          envTcbUuid: process.env.TCB_UUID || "",
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
        return ok({});
      }

      case "getMyNotes": {
        if (!uid) return fail("unauthorized");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 50, 100);
        // 排除公告（kind: announcement），公告只在公告栏展示。
        const base = notes.where({
          ownerUserId: uid,
          kind: _.neq("announcement"),
        });
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

        // 热门排序：阅读量 + 点赞×3 + 评论×5 + 转发×8，依次排列。
        if (sort === "hot") {
          const all = [];
          let skip = 0;
          while (true) {
            const r = await base.skip(skip).limit(1000).get();
            const batch = r.data || [];
            all.push(...batch);
            if (batch.length < 1000) break;
            skip += 1000;
          }
          const scored = filterBlocked(all).map((n) => ({
            ...n,
            _hotScore:
              (n.viewCount || 0) +
              (n.likeCount || 0) * 3 +
              (n.commentCount || 0) * 5 +
              (n.repostCount || 0) * 8,
          }));
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
        // 读经时长：同表 readingSeconds（他人主页徽章点亮依据）。
        const accounts = {};
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
              }
            }
          } catch (e) {}
        }
        // 昵称/签名/加入时间/头像/横幅：从 userData.payload 取（由 SyncService 定期推送）。
        // 头像横幅为 base64，存于 payload.files.avatar / payload.files.banner。
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
              profiles[row.uid] = {
                nickname: String(prefs.user_nickname || "").slice(0, 30),
                tagline: String(prefs.user_tagline || "").slice(0, 60),
                joinTime: Number(prefs.user_created_at) || 0,
                avatar:
                  avatar && typeof avatar.data === "string" && avatar.data
                    ? avatar.data
                    : "",
                banner:
                  banner && typeof banner.data === "string" && banner.data
                    ? banner.data
                    : "",
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
          users.push({
            id,
            name,
            account: accounts[id] || "",
            verified: !!verified[id],
            tagline: p.tagline || "",
            joinTime: p.joinTime || 0,
            canonRead: canonRead[id] || 0,
            canonTotal: canonTotal[id] || 0,
            readingSeconds: readingSeconds[id] || 0,
            avatar: p.avatar || "",
            banner: p.banner || "",
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
        return ok({ comment: { _id: res.id, noteId, authorId: uid, authorName: actorName, content, createdAt: now() } });
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
        return ok({ comments: res.data });
      }

      // ==================== 消息中心 ====================

      // 拉取「收到的互动」通知列表（分页，最新在前）。不自动标记已读，
      // 只有用户真正查看对应通知或执行「全部标记已读」后未读数才减少。
      case "getNotifications": {
        if (!uid) return fail("unauthorized");
        const page = Math.max(1, Number(event.page) || 1);
        const pageSize = Math.min(Number(event.pageSize) || 20, 50);
        const base = activities.where({
          userId: uid,
          type: _.in(receivedTypes),
        });
        const res = await base
          .orderBy("createdAt", "desc")
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        const { total } = await base.count();
        // 拉取互动用户头像（base64，存于 userData.payload.files.avatar）、
        // 账号名与认证状态，消息页直接展示真实头像而非默认 App 图标。
        const items = res.data || [];
        const actorIds = [...new Set(items.map((a) => a.actorId).filter(Boolean))];
        const avatars = {};
        const accounts = {};
        const verified = {};
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
              const av = row && row.payload && row.payload.files && row.payload.files.avatar;
              if (av && typeof av.data === "string" && av.data) {
                avatars[row.uid] = av.data;
              }
            }
          } catch (e) {}
        }
        for (const a of items) {
          if (avatars[a.actorId]) a.actorAvatar = avatars[a.actorId];
          if (accounts[a.actorId]) a.actorAccount = accounts[a.actorId];
          if (verified[a.actorId]) a.actorVerified = true;
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
        let unread = 0;
        for (const t of receivedTypes) {
          const r = await activities
            .where({ userId: uid, type: t, viewed: false })
            .count();
          unread += r.total || 0;
        }
        return ok({ unread });
      }

      // 标记通知已读：传 ids 标记指定通知；all=true 全部标记已读。
      case "markNotificationsRead": {
        if (!uid) return fail("unauthorized");
        if (event.all === true) {
          await activities
            .where({ userId: uid, type: _.in(receivedTypes), viewed: false })
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
        const json = JSON.stringify(payload);
        if (json.length > 2 * 1024 * 1024) return fail("payload_too_large");
        const { data } = await userData.where({ uid }).limit(1).get();
        const row = data && data[0];
        const record = {
          uid,
          payload,
          payloadJson: json,
          updatedAt: now(),
        };
        if (row) {
          await userData.doc(row._id).update(record);
        } else {
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
