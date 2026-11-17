/* 交易笔记云函数回归测试（Node，不需要浏览器、不连云端）。
 *
 * 用法：node tools/note_api_test.js
 *
 * 用内存版 db / 云存储把 cloudfunctions/api/trade.js 跑起来，验证：
 *   1. 未登录不能读写笔记；
 *   2. 只收 jpeg/png/webp，超过 1.5MB 拒绝；
 *   3. 上传返回的 fileID 只能在本人目录下引用，跨用户 / .. 路径会被丢掉；
 *   4. 新建、列表、详情、更新（删图同步删云存储）、删除整条链路；
 *   5. 300MB 图片配额、笔记条数不设上限与分页、「别人的笔记读不到」。
 *
 * 改 trade.js 的笔记段后跑一遍，比手点浏览器可靠。
 */

'use strict';

let failures = 0;
let checks = 0;

function assert(cond, msg) {
  checks += 1;
  if (!cond) {
    failures += 1;
    console.error('  x ' + msg);
  } else {
    console.log('  + ' + msg);
  }
}

function clone(v) {
  return v == null ? v : JSON.parse(JSON.stringify(v));
}

/** 极简内存版 CloudBase 数据库：只实现笔记/账号/会话用到的那几个方法。 */
function makeDb() {
  const cols = new Map();
  let seq = 0;

  function store(name) {
    if (!cols.has(name)) cols.set(name, new Map());
    return cols.get(name);
  }

  function matchCond(row, cond) {
    return Object.keys(cond || {}).every((k) => {
      const expected = cond[k];
      if (expected && typeof expected === 'object' && expected.__op === 'gt') {
        return Number(row[k]) > Number(expected.v);
      }
      return row[k] === expected;
    });
  }

  function query(rows, cond) {
    let list = rows.filter((row) => matchCond(row, cond));
    const q = {
      orderBy(field, dir) {
        list.sort((a, b) => {
          const av = a[field] || 0;
          const bv = b[field] || 0;
          return dir === 'desc' ? bv - av : av - bv;
        });
        return q;
      },
      skip(n) {
        list = list.slice(Math.max(0, n | 0));
        return q;
      },
      limit(n) {
        list = list.slice(0, n);
        return q;
      },
      field() {
        return q;
      },
      async get() {
        return { data: list.map(clone) };
      },
      async count() {
        return { total: list.length };
      },
    };
    return q;
  }

  const db = {
    async createCollection() {},
    command: {
      aggregate: {
        sum: (field) => ({ $sum: field }),
      },
      gt: (v) => ({ __op: 'gt', v }),
    },
    collection(name) {
      const rows = store(name);
      return {
        doc(id) {
          return {
            async get() {
              const v = rows.get(id);
              return { data: v ? [clone(v)] : [] };
            },
            async set(data) {
              rows.set(id, clone({ ...data, _id: id }));
              return {};
            },
            async update(patch) {
              const v = rows.get(id);
              if (v) rows.set(id, clone({ ...v, ...patch }));
              return {};
            },
            async remove() {
              rows.delete(id);
              return {};
            },
          };
        },
        where(cond) {
          return query([...rows.values()], cond);
        },
        aggregate() {
          let match = {};
          let group = null;
          const agg = {
            match(cond) {
              match = cond || {};
              return agg;
            },
            group(spec) {
              group = spec || {};
              return agg;
            },
            async end() {
              const list = [...rows.values()].filter((row) =>
                Object.keys(match).every((k) => row[k] === match[k])
              );
              if (!group) return { list: list.map(clone) };
              const out = { _id: null };
              Object.keys(group).forEach((key) => {
                if (key === '_id') return;
                const spec = group[key];
                if (spec && spec.$sum) {
                  const field = String(spec.$sum).replace(/^\$/, '');
                  out[key] = list.reduce(
                    (sum, row) => sum + (Number(row[field]) || 0),
                    0
                  );
                }
              });
              return { list: list.length ? [out] : [] };
            },
          };
          return agg;
        },
        async add(data) {
          const id = data && data._id ? String(data._id) : 'id_' + (++seq);
          rows.set(id, clone({ ...data, _id: id }));
          return { id };
        },
        async count() {
          return { total: rows.size };
        },
      };
    },
    _seed(name, id, doc) {
      store(name).set(id, clone({ ...doc, _id: id }));
    },
    _all(name) {
      return [...store(name).values()].map(clone);
    },
  };

  return db;
}

