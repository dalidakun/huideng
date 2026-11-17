/**
 * 本地最小化验证：用内存假 DB 跑 badge + AI 额度这两条新链路。
 * 只验证服务端逻辑，不替代真实云开发环境测试。
 * 用法：node tools/test-badge-api.js
 */
const Module = require('module');
const path = require('path');

const rows = new Map(); // collection -> Map(id -> doc)

function clone(v) {
  return v == null ? v : JSON.parse(JSON.stringify(v));
}

const CMD = {
  in: (v) => ({ __op: 'in', v }),
  gt: (v) => ({ __op: 'gt', v }),
  lt: (v) => ({ __op: 'lt', v }),
  neq: (v) => ({ __op: 'neq', v }),
  inc: (v) => ({ __op: 'inc', v }),
};

function match(doc, q) {
  for (const key of Object.keys(q || {})) {
    const cond = q[key];
    const val = doc[key];
    if (cond && cond.__op) {
      if (cond.__op === 'in' && !cond.v.includes(val)) return false;
      if (cond.__op === 'gt' && !(val > cond.v)) return false;
      if (cond.__op === 'lt' && !(val < cond.v)) return false;
      if (cond.__op === 'neq' && val === cond.v) return false;
    } else if (val !== cond) {
      return false;
    }
  }
  return true;
}

function applyPatch(doc, patch) {
  for (const key of Object.keys(patch || {})) {
    const v = patch[key];
    if (v && v.__op === 'inc') doc[key] = (Number(doc[key]) || 0) + v.v;
    else doc[key] = v;
  }
}

class Query {
  constructor(coll, q) {
    this.coll = coll;
    this.q = q || {};
    this.max = Infinity;
  }
  limit(n) {
    this.max = n;
    return this;
  }
  orderBy() {
    return this;
  }
  field() {
    return this;
  }
  skip() {
    return this;
  }
  async get() {
    const list = [];
    for (const doc of this.coll.rows.values()) {
      if (match(doc, this.q)) list.push(clone(doc));
      if (list.length >= this.max) break;
    }
    return { data: list };
  }
  async count() {
    let n = 0;
    for (const doc of this.coll.rows.values()) if (match(doc, this.q)) n++;
    return { total: n };
  }
  async update(patch) {
    let n = 0;
    for (const doc of this.coll.rows.values()) {
      if (match(doc, this.q)) {
        applyPatch(doc, patch);
        n++;
      }
    }
    return { updated: n };
  }
  async remove() {
    let n = 0;
    for (const [id, doc] of [...this.coll.rows.entries()]) {
      if (match(doc, this.q)) {
        this.coll.rows.delete(id);
        n++;
      }
    }
    return { deleted: n };
  }
}

class Coll {
  constructor(name) {
    this.name = name;
    this.rows = new Map();
  }
  doc(id) {
    const self = this;
    return {
      async get() {
        const d = self.rows.get(id);
        return { data: d ? [clone(d)] : [] };
      },
      async set(data) {
        self.rows.set(id, Object.assign({ _id: id }, clone(data)));
        return { updated: 1 };
      },
      async update(patch) {
        const d = self.rows.get(id);
        if (!d) return { updated: 0 };
        applyPatch(d, patch);
        return { updated: 1 };
      },
      async remove() {
        self.rows.delete(id);
        return { deleted: 1 };
      },
    };
  }
  async add(data) {
    const id = data._id || 'id_' + Math.random().toString(36).slice(2);
    if (this.rows.has(id)) throw new Error('DUPLICATE');
    this.rows.set(id, Object.assign({ _id: id }, clone(data)));
    return { id };
  }
  where(q) {
    return new Query(this, q);
  }
  limit(n) {
    return new Query(this, {}).limit(n);
  }
  async get() {
    return new Query(this, {}).get();
  }
  async count() {
    return new Query(this, {}).count();
  }
  orderBy() {
    return new Query(this, {});
  }
  skip() {
    return new Query(this, {});
  }
}

class DB {
  constructor() {
    this.colls = new Map();
  }
  collection(name) {
    if (!this.colls.has(name)) this.colls.set(name, new Coll(name));
    return this.colls.get(name);
  }
  async createCollection(name) {
    if (!this.colls.has(name)) this.colls.set(name, new Coll(name));
  }
  get command() {
    return CMD;
  }
}

const db = new DB();
const app = {
  database: () => db,
  parseContext: () => ({ environ: { TCB_UUID: 'u1' } }),
};

const origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === '@cloudbase/node-sdk') {
    return { init: () => app, parseContext: () => ({ environ: { TCB_UUID: 'u1' } }) };
  }
  return origLoad.call(this, request, parent, isMain);
};

process.env.TCB_ENV = 'test-env';
const api = require(path.resolve(__dirname, '..', 'cloudfunctions', 'api', 'index.js'));

function ctx(uid) {
  return { environment: JSON.stringify({ TCB_UUID: uid }) };
}

async function call(event, uid) {
  return api.main(event, ctx(uid));
}

