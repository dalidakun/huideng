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
        const res = await notes
          .where({ ownerUserId: uid })
          .orderBy("updatedAt", "desc")
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        return ok({ notes: res.data });
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
        });
        const res = await base
          .orderBy("createdAt", "desc")
          .skip((page - 1) * pageSize)
          .limit(pageSize)
          .get();
        const { total } = await base.count();
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
          .where({ visibility: "public", status: "normal" });

        // 屏蔽的用户内容从广场隐藏
        let blocked = [];
        if (uid) {
          const br = await blocks.where({ blockerId: uid }).limit(1000).get();
          blocked = br.data.map((r) => r.blockedId);
        }
        const filterBlocked = (arr) =>
          blocked.length ? arr.filter((n) => !blocked.includes(n.ownerUserId)) : arr;

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
        return ok({ note });
      }

      // 阅读量 +1（打开详情页时调用一次）。
      case "incView": {
        const id = String(event.id || "");
        const { data } = await notes.doc(id).get();
        const note = data && data[0];
        if (!note) return fail("not_found");
        if (note.visibility !== "public" && note.ownerUserId !== uid) {
          return fail("not_found");
        }
        const viewCount = (note.viewCount || 0) + 1;
        await notes.doc(id).update({ viewCount });
        return ok({ viewCount });
      }

      // 转发：以当前用户身份创建一条新笔记，并关联原笔记。
      // quote 为空 → 直接转发（内容与原笔记相同）；quote 非空 → 引用转发（内容为用户的引言 + 原笔记快照）。
      case "repostNote": {
        if (!uid) return fail("unauthorized");
        const id = String(event.id || "");
        const quote = String(event.quote || "").trim().slice(0, 500);
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
          base.title = String(src.title || "无标题").slice(0, 100);
          base.content = String(src.content || "");
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
        if (src.ownerUserId && src.ownerUserId !== uid) {
          await activities.add({
            userId: src.ownerUserId,
            type: "repost_me",
            noteId: res.id,
            noteTitle: newTitle,
            sourceTitle: String(src.title || "无标题").slice(0, 100),
            content: quote,
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
        const existing = await favorites.where({ noteId, userId: uid }).get();
        if (existing.data.length > 0) {
          await favorites.doc(existing.data[0]._id).remove();
          return ok({ favorited: false });
        }
        await favorites.add({ noteId, userId: uid, createdAt: now() });
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

      // 批量获取用户展示信息（昵称）。名字取该用户最新一篇公开笔记的署名。
      case "getUserProfiles": {
        const ids = (Array.isArray(event.ids) ? event.ids.map(String) : [])
          .filter(Boolean)
          .slice(0, 200);
        const users = [];
        for (const id of ids) {
          let name = "同修";
          try {
            const { data: ndata } = await notes
              .where({ ownerUserId: id, visibility: "public", status: "normal" })
              .orderBy("createdAt", "desc")
              .limit(1)
              .get();
            const n = ndata && ndata[0];
            if (n && n.authorName) name = String(n.authorName);
          } catch (e) {}
          users.push({ id, name });
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
          return ok({ following: false });
        }
        await follows.add({
          followerId: uid,
          followeeId: target,
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
        const [f, fl, r1, r2, r3] = await Promise.all([
          follows.where({ followerId: uid }).limit(1000).get(),
          follows.where({ followeeId: uid }).limit(1000).get(),
          activities
            .where({ userId: uid, type: "reply", viewed: false })
            .count(),
          activities
            .where({ userId: uid, type: "repost_me", viewed: false })
            .count(),
          activities
            .where({ userId: uid, type: "like_me", viewed: false })
            .count(),
        ]);
        return ok({
          following: f.data.length,
          followers: fl.data.length,
          unread: r1.total + r2.total + r3.total,
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
