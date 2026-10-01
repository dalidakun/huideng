"""扫描 site/ 下所有文本文件，找出 U+FFFD 替换字符（写入时编码丢失导致）。

用法:
  python tools/site_check.py            # 只检查，列出坏行
  python tools/site_check.py --fix      # 连同 --from/--to 给出的替换一起改

用法示例（把坏行整行替换掉）:
  python tools/site_check.py --fix 34 --from "页面永远是最新版" --to "页面永远是最新版"
"""

import argparse
import pathlib
import sys

# Windows 控制台默认 GBK，输出替换字符会直接抛 UnicodeEncodeError。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPL = "\ufffd"
ROOT = pathlib.Path(__file__).resolve().parent.parent / "site"
TEXT_SUFFIXES = {".html", ".css", ".json", ".js", ".md"}


def text_files() -> list[pathlib.Path]:
    return [p for p in sorted(ROOT.rglob("*")) if p.suffix in TEXT_SUFFIXES]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix", type=int, help="要替换的行号（1 起）")
    ap.add_argument("--from", dest="old", help="替换后的正确内容")
    ap.add_argument("--to", dest="new", help="替换后的正确内容（缺省与 --from 相同）")
    args = ap.parse_args()

    bad = 0
    for path in text_files():
        raw = path.read_bytes()
        try:
            content = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            print(f"{path}: 不是合法 UTF-8 -> {exc}")
            bad += 1
            continue
        if REPL not in content:
            continue

        lines = content.split("\n")
        for i, line in enumerate(lines, start=1):
            if REPL in line:
                print(f"{path}:{i}: {line.strip()}")
                bad += 1
                if args.fix == i:
                    replacement = args.new if args.new is not None else args.old
                    lines[i - 1] = replacement
                    path.write_text("\n".join(lines), encoding="utf-8")
                    print(f"  -> 已修复第 {i} 行")
                    bad -= 1

    if bad == 0:
        print("OK：site/ 下所有文本文件编码正常，无替换字符。")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