(async () => {
  let fail = 0;
  const check = (cond, msg) => {
    console.log((cond ? '  ✓ ' : '  ✗ ') + msg);
    if (!cond) fail++;
  };

  console.log('[旧自助单号入口已停用]');
  const legacy = await call(
    { action: 'submitBadgeTxn', channel: 'wechat', plan: '199', txnNo: '123456789012345678' },
    'u2'
  );
  check(legacy.ok === false, '不再接受交易单号自动开通');

  console.log('[AI 免费额度 1000]');
  let deniedAt = 0;
  for (let i = 0; i < 1001; i++) {
    const r = await call(
      { action: 'getParagraphTranslation', paragraph: '第' + i + '段测试经文' },
      'u2'
    );
    if (r.ok !== true) {
      deniedAt = i + 1;
      break;
    }
  }
  check(deniedAt === 1001, '第 1001 段被拒绝（实际 ' + deniedAt + '）');
  const q2 = await call({ action: 'getMyAiQuota' }, 'u2');
  check(q2.quota && q2.quota.freeLimit === 1000, '免费上限 1000');

  const repeat = await call(
    { action: 'getParagraphTranslation', paragraph: '第0段测试经文' },
    'u2'
  );
  check(repeat.ok === true, '已计过的同一段重复打开不扣额度');

  console.log('[管理员准备]');
  await db.collection('admins').add({ uid: 'u1' });
  await db.collection('admins').add({ uid: 'u3' });
  await db.collection('userAccounts').add({
    uid: 'u1',
    username: 'randeng',
    usernameKey: 'randeng',
    phone: '13800000001',
  });
  await db.collection('userAccounts').add({
    uid: 'u2',
    username: 'bob',
    usernameKey: 'bob',
    phone: '13800000002',
  });
  await db.collection('userAccounts').add({
    uid: 'u3',
    username: 'other',
    usernameKey: 'other',
    phone: '13800000003',
  });

  const rootFlag = await call({ action: 'isAdmin' }, 'u1');
  check(rootFlag.isAdmin === true && rootFlag.isRootAdmin === true,
    '@randeng 是第一管理员');
  const otherFlag = await call({ action: 'isAdmin' }, 'u3');
  check(otherFlag.isAdmin === true && otherFlag.isRootAdmin === false,
    '其他管理员不是第一管理员');
  const userFlag = await call({ action: 'isAdmin' }, 'u2');
  check(userFlag.isAdmin === false && userFlag.isRootAdmin === false,
    '普通用户既不是管理员也不是第一管理员');

  console.log('[第一管理员按账户名开通]');
  const grant = await call({ action: 'adminSetSubscription', input: '@bob', enabled: true }, 'u1');
  check(grant.ok === true, '第一管理员按「@账户名」开通成功');
  const v2 = await call({ action: 'getMyVerification' }, 'u2');
  check(v2.verified === true, '徽标已发放');
  const q3 = await call({ action: 'getMyAiQuota' }, 'u2');
  check(q3.quota && q3.quota.unlimited === true, '无限翻译已开通');
  const after = await call(
    { action: 'getParagraphTranslation', paragraph: '额度用完后的一段' },
    'u2'
  );
  check(after.ok === true, '开通后无限翻译可用');

  console.log('[开通消息通知]');
  const notif = await call(
    { action: 'getNotifications', page: 1, pageSize: 20 },
    'u2'
  );
  const subMsg = (notif.activities || []).find((a) => a.type === 'subscription');
  check(!!subMsg && String(subMsg.content || '').includes('恭喜你获得无限翻译和认证徽标'),
    '消息页收到开通信息');
  const unread = await call({ action: 'getNotificationUnreadCount' }, 'u2');
  check(unread.unread >= 1, '开通信息计入未读');

  console.log('[其他管理员不能开通]');
  const otherGrant = await call(
    { action: 'adminSetSubscription', input: '@bob', enabled: true },
    'u3'
  );
  check(otherGrant.ok === false, '非 @randeng 管理员无权开通');

  console.log('[订阅不可取消]');
  const cancel = await call(
    { action: 'adminSetSubscription', input: 'bob', enabled: false },
    'u1'
  );
  check(cancel.ok === false, '取消订阅被拒绝');
  const u2vAfterCancel = await call({ action: 'getMyVerification' }, 'u2');
  check(u2vAfterCancel.verified === true, '取消被拒后徽标仍在');

  console.log('[管理员清空]');
  const reset = await call({ action: 'adminResetBadges' }, 'u1');
  check(reset.ok === true && reset.cleared === true, '清空所有徽标（含管理员自己）');
  const u2v = await call({ action: 'getMyVerification' }, 'u2');
  check(u2v.verified === false, '其他用户徽标已清空');
  const u1v = await call({ action: 'getMyVerification' }, 'u1');
  check(u1v.verified === false, '管理员自己也无徽标');

  console.log(fail ? '\n测试失败：' + fail : '\n测试通过');
  process.exit(fail ? 1 : 0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
