/**
 * 小程序静态检查：页面文件齐全、JSON 合法、WXML 标签配对、正文可解析。
 * 用法：node tools/check-miniprogram.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', 'miniprogram');
let errors = 0;

function fail(msg) {
  errors++;
  console.log('  ✗ ' + msg);
}

function walk(dir, out = []) {
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const stat = fs.statSync(full);
    if (stat.isDirectory()) walk(full, out);
    else out.push(full);
  }
  return out;
}

const files = walk(ROOT);
const rel = (f) => path.relative(ROOT, f).replace(/\\/g, '/');

// 1) JSON
console.log('[1] JSON');
for (const f of files.filter((x) => x.endsWith('.json'))) {
  try {
    JSON.parse(fs.readFileSync(f, 'utf8'));
  } catch (e) {
    fail(rel(f) + ' → ' + e.message);
  }
}
if (!errors) console.log('  ✓ ' + files.filter((x) => x.endsWith('.json')).length + ' 个 JSON 合法');

// 2) 页面文件
console.log('[2] pages');
const app = JSON.parse(fs.readFileSync(path.join(ROOT, 'app.json'), 'utf8'));
for (const page of app.pages) {
  for (const ext of ['.js', '.json', '.wxml', '.wxss']) {
    if (!fs.existsSync(path.join(ROOT, page + ext))) fail('缺少 ' + page + ext);
  }
}
if (!errors) console.log('  ✓ ' + app.pages.length + ' 个页面文件齐全');

// 3) WXML 标签配对
console.log('[3] WXML');
const VOID = new Set(['input', 'image', 'icon', 'progress', 'slider', 'switch', 'textarea']);
for (const f of files.filter((x) => x.endsWith('.wxml'))) {
  const src = fs.readFileSync(f, 'utf8').replace(/<!--[\s\S]*?-->/g, '');
  const stack = [];
  const tagRe = /<\/?([a-zA-Z][\w-]*)([^>]*?)(\/?)>/g;
  let m;
  while ((m = tagRe.exec(src))) {
    const raw = m[0];
    const name = m[1];
    const selfClose = m[3] === '/' || raw.endsWith('/>');
    if (raw.startsWith('</')) {
      const top = stack.pop();
      if (top !== name) {
        fail(rel(f) + ' → 闭合标签 </' + name + '> 与 <' + (top || '?') + '> 不匹配');
        break;
      }
    } else if (!selfClose) {
      stack.push(name);
    }
  }
  if (stack.length) fail(rel(f) + ' → 未闭合：' + stack.join(', '));
}
if (!errors) console.log('  ✓ WXML 标签配对正常');

// 4) 正文解析
console.log('[4] 正文');
const library = require(path.join(ROOT, 'services', 'library.js'));
const { parseParagraphs } = require(path.join(ROOT, 'utils', 'paragraphs.js'));

function checkMarkers() {
  const cases = [
    ['普通一段', '普通一段', ''],
    ['带隐藏记号。。。', '带隐藏记号', 'quiet'],
    ['带紧排。。。///', '带紧排', 'tight'],
    ['加粗BBB', '加粗', 'bold'],
    ['。。。///加粗bbb', '加粗', 'bold'],
  ];
  for (const [input, expected, cls] of cases) {
    const out = parseParagraphs(input);
    const got = out[0] ? out[0].t : '';
    const gotCls = out[0] ? out[0].cls : '';
    if (got !== expected) fail(`标记解析「${input}」→「${got}」，期望「${expected}」`);
    if (cls && gotCls.indexOf(cls) < 0) fail(`标记解析「${input}」class=${gotCls}，期望含 ${cls}`);
  }
  const note = parseParagraphs('@@\n备注块第一行\n第二行\n@@');
  if (!note.length || note[0].cls !== 'note-block') fail('备注块解析失败');
}
checkMarkers();

let total = 0;
for (const book of library.list()) {
  const text = library.getText(book.id);
  if (!text) {
    fail(book.id + ' 正文为空');
    continue;
  }
  const paras = parseParagraphs(text);
  if (!paras.length) fail(book.id + ' 分段为空');
  const hasMarker = paras.some((p) => /。。。|\/\/\/|@@|BBB/.test(p.t));
  if (hasMarker) fail(book.id + ' 仍有未剥离的编辑记号');
  total += text.length;
  console.log(
    `  · ${book.id}  ${book.title}  ${paras.length} 段  ${(text.length / 1024).toFixed(1)} KB`
  );
}
console.log(`  ✓ ${library.list().length} 部，共 ${total} 字符`);

// 5) 包体积
console.log('[5] 体积');
const size = files.reduce((n, f) => n + fs.statSync(f).size, 0);
console.log(`  当前 ${(size / 1024).toFixed(1)} KB（主包上限 2MB）`);
if (size > 1.8 * 1024 * 1024) fail('包体积接近 2MB 上限');

console.log(errors ? `\n检查失败：${errors} 处` : '\n检查通过');
process.exit(errors ? 1 : 0);
