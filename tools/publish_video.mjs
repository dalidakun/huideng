#!/usr/bin/env node
// 把 master 目录里的一个视频发布到 Cloudflare R2，并更新云端 catalog.json。
//
// 用法（在仓库根目录）：
//   node tools/publish_video.mjs --id v002 --title "金刚经" --master "E:\9-huideng-video\master\v002.mp4"
//
// 流程：转码 720P（H.264/AAC）→ 截封面 → 切 HLS（6 秒一片）→ 上传 R2 →
// 合并并上传 catalog.json。已经生成过的中间文件会跳过，可以反复执行。
//
// 环境要求：ffmpeg / ffprobe 在 PATH 里；本机用 wrangler 登录过 Cloudflare
// （token 从 wrangler 配置里读，避免再单独存一份密钥）。

import { spawnSync } from 'node:child_process';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { existsSync, statSync } from 'node:fs';
import path from 'node:path';

const args = parseArgs(process.argv.slice(2));
const ROOT = path.resolve(args.root ?? 'E:\\9-huideng-video');
const MASTER = args.master ? path.resolve(args.master) : '';
const ID = (args.id ?? '').trim();
const TITLE = (args.title ?? '').trim();
const SUBTITLE = (args.subtitle ?? '').trim();
const DESCRIPTION = (args.desc ?? '').trim();
const POSTER_AT = Number(args.at ?? 300);

const ACCOUNT = args.account ?? process.env.R2_ACCOUNT_ID ?? '6140e5e3e14967610fe12d221304b125';
const BUCKET = args.bucket ?? process.env.R2_BUCKET ?? 'huideng-media';
const PUBLIC_BASE = (args['public-base'] ?? 'https://pub-5b5f4d4b26d4455796c20a6f89388785.r2.dev').replace(/\/$/, '');
const WRANGLER_CONFIG =
  args['wrangler-config'] ??
  path.join(process.env.APPDATA ?? '', 'xdg.config', '.wrangler', 'config', 'default.toml');

if (!MASTER || !ID || !TITLE) {
  console.error('缺少参数：--id v002 --title "经名" --master "E:\\9-huideng-video\\master\\v002.mp4"');
  process.exit(1);
}
if (!existsSync(MASTER)) {
  console.error(`master 文件不存在：${MASTER}`);
  process.exit(1);
}

const DIST = path.join(ROOT, 'dist');
const POSTERS = path.join(ROOT, 'posters');
const HLS_DIR = path.join(DIST, 'hls', ID);
const MP4 = path.join(DIST, `${ID}-720p.mp4`);

await mkdir(DIST, { recursive: true });
await mkdir(POSTERS, { recursive: true });
await mkdir(HLS_DIR, { recursive: true });

const probe = ffprobe(MASTER);
const durationSec = Math.round(probe.duration || 0);
const sourceHeight = probe.height || 0;
console.log(`源文件：${path.basename(MASTER)}  ${fmt(durationSec)}  ${probe.width}x${probe.height}  ${probe.codec}`);

// 1) 720P H.264/AAC（浏览器、安卓、iOS 都能硬解）
if (!existsSync(MP4) || statSyncMtime(MP4) < statSyncMtime(MASTER)) {
  console.log('转码 720P …（几分钟，可中断后重跑）');
  run('ffmpeg', [
    '-hide_banner', '-y', '-i', MASTER,
    '-c:v', 'libx264', '-preset', 'medium', '-crf', '25', '-tune', 'animation',
    '-maxrate', '1300k', '-bufsize', '2600k', '-profile:v', 'high', '-level', '4.0',
    '-pix_fmt', 'yuv420p', '-g', '50', '-keyint_min', '50', '-sc_threshold', '0',
    '-c:a', 'aac', '-b:a', '128k', '-ac', '2', '-movflags', '+faststart', MP4,
  ]);
} else {
  console.log('已存在转码文件，跳过转码');
}

// 2) 封面
const poster = path.join(POSTERS, `${ID}.jpg`);
if (!existsSync(poster) || statSyncMtime(poster) < statSyncMtime(MASTER)) {
  const posterAt = Math.max(1, Math.min(POSTER_AT, durationSec - 2));
  console.log(`截封面（第 ${posterAt}s）…`);
  run('ffmpeg', ['-hide_banner', '-y', '-ss', String(posterAt), '-i', MASTER,
    '-frames:v', '1', '-q:v', '2', poster]);
}

// 3) HLS 切片（每片 1MB 左右，绕开 wrangler 300MiB 单文件限制）
const playlist = path.join(HLS_DIR, 'index.m3u8');
if (!existsSync(playlist) || statSyncMtime(playlist) < statSyncMtime(MP4)) {
  console.log('切 HLS …');
  run('ffmpeg', ['-hide_banner', '-y', '-i', MP4, '-c', 'copy', '-f', 'hls',
    '-hls_time', '6', '-hls_list_size', '0', '-hls_playlist_type', 'vod',
    '-hls_segment_filename', path.join(HLS_DIR, 'seg_%04d.ts'), playlist]);
}

// 4) 上传
const token = await wranglerToken();
console.log('上传 R2 …');
await uploadFile(token, `posters/${ID}.jpg`, poster, 'image/jpeg',
  'public, max-age=31536000, immutable');
const hlsFiles = (await readdir(HLS_DIR))
  .filter((f) => f.endsWith('.ts') || f.endsWith('.m3u8'))
  .sort();