function makeStorage() {
  const uploaded = [];
  const deleted = [];
  return {
    uploaded,
    deleted,
    async uploadFile({ cloudPath, fileContent }) {
      uploaded.push(cloudPath);
      return {
        fileID: 'cloud://test-env.bucket/' + cloudPath,
        size: fileContent.length,
      };
    },
    async getTempFileURL({ fileList }) {
      return {
        fileList: fileList.map((fileID) => ({
          fileID,
          tempFileURL: 'https://cdn.test/' + encodeURIComponent(fileID),
        })),
      };
    },
    async deleteFile({ fileList }) {
      deleted.push(...fileList);
      return {};
    },
  };
}

const JPEG = Buffer.concat([
  Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]),
  Buffer.alloc(2048, 1),
]);

async function main() {
  const db = makeDb();
  const storage = makeStorage();
  const createTrade = require('../cloudfunctions/api/trade.js');

  const ok = (data) => ({ ok: true, ...(data || {}) });
  const fail = (code) => ({ ok: false, error: code });

  const handle = createTrade({
    db,
    app: storage,
    ok,
    fail,
    hashPassword: (pw, salt) => 'h:' + salt + ':' + pw,
    normalizeUsername: (u) =>
      String(u || '')
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9_]/g, '')
        .slice(0, 20),
  });

  const reg = await handle(
    'tradeRegister',
    { username: 'notetest1', password: 'secret1' },
    ''
  );
  assert(reg.ok && reg.token, '注册测试账号并拿到 token');
  const uid = reg.uid;
  const token = reg.token;

  // ---------------------------------------------------------------- 鉴权
  let r = await handle('tradeNoteList', {}, '');
  assert(!r.ok && r.error === 'unauthorized', '未登录不能列笔记');
  r = await handle('tradeNoteSave', { title: 'x', content: 'y' }, '');
  assert(!r.ok && r.error === 'unauthorized', '未登录不能写笔记');

  // ---------------------------------------------------------------- 上传校验
  r = await handle(
    'tradeNoteUpload',
    { token, data: Buffer.from('not an image').toString('base64') },
    ''
  );
  assert(!r.ok && r.error === 'bad_image', '非图片字节被拒绝');

  r = await handle(
    'tradeNoteUpload',
    { token, data: Buffer.alloc(1.6 * 1024 * 1024, 1).toString('base64') },
    ''
  );
  assert(!r.ok && r.error === 'image_too_large', '超过 1.5MB 被拒绝');

  const up1 = await handle(
    'tradeNoteUpload',
    { token, data: JPEG.toString('base64') },
    ''
  );
  assert(up1.ok && up1.fileId.indexOf('/tradeNotes/' + uid + '/') > 0, '上传成功且路径带 uid');
  assert(up1.size === JPEG.length, '上传返回真实字节数');

  const up2 = await handle(
    'tradeNoteUpload',
    { token, data: JPEG.toString('base64') },
    ''
  );
  assert(up2.ok && up2.fileId !== up1.fileId, '两次上传生成不同 fileID');

  const up3 = await handle(
    'tradeNoteUpload',
    { token, data: JPEG.toString('base64') },
    ''
  );

  // ---------------------------------------------------------------- 新建 / 列表 / 详情
  const inline =
    '<p>回踩 68k 接多，<br>止损 67.2k。</p>' +
    '<img data-file-id="' + up1.fileId + '" alt="">' +
    '<img data-file-id="' + up2.fileId + '" alt="">';
  r = await handle(
    'tradeNoteSave',
    {
      token,
      title: '  11/4 复盘  ',
      content: inline,
      images: [
        { fileId: up1.fileId, size: up1.size },
        { fileId: up2.fileId, size: up2.size },
      ],
    },
    ''
  );
  assert(r.ok && r.noteId, '新建笔记成功');
  const noteId = r.noteId;

  r = await handle('tradeNoteList', { token }, '');
  assert(r.ok && r.notes.length === 1, '列表返回 1 条');
  assert(r.notes[0].title === '11/4 复盘', '标题两端空格被去掉');
  assert(r.notes[0].imageCount === 2, '列表带图片数量');
  assert(
    r.notes[0].preview.indexOf('<') < 0 && r.notes[0].preview.indexOf('\n') < 0,
    '列表预览是纯文字且压掉换行'
  );
  assert(r.usage.count === 1 && r.usage.bytes === up1.size + up2.size, '用量统计正确');

  r = await handle('tradeNoteGet', { token, noteId }, '');
  assert(r.ok && r.note.images.length === 2, '详情返回 2 张图');
  assert(
    r.note.content.indexOf('src="https://cdn.test/') > 0,
    '正文内联图片换成了临时链接'
  );

  // ---------------------------------------------------------------- 跨用户 / 越权
  const reg2 = await handle(
    'tradeRegister',
    { username: 'notetest2', password: 'secret2' },
    ''
  );
  const token2 = reg2.token;

  r = await handle('tradeNoteGet', { token: token2, noteId }, '');
  assert(!r.ok && r.error === 'not_found', '别人的笔记读不到');

  r = await handle(
    'tradeNoteSave',
    {
      token: token2,
      title: '想引用别人的图',
      content:
        '<p>x</p><img data-file-id="' + up1.fileId + '" alt="">' +
        '<img data-file-id="cloud://test-env.bucket/tradeNotes/' + uid + '/../x.jpg" alt="">',
      images: [
        { fileId: up1.fileId, size: 1 },
        { fileId: 'cloud://test-env.bucket/tradeNotes/' + uid + '/../x.jpg', size: 1 },
      ],
    },
    ''
  );
  assert(r.ok && r.imageCount === 0, '别人的 fileID / .. 路径被丢掉');

  // ---------------------------------------------------------------- 更新：删掉的图同步删云存储
  storage.deleted.length = 0;
  r = await handle(
    'tradeNoteSave',
    {
      token,
      noteId,
      title: '11/4 复盘',
      content: '<p>只留一张图。</p><img data-file-id="' + up2.fileId + '" alt="">',
      images: [{ fileId: up2.fileId, size: up2.size }],
    },
    ''
  );
  assert(r.ok && r.imageCount === 1, '更新为 1 张图');
  assert(
    storage.deleted.length === 1 && storage.deleted[0] === up1.fileId,
    '被移除的图片同步删除'
  );

  // ---------------------------------------------------------------- 富文本清洗
  r = await handle(
    'tradeNoteSave',
    {
      token,
      title: '富文本清洗',
      content:
        '<p onclick="alert(1)">A<script>alert(2)</script>' +
        '<span style="color:#305c38;position:absolute">B</span>' +
        '<a href="javascript:alert(3)">C</a></p>',
      lineHeight: 2
    },
    ''
  );
  assert(r.ok && r.noteId, '富文本笔记保存成功');
  const richId = r.noteId;
  r = await handle('tradeNoteGet', { token, noteId: richId }, '');
  assert(r.ok && r.note.contentFormat === 'html', '正文按 HTML 格式存储');
  assert(r.ok && Number(r.note.lineHeight) === 2, '行距字段保存/返回一致');
  const rich = r.note.content;
  assert(rich.indexOf('script') < 0, 'script 标签被清掉');
  assert(rich.indexOf('onclick') < 0, '事件属性被清掉');
  assert(rich.indexOf('javascript:') < 0, 'javascript: 链接被清掉');
  assert(rich.indexOf('position') < 0, '危险样式被清掉');
  assert(rich.indexOf('#305c38') >= 0, '安全的字色保留');
  await handle('tradeNoteDelete', { token, noteId: richId }, '');

  // ---------------------------------------------------------------- 空笔记
  r = await handle('tradeNoteSave', { token, title: '   ', content: '' }, '');
  assert(!r.ok && r.error === 'empty_note', '空笔记被拒绝');

  // ---------------------------------------------------------------- 图片配额
  db._seed('tradeNotes', 'seed_full', {
    ownerUserId: uid,
    title: '占位',
    content: '',
    images: [{ fileId: 'cloud://x/tradeNotes/' + uid + '/a.jpg', size: 300 * 1024 * 1024 }],
    imageBytes: 300 * 1024 * 1024,
    imageCount: 1,
    createdAt: 1,
    updatedAt: 1,
    deletedAt: 0,
  });
  r = await handle(
    'tradeNoteUpload',
    { token, data: JPEG.toString('base64') },
    ''
  );
  assert(!r.ok && r.error === 'storage_quota', '300MB 图片配额满后拒绝上传');

  // ---------------------------------------------------------------- 条数不设上限 + 分页
  for (let i = 0; i < 120; i += 1) {
    db._seed('tradeNotes', 'seed_' + i, {
      ownerUserId: uid,
      title: 't' + i,
      content: '',
      images: [],
      imageBytes: 0,
      imageCount: 0,
      createdAt: i,
      updatedAt: i,
      deletedAt: 0,
    });
  }
  r = await handle(
    'tradeNoteSave',
    { token, title: '第 123 条（不设上限）', content: 'x' },
    ''
  );
  assert(r.ok && r.noteId, '笔记条数不设上限：超过 300 条仍可新建');

  const total = 1 + 1 + 120 + 1; // 原笔记 + seed_full + 120 条种子 + 刚新建
  r = await handle('tradeNoteList', { token, pageSize: 50, offset: 0 }, '');
  assert(r.ok && r.notes.length === 50 && r.nextOffset === 50, '第一页 50 条，游标 50');
  assert(r.usage.count === total, 'usage.count 返回真实总数，不受分页影响');
  const page1 = r.notes.map((n) => n.noteId);
  r = await handle('tradeNoteList', { token, pageSize: 50, offset: 50 }, '');
  assert(r.ok && r.notes.length === 50 && r.nextOffset === 100, '第二页 50 条，游标 100');
  const page2 = r.notes.map((n) => n.noteId);
  r = await handle('tradeNoteList', { token, pageSize: 50, offset: 100 }, '');
  assert(r.ok && r.notes.length === total - 100 && r.nextOffset === null, '最后一页取完，游标置空');
  const all = page1.concat(page2).concat(r.notes.map((n) => n.noteId));
  assert(new Set(all).size === total, '三页拼起来不重不漏');

  // 清掉配额占位和分页种子，避免影响后面的删除测试
  for (const n of db._all('tradeNotes')) {
    if (n._id.indexOf('seed_') === 0) {
      await db.collection('tradeNotes').doc(n._id).remove();
    }
  }

  // ---------------------------------------------------------------- 分享 / 头像
  r = await handle('tradeNoteShare', { token, noteId }, '');
  assert(r.ok && r.shareId && r.url.indexOf('/note.html?s=') > 0, '生成分享链接');
  const shareId = r.shareId;
  r = await handle('tradeNotePublicGet', { shareId }, '');
  assert(r.ok && r.note.title === '11/4 复盘', '未登录可以打开分享页');
  assert(r.note.content.indexOf('src="https://cdn.test/') > 0, '分享页图片也换临时链接');

  r = await handle('tradeAvatarSet', { token, avatar: 'data:image/jpeg;base64,AAAA' }, '');
  assert(r.ok, '头像缩略图保存成功');
  r = await handle('tradeAvatarGet', { token }, '');
  assert(r.ok && r.avatar.indexOf('data:image/jpeg') === 0, '头像读取成功');
  r = await handle('tradeAvatarSet', { token, avatar: 'not-a-data-url' }, '');
  assert(!r.ok && r.error === 'bad_image', '非图片头像被拒绝');

  // ---------------------------------------------------------------- 回收站 / 彻底删除
  storage.deleted.length = 0;
  r = await handle('tradeNoteDelete', { token, noteId }, '');
  assert(r.ok && r.trashed, '删除笔记进入回收站');
  assert(storage.deleted.length === 0, '软删除不删云存储图片');
  r = await handle('tradeNoteGet', { token, noteId }, '');
  assert(!r.ok && r.error === 'not_found', '回收站里的笔记详情 404');
  r = await handle('tradeNoteList', { token }, '');
  assert(r.ok && r.notes.every((n) => n.noteId !== noteId), '删除后不在正常列表里');
  r = await handle('tradeNoteTrashList', { token }, '');
  assert(r.ok && r.notes.some((n) => n.noteId === noteId), '回收站列表能看到');
  r = await handle('tradeNotePublicGet', { shareId }, '');
  assert(!r.ok && r.error === 'not_found', '删除后分享链接失效');

  r = await handle('tradeNoteRestore', { token, noteId }, '');
  assert(r.ok && r.restored, '从回收站恢复');
  r = await handle('tradeNoteGet', { token, noteId }, '');
  assert(r.ok, '恢复后详情可读');
  r = await handle('tradeNotePublicGet', { shareId }, '');
  assert(r.ok, '恢复后分享链接又能打开');

  await handle('tradeNoteDelete', { token, noteId }, '');
  r = await handle('tradeNotePurge', { token, noteId }, '');
  assert(r.ok && r.purged, '彻底删除');
  assert(storage.deleted.indexOf(up2.fileId) >= 0, '彻底删除同步删图');
  r = await handle('tradeNoteGet', { token, noteId }, '');
  assert(!r.ok && r.error === 'not_found', '彻底删除后详情 404');
  r = await handle('tradeNotePublicGet', { shareId }, '');
  assert(!r.ok, '彻底删除后分享链接失效');

  console.log('');
  console.log(`  ${checks - failures}/${checks} 通过`);
  if (failures > 0) process.exit(1);
}

main().catch((e) => {
  console.error(e && e.stack ? e.stack : e);
  process.exit(1);
});
