"""把《教你炒股票 108 课》Word 文档抽成站点用的 JSON + 插图。

用法：
    python tools/extract_chan.py                 # 默认读 E:\\教你炒股票系列.docx
    python tools/extract_chan.py --docx D:\\x.docx

产物：
    site/data/chan-lessons.json     108 课正文（段落 / 日期行 / 插图按原文顺序）
    site/assets/chan/img/*.webp     插图，长边降到 860px，页面里按需懒加载

页面本身由 tools/build_site.py 读 JSON 渲染成 dist/chan/index.html，
所以这个脚本只在原文有更新时才需要重跑。

源文档结构（Word 样式 id）：
    "2"  -> Heading 1，一课的开头（108 个）
    "3"  -> Body Text，正文段落
    None -> Normal，课程日期行 / 课内附带的其它博文
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import pathlib
import re

from docx import Document
from docx.oxml.ns import qn
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
DATA = SITE / "data" / "chan-lessons.json"
IMG_DIR = SITE / "assets" / "chan" / "img"
DEFAULT_DOCX = r"E:\教你炒股票系列.docx"

DATE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})\s*(\d{2}:\d{2}:\d{2})$")
# Word 给「没字形的字符」塞的占位符（U+F8FF），后面按 PDF 对照补回真字。
PRIVATE_USE = "\uf8ff"
HEADING_STYLE_IDS = {"2", "1", "Heading1"}

IMG_MAX_W = 860
IMG_QUALITY = 82


def clean(text: str) -> str:
    text = text.replace("\u00a0", " ").replace("\u3000", " ")
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    return text.strip()


class Images:
    """把 docx 里的图片压成 WebP，同名图片只存一份。"""

    def __init__(self) -> None:
        IMG_DIR.mkdir(parents=True, exist_ok=True)
        self.by_hash: dict[str, dict] = {}
        self.budget = 0

    def add(self, rid: str, doc_part) -> dict:
        blob = doc_part.related_parts[rid].blob
        digest = hashlib.md5(blob).hexdigest()[:12]
        if digest in self.by_hash:
            return self.by_hash[digest]

        im = Image.open(io.BytesIO(blob))
        # 源文档里「早」「中」这类字没进字体子集，Word 把它们当成小图片塞进来
        # （38x39 的位图字形）。这种图不当插图用，交给 PDF 对照还原成文字。
        if im.size[0] <= 64 and im.size[1] <= 64:
            meta = {"glyph": True}
            self.by_hash[digest] = meta
            return meta

        im = im.convert("RGB")
        w, h = im.size
        if w > IMG_MAX_W:
            im = im.resize((IMG_MAX_W, round(h * IMG_MAX_W / w)), Image.LANCZOS)
        out = io.BytesIO()
        im.save(out, "WEBP", quality=IMG_QUALITY, method=6)
        data = out.getvalue()
        name = f"{digest}.webp"
        (IMG_DIR / name).write_bytes(data)
        meta = {
            "src": f"assets/chan/img/{name}",
            "w": im.size[0],
            "h": im.size[1],
        }
        self.by_hash[digest] = meta
        self.budget += len(data)
        return meta


def para_style(child) -> str:
    ppr = child.find(qn("w:pPr"))
    if ppr is None:
        return ""
    ps = ppr.find(qn("w:pStyle"))
    return ps.get(qn("w:val")) if ps is not None else ""


def paragraph_pieces(child, images: Images, doc_part) -> list[tuple[str, object]]:
    """按 run 顺序收集文字 / 图片，保持图文相对位置。"""
    pieces: list[tuple[str, object]] = []
    buf: list[str] = []
    for run in child.iterchildren(qn("w:r")):
        text = "".join(t.text or "" for t in run.iter(qn("w:t")))
        if text:
            buf.append(text)
        for blip in run.iter(qn("a:blip")):
            rid = blip.get(qn("r:embed"))
            if not rid:
                continue
            if buf:
                pieces.append(("text", "".join(buf)))
                buf = []
            pieces.append(("img", images.add(rid, doc_part)))
    if buf:
        pieces.append(("text", "".join(buf)))
    return pieces


# 原文里有些段落是从行末硬折出来的（"……都在 10" + "几元抛的"），
# 上一段没收在句末标点、下一段又不是小标题，就接回去。
SENTENCE_END = re.compile(r"[。！？；：…”’』」）】》]$")
SUBHEAD = re.compile(
    r"^(附录|[一二三四五六七八九十]+[、.．]|\d+[、.．]|（[一二三四五六七八九十]+）|第[一二三四五六七八九十百]+[课节章])"
)


def recover_glyphs(blocks: list[dict], pdf: str | None) -> tuple[list[dict], list[str]]:
    """把「以图片形式塞进来的字」还原成文字。

    Word 里「早」「中」这类字没进字体子集，导出后就变成一张 38x39 的位图字形。
    同一份文字的 PDF 版还在，拿上下文去 PDF 里对：前后各取 12 个字，中间夹的
    那一两个字就是丢掉的字符；对不上就丢掉占位图（宁可少一字，不要多一图）。
    """
    out: list[dict] = []
    missed: list[str] = []

    for i, block in enumerate(blocks):
        if block["t"] not in {"glyph", "blank"}:
            out.append(block)
            continue

        prev = next((b for b in reversed(out) if b["t"] == "p"), None)
        nxt = next((b for b in blocks[i + 1 :] if b["t"] == "p"), None)
        if prev is None or nxt is None:
            continue

        before = re.sub(r"\s+", "", prev["x"])[-12:]
        after = re.sub(r"\s+", "", nxt["x"])[:12]
        gap = None

        if pdf:
            hits = re.findall(re.escape(before) + r"(.{1,3}?)" + re.escape(after), pdf)
            chars = {h for h in hits if h.strip() and not re.search(r"\s", h)}
            if len(chars) == 1:
                gap = chars.pop()

        if gap:
            # 句中断行就把字接在上一段末尾；上一段已经收尾（。！？）
            # 说明这是下一段的开头缺字，补到下一段前面。
            if SENTENCE_END.search(prev["x"]):
                nxt["x"] = gap + nxt["x"]
            else:
                prev["x"] += gap
            continue

        if not pdf:
            missed.append(f"…{prev['x'][-18:]}‖{nxt['x'][:18]}…")

    return out, missed


def repair_private_use(blocks: list[dict], pdf: str | None) -> list[str]:
    """U+F8FF 是 Word 为缺字形字符留下的占位符，按 PDF 上下文补回真字。

    占位符所在位置的前后各取一段文字去 PDF 里对，比对不上就当没有这个字
    （多数是段落之间的换行残留）。
    """
    missed: list[str] = []
    for block in blocks:
        if block["t"] != "p" or PRIVATE_USE not in block["x"]:
            continue

        text = block["x"]
        for _ in range(text.count(PRIVATE_USE)):
            at = text.index(PRIVATE_USE)
            gap = ""
            if pdf:
                for span in (12, 8, 6):
                    before = re.sub(r"\s+", "", text[:at])[-span:]
                    after = re.sub(r"\s+", "", text[at + 1 :])[:span]
                    if not before or not after:
                        continue
                    hits = re.findall(
                        re.escape(before) + r"(.{0,3}?)" + re.escape(after), pdf
                    )
                    chars = {h for h in hits if not re.search(r"\s", h)}
                    if len(chars) == 1:
                        gap = chars.pop()
                        break
            if not gap:
                if not pdf:
                    missed.append(f"…{text[max(0, at - 14):at]}‖{text[at + 1:at + 15]}…")
            text = text[:at] + gap + text[at + 1 :]
        block["x"] = text
    return missed


def merge_broken(blocks: list[dict]) -> list[dict]:
    """把硬折行接回成整段，读起来才连得上。"""
    out: list[dict] = []
    for block in blocks:
        if (
            out
            and block["t"] == "p"
            and out[-1]["t"] == "p"
            and not SENTENCE_END.search(out[-1]["x"])
            and not SUBHEAD.match(block["x"])
        ):
            out[-1]["x"] += block["x"]
            continue
        out.append(block)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="把 108 课 docx 抽成站点 JSON")
    ap.add_argument("--docx", default=DEFAULT_DOCX, help="Word 文档路径")
    ap.add_argument(
        "--pdf-text",
        default="",
        help="同一份文字的 PDF 转纯文本（用来补回丢失的「早」「晚」等字）",
    )
    args = ap.parse_args()

    pdf = None
    if args.pdf_text:
        pdf = re.sub(r"\s+", "", pathlib.Path(args.pdf_text).read_text(encoding="utf-8"))
        print(f"PDF 对照   {args.pdf_text}  {len(pdf):,} 字")

    doc = Document(args.docx)
    images = Images()
    doc_part = doc.part

    lessons: list[dict] = []
    cur: dict | None = None

    for child in doc.element.body.iterchildren():
        if child.tag == qn("w:p"):
            style = para_style(child)
            pieces = paragraph_pieces(child, images, doc_part)

            if style in HEADING_STYLE_IDS:
                title = clean("".join(v for k, v in pieces if k == "text"))
                if title:
                    cur = {"no": len(lessons) + 1, "title": title, "date": "", "blocks": []}
                    lessons.append(cur)
                continue

            if cur is None:
                continue

            for kind, value in pieces:
                if kind == "img":
                    if value.get("glyph"):
                        cur["blocks"].append({"t": "glyph"})
                    else:
                        cur["blocks"].append({"t": "img", **value})
                    continue
                text = clean(str(value))
                if not text:
                    continue
                m = DATE_RE.match(text)
                if m:
                    stamp = f"{m.group(1)} {m.group(2)}"
                    if not cur["date"]:
                        cur["date"] = stamp
                    else:
                        cur["blocks"].append({"t": "date", "x": stamp})
                    continue
                cur["blocks"].append({"t": "p", "x": text})

        elif child.tag == qn("w:tbl") and cur is not None:
            rows = []
            for tr in child.iter(qn("w:tr")):
                cells = [
                    clean(" ".join(t.text or "" for t in tc.iter(qn("w:t"))))
                    for tc in tr.iter(qn("w:tc"))
                ]
                rows.append(cells)
            cur["blocks"].append({"t": "table", "rows": rows})

    missing: list[str] = []
    for lesson in lessons:
        blocks, missed = recover_glyphs(lesson["blocks"], pdf)
        for line in missed:
            missing.append(f"第 {lesson['no']} 课 {line}")
        for line in repair_private_use(blocks, pdf):
            missing.append(f"第 {lesson['no']} 课 [U+F8FF] {line}")
        for line in missed:
            missing.append(f"第 {lesson['no']} 课 {line}")
        lesson["blocks"] = merge_broken(blocks)
        lesson["short"] = re.sub(r"^教你炒股票\s*\d+\s*[：:]\s*", "", lesson["title"])
        lesson["chars"] = sum(len(b.get("x", "")) for b in lesson["blocks"])

    if missing:
        print(f"占位图未还原 {len(missing)} 处：")
        for line in missing:
            print("   ", line)

    if len(lessons) != 108:
        raise SystemExit(f"课数不对：抽到 {len(lessons)} 课，应为 108 课")

    DATA.parent.mkdir(parents=True, exist_ok=True)
    DATA.write_text(
        json.dumps(lessons, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    chars = sum(l["chars"] for l in lessons)
    figs = sum(1 for l in lessons for b in l["blocks"] if b["t"] == "img")
    print(f"课数      {len(lessons)}")
    print(f"字数      {chars:,}")
    print(f"插图      {figs} 处 / {len(images.by_hash)} 张  {images.budget / 1024:.0f} KB")
    print(f"输出      {DATA.relative_to(ROOT)}  {DATA.stat().st_size / 1024:.0f} KB")
    print(f"          {IMG_DIR.relative_to(ROOT)}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