await uploadMany(token, HLS_DIR, hlsFiles, `videos/${ID}`);

// 5) 合并 catalog.json（保留云端已有条目，按 id 覆盖）
const catalog = await loadRemoteCatalog();
const entry = {
  id: ID,
  title: TITLE,
  subtitle: SUBTITLE || '讲经影音',
  description: DESCRIPTION,
  durationSec,
  cover: `posters/${ID}.jpg`,
  sources: [
    {
      label: '720P',
      path: `videos/${ID}/index.m3u8`,
      height: 720,
      bitrate: 1250000,
    },
  ],
};
catalog.updatedAt = new Date().toISOString().slice(0, 10);
catalog.version = 1;
catalog.videos = [entry, ...(catalog.videos ?? []).filter((v) => v.id !== ID)];

const catalogText = JSON.stringify(catalog, null, 2) + '\n';
await writeFile(path.join(DIST, 'catalog.json'), catalogText, 'utf8');
await uploadFile(token, 'catalog.json', path.join(DIST, 'catalog.json'),
  'application/json; charset=utf-8', 'public, max-age=60');

console.log('\n发布完成：');
console.log(`  页面封面  ${PUBLIC_BASE}/posters/${ID}.jpg`);
console.log(`  HLS 播放  ${PUBLIC_BASE}/videos/${ID}/index.m3u8`);
console.log(`  清单      ${PUBLIC_BASE}/catalog.json`);
console.log(`  共 ${catalog.videos.length} 部视频`);
console.log('（dist 里的中间 MP4 会保留，方便以后二次处理；不需要可手动删除）');

// ───────────────────────── 工具函数 ─────────────────────────

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      out[key] = next;
      i++;
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

function run(cmd, argsList) {
  const r = spawnSync(cmd, argsList, { stdio: 'inherit', windowsHide: true });
  if (r.status !== 0) {
    console.error(`${cmd} 失败（exit ${r.status}）`);
    process.exit(r.status ?? 1);
  }
}

function ffprobe(file) {
  const r = spawnSync('ffprobe', ['-v', 'error', '-print_format', 'json',
    '-show_format', '-show_streams', file], { encoding: 'utf8' });
  if (r.status !== 0) {
    console.error(`ffprobe 读取失败：${file}`);
    process.exit(1);
  }
  const info = JSON.parse(r.stdout);
  const video = (info.streams ?? []).find((s) => s.codec_type === 'video') ?? {};
  return {
    duration: Number(info.format?.duration ?? 0),
    width: video.width,
    height: video.height,
    codec: video.codec_name,
  };
}

function statSyncMtime(p) {
  try {
    return statSync(p).mtimeMs;
  } catch {
    return 0;
  }
}

async function wranglerToken() {
  if (!existsSync(WRANGLER_CONFIG)) {
    console.error(`找不到 wrangler 配置：${WRANGLER_CONFIG}\n先运行一次 wrangler login。`);
    process.exit(1);
  }
  const text = await readFile(WRANGLER_CONFIG, 'utf8');
  const token = /oauth_token\s*=\s*"([^"]+)"/.exec(text)?.[1];
  if (!token) {
    console.error('wrangler 配置里没有 oauth_token，重新登录一次。');
    process.exit(1);
  }
  return token;
}

const apiBase = `https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/r2/buckets/${BUCKET}/objects`;

async function uploadFile(token, key, file, contentType, cacheControl) {
  const body = await readFile(file);
  await uploadBuffer(token, key, body, contentType, cacheControl);
}

async function uploadBuffer(token, key, body, contentType, cacheControl) {
  const url = `${apiBase}/${key.split('/').map(encodeURIComponent).join('/')}`;
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const res = await fetch(url, {
        method: 'PUT',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': contentType,
          'Cache-Control': cacheControl,
        },
        body,
        signal: AbortSignal.timeout(120000),
      });
      if (res.ok) return;
      if (res.status === 429 || res.status >= 500) {
        await sleep(1000 * (attempt + 1));
        continue;
      }
      throw new Error(`${res.status} ${(await res.text()).slice(0, 160)}`);
    } catch (e) {
      if (attempt === 4) throw e;
      await sleep(1000 * (attempt + 1));
    }
  }
}

async function uploadMany(token, dir, names, prefix) {
  const queue = [...names];
  let done = 0;
  const workers = Array.from({ length: 3 }, async () => {
    for (;;) {
      const name = queue.shift();
      if (!name) return;
      const body = await readFile(path.join(dir, name));
      const type = name.endsWith('.m3u8') ? 'application/vnd.apple.mpegurl' : 'video/mp2t';
      const cc = name.endsWith('.m3u8')
        ? 'public, max-age=60'
        : 'public, max-age=31536000, immutable';
      await uploadBuffer(token, `${prefix}/${name}`, body, type, cc);
      done++;
      if (done % 20 === 0) console.log(`  已上传 ${done}/${names.length}`);
    }
  });
  await Promise.all(workers);
}

async function loadRemoteCatalog() {
  try {
    const res = await fetch(`${PUBLIC_BASE}/catalog.json`, { signal: AbortSignal.timeout(15000) });
    if (res.ok) return await res.json();
  } catch {}
  const local = path.join(DIST, 'catalog.json');
  if (existsSync(local)) {
    try {
      return JSON.parse(await readFile(local, 'utf8'));
    } catch {}
  }
  return { version: 1, videos: [] };
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function fmt(sec) {
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}
