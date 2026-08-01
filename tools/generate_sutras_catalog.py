#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Extract the _defaultSutras literal from sutra_list_page.dart into
assets/sutras_catalog.json (compact [title, size, folder] entries),
and replace the literal with an empty list placeholder.

Usage: python tools/generate_sutras_catalog.py
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "lib" / "sutra_list_page.dart"
OUT = ROOT / "assets" / "sutras_catalog.json"

ENTRY_RE = re.compile(
    r"Sutra\('((?:[^'\\]|\\.)*)',\s*'((?:[^'\\]|\\.)*)',\s*filePath:\s*'((?:[^'\\]|\\.)*)',\s*folder:\s*'((?:[^'\\]|\\.)*)'\)"
)
BLOCK_RE = re.compile(
    r"(final\s+List<Sutra>\s+_defaultSutras\s*=\s*\[).*?(\];)",
    re.DOTALL,
)


def main():
    text = SRC.read_text(encoding="utf-8")
    m = BLOCK_RE.search(text)
    if not m:
        print("ERROR: _defaultSutras block not found", file=sys.stderr)
        sys.exit(1)

    block = m.group(0)
    entries = ENTRY_RE.findall(block)
    print(f"parsed {len(entries)} sutra entries")

    # de-escape Dart string escapes (only simple cases here)
    def unescape(s):
        return s.replace("\\'", "'").replace('\\\\', "\\")

    catalog = [
        {"t": unescape(t), "s": unescape(s), "f": unescape(f)}
        for (t, s, _fp, f) in entries
    ]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")

    new_block = "  List<Sutra> _defaultSutras = [];"
    new_text = text[: m.start()] + new_block + text[m.end():]
    SRC.write_text(new_text, encoding="utf-8")
    print(f"replaced literal in {SRC} (removed {len(block)} chars)")


if __name__ == "__main__":
    main()
