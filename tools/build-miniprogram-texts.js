/**
 * 生成微信小程序首版内置书目与正文模块。
 *
 * 用法：node tools/build-miniprogram-texts.js
 * 数据源：assets/sutras_ascii/<卷>/<ID>.txt（与 App 同一份大正藏文本）
 *
 * 说明：首版只内置少量短经，控制在 200KB 以内，方便过审与快速启动；
 * 后续全量经书改走云存储按需下载（见 miniprogram/README.md）。
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SRC = path.join(ROOT, 'assets', 'sutras_ascii');
const OUT = path.join(ROOT, 'miniprogram', 'data');

const BOOKS = [
  {
    id: 'T08n0251_001',
    title: '般若波罗蜜多心经',
    volume: '大正藏 T08',
    dynasty: '姚秦',
    translator: '鸠摩罗什 译',
    tag: '般若',
    intro: '般若类经典，全文篇幅精炼，流传广泛。',
  },
  {
    id: 'T08n0235_001',
    title: '金刚般若波罗蜜经',
    volume: '大正藏 T08',
    dynasty: '姚秦',
    translator: '鸠摩罗什 译',
    tag: '般若',
    intro: '般若部重要经典，以对话形式展开。',
  },
  {
    id: 'T12n0366_001',
    title: '佛说阿弥陀经',
    volume: '大正藏 T12',
    dynasty: '姚秦',
    translator: '鸠摩罗什 译',
    tag: '净土',
    intro: '净土部经典，鸠摩罗什译本流通最广。',
  },
  {
    id: 'T15n0600_001',
    title: '十善业道经',
    volume: '大正藏 T15',
    dynasty: '唐',
    translator: '实叉难陀 译',
    tag: '经集',
    intro: '唐代实叉难陀译本，说十善业道。',
  },
  {
    id: 'T17n0779_001',
    title: '佛说八大人觉经',
    volume: '大正藏 T17',
    dynasty: '后汉',
    translator: '安世高 译',
    tag: '经集',
    intro: '后汉安世高译，篇幅短小。',
  },
  {
    id: 'T17n0784_001',
    title: '四十二章经',
    volume: '大正藏 T17',
    dynasty: '后汉',
    translator: '迦叶摩腾、竺法兰 译',
    tag: '经集',
    intro: '现存最早的汉译佛经之一。',
  },
  {
    id: 'T48n2008_001',
    title: '六祖大师法宝坛经',
    volume: '大正藏 T48',
    dynasty: '唐',
    translator: '法海 集记',
    tag: '禅宗',
    intro: '禅宗六祖惠能语录，由门人集录。',
  },
  {
    id: 'T14n0475_001',
    title: '维摩诘所说经（卷上）',
    volume: '大正藏 T14',
    dynasty: '姚秦',
    translator: '鸠摩罗什 译',
    tag: '大乘',
    intro: '大乘经典，鸠摩罗什译，此为上卷。',
  },
];

function readText(id) {
  const vol = id.slice(0, 3);
  const file = path.join(SRC, vol, `${id}.txt`);
  if (!fs.existsSync(file)) throw new Error(`缺少正文文件：${file}`);
  return fs
    .readFileSync(file, 'utf8')
    .replace(/^\uFEFF/, '')
    .replace(/\r\n/g, '\n')
    .trim();
}

function toJsString(text) {
  return JSON.stringify(text)
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
}

fs.mkdirSync(path.join(OUT, 'texts'), { recursive: true });

const manifest = [];
for (const book of BOOKS) {
  const text = readText(book.id);
  const body = `// 自动生成：${book.title}（${book.id}）\nmodule.exports = ${toJsString(text)};\n`;
  fs.writeFileSync(path.join(OUT, 'texts', `${book.id}.js`), body, 'utf8');
  manifest.push({
    ...book,
    chars: text.replace(/\s/g, '').length,
    module: `./${book.id}.js`,
  });
}

const index =
  '// 自动生成：正文模块索引（按需 require，避免首屏解析全部文本）\nmodule.exports = {\n' +
  manifest.map((b) => `  '${b.id}': () => require('${b.module}'),`).join('\n') +
  '\n};\n';
fs.writeFileSync(path.join(OUT, 'texts', 'index.js'), index, 'utf8');

const booksJs =
  '// 自动生成：首版内置书目。字段：id/title/volume/dynasty/translator/tag/intro/chars\n' +
  `module.exports = ${JSON.stringify(manifest, null, 2)};\n`;
fs.writeFileSync(path.join(OUT, 'books.js'), booksJs, 'utf8');

const totalChars = manifest.reduce((n, b) => n + b.chars, 0);
console.log(`已生成 ${manifest.length} 部，共 ${totalChars} 字`);
for (const b of manifest) {
  const size = fs.statSync(path.join(OUT, 'texts', `${b.id}.js`)).size;
  console.log(`  ${b.id}  ${b.title}  ${b.chars} 字  ${(size / 1024).toFixed(1)} KB`);
}
