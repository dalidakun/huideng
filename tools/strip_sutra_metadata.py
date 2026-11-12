# -*- coding: utf-8 -*-
"""去掉经文末尾 CBETA 附带的说明块。

每部经文文末原本带一段固定说明：

    经文名（含卷数）重复
    【经文资讯】…
    【版本记录】…
    【编辑说明】…
    【原始资料】…
    【版权公告】…
    【制作说明】…

本脚本把「从说明块前的空行到文件末尾」整段删除，并顺手删掉紧贴在说明块前面、
重复经名（含卷数，可能带「(八千一百九字)」等卷末字数注）的那一行。
正文里正常的卷末题记（如「某某品第二竟(…字)」）与校勘跋文保持不动。

用法：
    python tools/strip_sutra_metadata.py --dry-run   # 只统计，不写文件
    python tools/strip_sutra_metadata.py             # 正式改写
    python tools/strip_sutra_metadata.py --report tools/_strip_report.json

两个正文目录都会处理（内容相同、文件名不同）：
    assets/sutras_ascii/<卷>/<ID>.txt       ← App 下载源（GitHub）
    assets/sutras/<卷中文名>/<经名><ID>.txt  ← 本地可读副本
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASCII_DIR = ROOT / "assets" / "sutras_ascii"
READABLE_DIR = ROOT / "assets" / "sutras"

MARKERS = [
    "【经文资讯】",
    "【版本记录】",
    "【编辑说明】",
    "【原始资料】",
    "【版权宣告】",  # 少数资料写作「版权公告」，见 _MARKER_ALIASES
    "【制作说明】",
]
# 个别文件在标签前多一个「◎」等排版装饰，定位时允许剥掉。
MARKER_PREFIX_CHARS = "◎○●[＊]* 　\t"
PRIMARY = MARKERS[0]

# 行尾的卷次后缀：卷第一 / 卷上 / 第十二卷 / 一卷 / 卷1 …
VOL_SUFFIX_RE = re.compile(
    r"(?:"
    r"卷(?:第?[一二三四五六七八九十百千零〇两0-9]+|[上中下])?"
    r"|第[一二三四五六七八九十百千零〇两0-9]+卷"
    r"|[一二三四五六七八九十]+卷"
    r"|[上中下]卷"
    r")$"
)

# 括号注释（卷末字数、诵次、异名等）在比对标题时先去掉。
PAREN_RE = re.compile(r"（[^（）]*）|\([^()]*\)|\[[^\[\]]*\]|〔[^〔〕]*〕")
SENT_END = "。！？；：!?"
TITLE_TAIL = ("经", "论", "品", "传", "记", "疏", "钞", "释", "集", "录", "赞", "咒", "呪")

ID_RE = re.compile(r"(T\d{2}n\d{4}[A-Za-z]?_\d{3})")
MAX_TAIL = 4000  # 说明块长度上限，超过说明定位到的不是文末说明


def norm(s: str) -> str:
    s = s.replace("[＊]", "").replace("＊", "").replace("◎", "")
    s = s.replace("《", "").replace("》", "").replace("「", "").replace("」", "")
    s = PAREN_RE.sub("", s)
    s = re.sub(r"[\s\u3000·・]", "", s)
    return s.strip("，。！？；：、,.;:!?")


def strip_vol(s: str) -> str:
    prev = None
    while prev != s:
        prev = s
        s = VOL_SUFFIX_RE.sub("", s)
    return s


def head_title_candidates(body: str, stem: str) -> list[str]:
    cands: list[str] = []
    if stem:
        cands.append(stem)
    seen = 0
    for raw in body.split("\n"):
        t = raw.strip()
        if not t:
            continue
        if re.match(r"^No\.\s*\d", t):  # 「No. 366 [No. 367]」这类编目行
            continue
        if len(t) > 60:
            # 长行已经是正文（短经可能只有几行，别把文末跋记当成经名）。
            break
        if not re.search(r"[\u4e00-\u9fff]", t):
            continue
        cands.append(t)
        seen += 1
        if seen >= 4:
            break
    out: list[str] = []
    for c in cands:
        for v in (norm(c), strip_vol(norm(c))):
            if v and v not in out:
                out.append(v)
    return out


def lev_ratio(a: str, b: str) -> float:
    """归一化编辑距离相似度（1.0 完全相同）。只用于短标题。"""
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    la, lb = len(a), len(b)
    if abs(la - lb) > 6:
        return 0.0
    prev = list(range(lb + 1))
    for i in range(1, la + 1):
        cur = [i] + [0] * lb
        for j in range(1, lb + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        prev = cur
    return 1.0 - prev[lb] / max(la, lb)


def looks_like_title_repeat(line: str, cands: list[str]) -> tuple[bool, str]:
    """判断末行是否为「前文经名（含卷数）」的重复。返回（是否删除，理由）。"""
    raw = line.strip()
    if not raw or len(raw) > 60:
        return False, "too_long"
    # 目录/索引条目（「…卷上（大正五一 P. 833b）」）也以「卷上」收尾，
    # 但那是正文内容，不是卷末题名。
    if "P." in raw or "大正" in raw or re.search(r"[０-９0-9]\s*b\s*）", raw):
        return False, "index_entry"
    # 带句末标点的多半是正文/跋文，不是标题行。
    if any(ch in raw for ch in SENT_END):
        # 例外：标题本身带括号字数注时不含句末标点，所以这里直接排除。
        return False, "sentence"
    n = norm(raw)
    if not n:
        return False, "empty_after_norm"
    nv = strip_vol(n)
    if len(n) < 2 or not re.search(r"[\u4e00-\u9fff]", n):
        return False, "not_chinese"

    # 说明块前的经名重复一定带卷数：卷第一 / 卷上 / 第十二卷 / 一卷 / 上卷 …
    # （单卷经的经名不带卷数，属于正文里的标题段，保留。）
    if VOL_SUFFIX_RE.search(n) and len(n) >= 3:
        return True, "volume"

    for c in cands:
        cv = strip_vol(c)
        if not c:
            continue
        if n == c or n == cv or nv == cv:
            return True, "exact"
        # 简写/漏字/异体：一方包含另一方，且长度接近。
        shorter, longer = (n, c) if len(n) <= len(c) else (c, n)
        if len(shorter) >= 4 and shorter in longer and len(shorter) / len(longer) >= 0.6:
            return True, "contains"
        # 「玉女耶经」/「玉耶女经」这类一字之差。
        if len(n) >= 3 and lev_ratio(n, c) >= 0.75:
            return True, "similar"
        # 共同前缀够长（如「僧伽和尚经」对「僧伽和尚欲入涅槃说六度经」）。
        k = 0
        for x, y in zip(n, c):
            if x != y:
                break
            k += 1
        if k >= 4 and n.endswith(TITLE_TAIL) and nv == strip_vol(n):
            return True, "prefix"
    return False, "no_match"


def process_text(text: str, stem: str) -> tuple[str | None, dict]:
    """返回清理后的文本；结构不符合预期时返回 None 与原因。"""
    info: dict = {}
    if PRIMARY not in text:
        return None, {"error": "marker_missing"}

    idx = text.rfind(PRIMARY)
    if len(text) - idx > MAX_TAIL:
        return None, {"error": "marker_not_at_tail", "tail_len": len(text) - idx}
    line_start = text.rfind("\n", 0, idx) + 1
    prefix = text[line_start:idx]
    if prefix.strip(MARKER_PREFIX_CHARS):
        return None, {"error": "marker_not_line_start", "prefix": prefix}

    tail = text[idx:]
    # 说明块必须按固定顺序包含全部标签，且标签之间不能再夹正文。
    pos = -1
    for m in MARKERS:
        options = [m]
        if m == "【版权宣告】":
            options.append("【版权公告】")  # 兼容旧写法
        found = [(tail.find(o), o) for o in options if tail.find(o) >= 0]
        if not found:
            return None, {"error": f"missing_{m}"}
        p, _hit = min(found)
        if p < pos:
            return None, {"error": f"order_{m}"}
        pos = p
    if tail.count("【经文资讯】") != 1:
        return None, {"error": "marker_repeated"}

    body = text[:line_start].rstrip()
    if not body.strip():
        return None, {"error": "empty_body"}

    cands = head_title_candidates(body, stem)
    # 经文资讯行里的规范经名也作为候选（「… No. 221 放光般若经」）。
    m_info = re.search(r"【经文资讯】.*?No\.\s*\d+[A-Za-z]?\s+(\S.*)$", tail, re.M)
    if m_info:
        cands.append(norm(m_info.group(1)))
        cands.append(strip_vol(norm(m_info.group(1))))
    lines = body.split("\n")
    last = lines[-1].strip()
    removed_title = False
    reason = "kept"
    # 只删文末紧跟说明块的那一行卷末题名（如「佛说阿弥陀经卷第一」）；
    # 更早的行可能是目录条目或引用的书名，属于正文，不能继续往上删。
    ok, why = looks_like_title_repeat(last, cands)
    if ok:
        lines.pop()
        removed_title = True
        reason = why
        body = "\n".join(lines).rstrip()
        if not body.strip():
            return None, {"error": "empty_after_title"}

    info.update({
        "removed_title": removed_title,
        "title_reason": reason,
        "removed_lines": [last] if removed_title else [],
        "removed_chars": len(text) - len(body) - 1 if removed_title else len(text) - len(body),
        "last_line": last[:80],
        "kept_last_line": body.split("\n")[-1].strip()[:80],
    })
    return body + "\n", info


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--report", default=str(ROOT / "tools" / "_strip_report.json"))
    ap.add_argument("--limit", type=int, default=0, help="只处理前 N 个文件（调试用）")
    args = ap.parse_args()

    files = sorted(ASCII_DIR.rglob("*.txt"))
    if args.limit:
        files = files[: args.limit]
    if not files:
        print("no files found", file=sys.stderr)
        return

    report = {
        "total": len(files),
        "changed": 0,
        "removed_title": 0,
        "errors": [],
        "decisions": [],
        "kept_title_like": [],
    }
    # ascii 目录 → 可读目录的映射（同 ID、内容必须一致）。
    readable_by_id: dict[str, Path] = {}
    for p in READABLE_DIR.rglob("*.txt"):
        m = ID_RE.search(p.name)
        if m:
            readable_by_id[m.group(1)] = p

    for i, p in enumerate(files):
        raw_bytes = p.read_bytes()
        bom = raw_bytes.startswith(b"\xef\xbb\xbf")
        text = raw_bytes.decode("utf-8-sig")
        # 保留原有换行风格（这批文件是 CRLF），避免整篇被改成 LF 产生巨大 diff。
        eol = "\r\n" if "\r\n" in text else "\n"
        text_n = text.replace("\r\n", "\n").replace("\r", "\n")
        stem = ID_RE.sub("", p.stem).strip()
        cleaned, info = process_text(text_n, stem)
        rel = p.relative_to(ASCII_DIR).as_posix()
        if cleaned is None:
            report["errors"].append({"file": rel, **info})
            continue
        out_text = cleaned.replace("\n", eol)
        changed = out_text != text
        if changed:
            report["changed"] += 1
        if info.get("removed_title"):
            report["removed_title"] += 1
        report["decisions"].append({
            "file": rel,
            **info,
            "changed": changed,
        })
        # 提醒复查：保留了「像标题」的卷末题记，便于确认没有误删内容。
        kept = info.get("kept_last_line", "")
        if kept and not any(ch in kept for ch in SENT_END) and (
                VOL_SUFFIX_RE.search(kept) or kept.endswith(TITLE_TAIL)):
            report["kept_title_like"].append({"file": rel, "kept": kept[:100]})

        if changed and not args.dry_run:
            # 按字节写回，保持原 BOM / 换行风格，只去掉尾部说明块。
            data = (b"\xef\xbb\xbf" if bom else b"") + out_text.encode("utf-8")
            p.write_bytes(data)
            m = ID_RE.search(p.name)
            if m:
                q = readable_by_id.get(m.group(1))
                if q is not None and q != p:
                    q.write_bytes(data)

        if (i + 1) % 500 == 0:
            print(f"  ... {i + 1}/{len(files)}", flush=True)

    report["decisions"] = report["decisions"]  # keep all decisions for audit
    Path(args.report).write_text(
        json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({
        "total": report["total"],
        "changed": report["changed"],
        "removed_title": report["removed_title"],
        "errors": len(report["errors"]),
        "kept_title_like": len(report["kept_title_like"]),
        "dry_run": args.dry_run,
        "report": args.report,
    }, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
