#!/usr/bin/env node
// 把一个 MP4 按字节切成 <100MB 的分片（光鸭等网盘“免登录下载”只限小文件），
// App 端按顺序拼回完整文件后播放。
//
// 用法：
//   node tools/split_video_parts.mjs --file "E:\9-huideng-video\dist\v001-720p.mp4" --id v001
//
// 输出：
//   E:\9-huideng-video\parts\v001\part-001.mp4 …  （每片默认 90MB）
//   终端打印每片大小，以及可直接粘进 catalog.json 的 parts 片段。

import { open, mkdir, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

const args = parseArgs(process.argv.slice(2));
const file = args.file ? path.resolve(args.file) : '';
const id = (args.id ?? '').trim() || 'video';
const maxBytes = Math.floor(Number(args.size ?? 90) * 1024 * 1024);
const root = path.resolve(args.root ?? 'E:\\9-huideng-video');
const outDir = path.join(root, 'parts', id);

if (!file) {
  console.error('用法：node tools/split_video_parts.mjs --file <mp4> --id v001 [--size 90]');
  process.exit(1);
}

const info = await stat(file);
const total = info.size;
const parts = Math.ceil(total / maxBytes);
await mkdir(outDir, { recursive: true });

const src = await open(file, 'r');
const out = [];
let offset = 0;
let index = 1;
const buf = Buffer.allocUnsafe(4 * 1024 * 1024);
while (offset < total) {
  const name = `part-${String(index).padStart(3, '0')}.mp4`;
  const target = path.join(outDir, name);
  const size = Math.min(maxBytes, total - offset);
  const dst = await open(target, 'w');
  let written = 0;
  while (written < size) {
    const want = Math.min(buf.length, size - written);
    const { bytesRead } = await src.read(buf, 0, want, offset + written);
    if (bytesRead === 0) break;
    await dst.write(buf, 0, bytesRead);
    written += bytesRead;
  }
  await dst.close();
  out.push({ name, size: written, file: target });
  offset += written;
  index++;
}
await src.close();

const manifest = {
  id,
  source: path.basename(file),
  totalBytes: total,
  partCount: out.length,
  parts: out.map((p) => ({ name: p.name, size: p.size })),
};
const manifestPath = path.join(outDir, 'manifest.json');
await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + '\n', 'utf8');

console.log(`源文件：${path.basename(file)}  ${(total / 1024 / 1024).toFixed(1)} MB`);
console.log(`切成 ${out.length} 片（每片 ≤ ${(maxBytes / 1024 / 1024).toFixed(0)} MB）→ ${outDir}`);
for (const p of out) {
  console.log(`  ${p.name}  ${(p.size / 1024 / 1024).toFixed(1)} MB`);
}
console.log('\n上传到光鸭/网盘后，把每片的直链填进 catalog.json，例如：\n');
console.log(JSON.stringify({
  id,
  parts: out.map((p) => ({
    url: `https://光鸭直链/${id}/${p.name}`,
    size: p.size,
  })),
}, null, 2));

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
