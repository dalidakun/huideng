"""把《缠中说禅：教你炒股票》MOBI 抽成站点用的 JSON + 插图。

用法：
    python tools/extract_chan_mobi.py
    python tools/extract_chan_mobi.py --mobi "C:\\Users\\Administrator\\Desktop\\缠中说禅.mobi"
    python tools/extract_chan_mobi.py --no-images

产物：
    site/data/chan-lessons.json     108 课正文（段落 / 小标题 / 注释 / 插图）
    site/assets/chan/img/*.webp     插图，长边压到 860px

MOBI 结构（mobi7/book.html）：
    <mbp:pagebreak/><a id="filepos..."/><p>教你炒股票N / 副标题 / （日期）</p>
    <p>正文段落</p>
    <p><img src="Images/xxx.jpeg"/></p><p>图1-1 说明</p>
    之后是编者的「缠论点睛 / 投资微言 / 注释」：整段丢弃，不进站点

依赖：pip install mobi beautifulsoup4 lxml pillow
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import pathlib
import re
import shutil

import mobi
from bs4 import BeautifulSoup, Tag
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
DATA = SITE / "data" / "chan-lessons.json"
IMG_DIR = SITE / "assets" / "chan" / "img"
DEFAULT_MOBI = r"C:\Users\Administrator\Desktop\缠中说禅.mobi"

IMG_MAX_W = 860
IMG_QUALITY = 82

CHAP_RE = re.compile(r"^教你炒股票\s*(\d+)\s*[\s\u3000]*(.*)$")
DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})")
DATE_IN_TEXT_RE = re.compile(r"时间[：:]\s*(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})")
FOOTNOTE_RE = re.compile(r"^\[\d+\]")
FOOTNOTE_MARK_RE = re.compile(r"\s*\[\d+\]\s*$")


def clean(text: str) -> str:
    text = text.replace("\u00a0", " ").replace("\u3000", " ")
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    return text.strip()


def text_without_sup(node) -> str:
    """取文字时去掉上标脚注标记（页面里没有脚注跳转，留着只剩 [1]）。"""
    clone = BeautifulSoup(str(node), "lxml")
    for sup in clone.find_all("sup"):
        sup.decompose()
    # 空分隔符：紧贴标点的脚注标记去掉后不留下多余空格
    for br in clone.find_all("br"):
        br.replace_with(" ")
    return clean(clone.get_text(""))


class Images:
    """把引用到的 MOBI 图片压成 WebP；同一张图只存一份。"""

    def __init__(self, book_dir: pathlib.Path, enabled: bool = True) -> None:
        self.book_dir = book_dir
        self.enabled = enabled
        self.by_src: dict[str, dict | None] = {}
        self.total = 0
        IMG_DIR.mkdir(parents=True, exist_ok=True)

    def add(self, src: str) -> dict | None:
        if not self.enabled or not src:
            return None
        if src in self.by_src:
            return self.by_src[src]

        path = self.book_dir / src
        if not path.is_file():
            print(f"警告      缺图 {src}")
            self.by_src[src] = None
            return None

        blob = path.read_bytes()
        digest = hashlib.md5(blob).hexdigest()[:12]
        name = f"{digest}.webp"
        out = IMG_DIR / name

        if out.exists():
            try:
                with Image.open(out) as im:
                    w, h = im.size
            except OSError:
                w, h = 0, 0
        else:
            try:
                im = Image.open(io.BytesIO(blob))
            except OSError:
                self.by_src[src] = None
                return None
            # 字体缺字留下的小位图不当插图
            if im.size[0] <= 64 and im.size[1] <= 64:
                self.by_src[src] = None
                return None
            im = im.convert("RGB")
            w, h = im.size
            if w > IMG_MAX_W:
                im = im.resize((IMG_MAX_W, round(h * IMG_MAX_W / w)), Image.LANCZOS)
            buf = io.BytesIO()
            im.save(buf, "WEBP", quality=IMG_QUALITY, method=6)
            data = buf.getvalue()
            out.write_bytes(data)
            self.total += len(data)

        meta = {"src": f"assets/chan/img/{name}", "w": w, "h": h}
        self.by_src[src] = meta
        return meta


def parse_title(p) -> tuple[str, str, str]:
    """从标题段落里取「教你炒股票N」、副标题、日期。"""
    clone = BeautifulSoup(str(p), "lxml")
    for sup in clone.find_all("sup"):
        sup.decompose()
    label = ""
    short = ""
    for font in clone.find_all("font"):
        size = str(font.get("size") or "")
        text = clean(font.get_text(" ", strip=True))
        if size == "6" and not label:
            label = text
        elif size == "7" and not short:
            short = text
    raw = clean(clone.get_text(" ", strip=True))
    m = DATE_RE.search(raw)
    date = f"{m.group(1)} {m.group(2)}" if m else ""
    if not label:
        m2 = CHAP_RE.match(raw)
        if m2:
            label = f"教你炒股票{m2.group(1)}"
            short = short or clean(m2.group(2))
    short = FOOTNOTE_MARK_RE.sub("", short).strip()
    return label, short, date


def extract_chapters(html_path: pathlib.Path, images: Images) -> list[dict]:
    soup = BeautifulSoup(html_path.read_text(encoding="utf-8"), "lxml")

    # 目录里同一课会重复出现，按 href 去重，并只认 1–108
    links: dict[str, int] = {}
    for a in soup.find_all("a", href=True):
        m = CHAP_RE.match(a.get_text(" ", strip=True))
        if not m:
            continue
        no = int(m.group(1))
        href = a["href"]
        if href not in links and 1 <= no <= 108:
            links[href] = no

    if len(links) != 108:
        raise SystemExit(f"MOBI 里识别到 {len(links)} 课，预期 108 课")

    chapter_ids = {href.lstrip("#") for href in links}

    chapters: list[dict] = []
    for href, expected_no in links.items():
        anchor = soup.find(id=href.lstrip("#"))
        if anchor is None:
            raise SystemExit(f"找不到第 {expected_no} 课的锚点 {href}")

        nodes = []
        el = anchor.next_sibling
        while el is not None:
            if isinstance(el, Tag) and el.name == "a" and el.get("id") in chapter_ids:
                break
            nodes.append(el)
            el = el.next_sibling

        label = ""
        short = ""
        date = ""
        blocks: list[dict] = []
        pending_img: dict | None = None

        for node in nodes:
            if not isinstance(node, Tag):
                continue
            name = node.name

            if name == "p":
                imgs = node.find_all("img")
                if imgs:
                    for im in imgs:
                        meta = images.add(im.get("src", ""))
                        if meta:
                            block = {"t": "img", **meta}
                            blocks.append(block)
                            pending_img = block
                    continue

                text = text_without_sup(node)
                if not text:
                    continue

                if not label and node.find("font", {"size": "6"}):
                    label, short, date = parse_title(node)
                    continue

                # 每篇后面的「缠论点睛 / 投资微言 / 注释」是编者附文，不要
                if text in ("缠论点睛", "投资微言", "注释"):
                    break

                # 其它书内小标题（如果有）照常保留
                if node.find("font", {"size": "4"}):
                    blocks.append({"t": "h", "x": text})
                    pending_img = None
                    continue

                if pending_img is not None and text.startswith("图"):
                    pending_img["cap"] = text
                    pending_img = None
                    continue

                blocks.append({"t": "p", "x": text})
                pending_img = None

            elif name == "blockquote":
                # 脚注区也不要；正文里的引用仍按段落保留
                text = text_without_sup(node)
                if not text or FOOTNOTE_RE.match(text):
                    continue
                blocks.append({"t": "p", "x": text})

        if not date:
            for block in blocks:
                if block["t"] != "p":
                    continue
                m = DATE_IN_TEXT_RE.search(block["x"])
                if m:
                    date = f"{m.group(1)} {m.group(2)}"
                    break

        no = int(CHAP_RE.match(label).group(1)) if CHAP_RE.match(label) else expected_no
        if no != expected_no:
            raise SystemExit(f"章节顺序对不上：锚点是第 {expected_no} 课，标题却是 {label}")

        if not label or not short:
            raise SystemExit(f"第 {no} 课缺少标题（{label!r} / {short!r}）")

        chars = sum(len(b.get("x", "")) for b in blocks if b["t"] in ("p", "h", "note"))
        chapters.append(
            {
                "no": no,
                "title": f"教你炒股票 {no}：{short}",
                "date": date,
                "blocks": blocks,
                "short": short,
                "chars": chars,
            }
        )

    chapters.sort(key=lambda c: c["no"])
    if [c["no"] for c in chapters] != list(range(1, 109)):
        raise SystemExit("抽取后的课号不是完整的 1–108")
    return chapters


def main() -> int:
    ap = argparse.ArgumentParser(description="从 MOBI 抽取缠论读书会 108 课")
    ap.add_argument("--mobi", default=DEFAULT_MOBI, help="MOBI 文件路径")
    ap.add_argument("--no-images", action="store_true", help="只抽文字，不处理插图")
    args = ap.parse_args()

    src = pathlib.Path(args.mobi)
    if not src.is_file():
        raise SystemExit(f"找不到 MOBI：{src}")

    print(f"读取      {src}")
    tempdir, book = mobi.extract(str(src))
    try:
        book_path = pathlib.Path(book)
        book_dir = book_path.parent
        print(f"解包      {book_path.relative_to(pathlib.Path(tempdir))}")
        images = Images(book_dir, enabled=not args.no_images)
        chapters = extract_chapters(book_path, images)

        DATA.parent.mkdir(parents=True, exist_ok=True)
        DATA.write_text(
            json.dumps(chapters, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )

        figs = sum(1 for c in chapters for b in c["blocks"] if b["t"] == "img")
        chars = sum(c["chars"] for c in chapters)
        print(f"课程      {len(chapters)} 课")
        print(f"正文      {chars:,} 字")
        print(f"插图      {figs} 处 / {len([m for m in images.by_src.values() if m])} 张")
        print(f"输出      {DATA.relative_to(ROOT)}")
        if not args.no_images:
            print(f"图片      {IMG_DIR.relative_to(ROOT)}/  {images.total / 1024:.0f} KB（本次新增）")
        return 0
    finally:
        shutil.rmtree(tempdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
