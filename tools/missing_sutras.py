import os
import re


def normalize(p: str) -> str:
    return p.replace("\\", "/").strip()


def extract_sutras(dart_text: str):
    """
    Best-effort extraction for entries like:
      Sutra('标题', 'xxk', filePath: 'assets/...', folder: '...')
    """
    pat = re.compile(
        r"Sutra\('([^']+)'\s*,\s*'[^']*'(?:[\s\S]*?filePath:\s*'([^']+)')?",
        re.M,
    )
    for m in pat.finditer(dart_text):
        yield m.group(1), m.group(2)


def main():
    dart_file = os.path.join("lib", "sutra_list_page.dart")
    with open(dart_file, "r", encoding="utf-8") as f:
        s = f.read()

    id_re = re.compile(r"(T\d{2}n\d{4}[A-Za-z]?_\d{3})")

    total = 0
    missing_titles = []
    for title, fp in extract_sutras(s):
        total += 1

        candidates = set()
        if fp and fp.startswith("assets/"):
            candidates.add(normalize(fp))

        m = id_re.search(fp or "") or id_re.search(title)
        if m:
            sid = m.group(1)
            vol = sid[:3]  # e.g. "T01"
            candidates.add(f"assets/sutras_ascii/{vol}/{sid}.txt")

        ok = False
        for c in candidates:
            disk_path = c.replace("/", os.sep)
            if os.path.exists(disk_path):
                ok = True
                break

        if not ok:
            missing_titles.append(title)

    missing_titles = sorted(set(missing_titles))
    print(f"total: {total}")
    print(f"missing: {len(missing_titles)}")

    out = "missing_sutras.txt"
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(missing_titles))
    print(f"wrote: {out}")


if __name__ == "__main__":
    main()




