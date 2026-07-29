import re
import shutil
from pathlib import Path

# Build ASCII-only asset paths for sutras to avoid APK asset filename encoding issues.
#
# Input:
#   assets/sutras/**/<ChineseTitle>T01n0031_001.txt
# Output:
#   assets/sutras_ascii/T01/T01n0031_001.txt
#
# This script copies files (does not delete originals).

ID_RE = re.compile(r"(T\d{2}n\d{4}[A-Za-z]?_\d{3})")


def extract_id(filename: str) -> str | None:
    m = ID_RE.search(filename)
    return m.group(1) if m else None


def main() -> None:
    src_root = Path("assets/sutras")
    out_root = Path("assets/sutras_ascii")
    out_root.mkdir(parents=True, exist_ok=True)

    if not src_root.exists():
        raise SystemExit(f"Missing {src_root} (expected sutra txts under it).")

    total = 0
    copied = 0
    skipped = 0
    missing_id = 0

    for p in src_root.rglob("*.txt"):
        total += 1
        sid = extract_id(p.name)
        if not sid:
            missing_id += 1
            continue

        vol = sid[:3]  # "T01"
        dst_dir = out_root / vol
        dst_dir.mkdir(parents=True, exist_ok=True)
        dst = dst_dir / f"{sid}.txt"

        if dst.exists() and dst.stat().st_size == p.stat().st_size:
            skipped += 1
            continue

        shutil.copyfile(p, dst)
        copied += 1

    print(f"total txt: {total}")
    print(f"copied: {copied}")
    print(f"skipped (already same size): {skipped}")
    print(f"missing id (ignored): {missing_id}")
    print(f"output: {out_root}")


if __name__ == "__main__":
    main()


