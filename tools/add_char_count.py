#!/usr/bin/env python3
"""Add character count ('c') field to sutras_catalog.json by reading each sutra txt file."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS_ROOT = ROOT / "assets" / "sutras_ascii"
CATALOG = ROOT / "assets" / "sutras_catalog.json"

def count_chars(filepath: Path) -> int:
    """Count Chinese characters only (no punctuation, no numbers, no letters),
    excluding the ~300-char CBETA metadata at the end of each file."""
    try:
        text = filepath.read_text(encoding="utf-8", errors="replace")
        total = sum(1 for ch in text if '\u4e00' <= ch <= '\u9fff')
        return max(0, total - 300)
    except Exception:
        return 0

def title_to_path(title: str) -> Path | None:
    """Extract CBETA ID from title and build asset path."""
    import re
    m = re.search(r'(T\d{2}n\d{4}[A-Za-z]?_\d{3})', title)
    if not m:
        return None
    cbeta_id = m.group(1)
    vol = cbeta_id[:3]
    return ASSETS_ROOT / vol / f"{cbeta_id}.txt"

def main():
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    total_chars = 0
    updated = 0
    for entry in catalog:
        title = entry["t"]
        path = title_to_path(title)
        if path and path.exists():
            cc = count_chars(path)
            entry["c"] = cc
            total_chars += cc
            updated += 1
        else:
            entry["c"] = 0
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"updated {updated}/{len(catalog)} entries, total chars: {total_chars} ({total_chars/10000:.1f}万)")

if __name__ == "__main__":
    main()
