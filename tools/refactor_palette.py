# -*- coding: utf-8 -*-
"""One-shot refactor: converge hardcoded warm palette colors into AppPalette.

Pass 1 (all files): `const [static] Color NAME = Color(0xFFHEX);` where HEX is a
  warm-family color -> `[static] Color get NAME => AppPalette.p.<slot>;`
  Collect all converted names globally (cross-file const usage detection).
Pass 2 (per file): inline `Color(0xFFHEX)` for mapped hexes -> `AppPalette.p.slot`,
  stripping an immediately preceding `const `.
Pass 3 (per file): remove any `const` keyword whose balanced expression references
  a converted name or `AppPalette.` (string/comment aware bracket matching).
Finally: insert `import 'app_palette.dart';` when the file was touched.

Usage: python tools/refactor_palette.py [--dry]
"""
import bisect
import os
import re
import sys

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'lib')

HEXMAP = {
    'FF5C4033': 'primary',
    'FF5D4037': 'primary',
    'FFD4A06A': 'accent', 'FFD3A069': 'accent', 'FFE8C48A': 'accent',
    'FFF6C57E': 'accent', 'FFCDB292': 'accent',
    'FF9A6B3F': 'accentDeep', 'FF9D5F4B': 'accentDeep', 'FF9D5E4B': 'accentDeep',
    'FFF5EDE3': 'bg',
    'FFFFFAF5': 'card',
    'FF3E2723': 'text',
    'FF8B6B5A': 'textSec',
    'FFC4B5A8': 'textHint',
    'FFEBE1D6': 'border',
    'FFE6DAC8': 'divider',
    'FFEFE6DB': 'borderSoft', 'FFEFE6DA': 'borderSoft', 'FFEDE3D5': 'borderSoft',
    'FFEDE3D6': 'borderSoft', 'FFE8DED0': 'borderSoft', 'FFECE9E4': 'borderSoft',
    'FFE8E2DA': 'borderSoft', 'FFE8E0D5': 'borderSoft', 'FFE9E2D8': 'borderSoft',
    'FFD2C5B3': 'muted', 'FFC6B79E': 'muted', 'FFC0B3A2': 'muted',
    'FFC9BFB2': 'muted', 'FFD4C9BB': 'muted', 'FFBDB6AC': 'muted',
    'FFF3E8DB': 'gradTop',
    'FFF9F1E7': 'gradBot',
    'FFFFF3E0': 'tintBg', 'FFFCF4E7': 'tintBg', 'FFFCF4E6': 'tintBg',
    'FFF8E9CD': 'tintBg', 'FFF7E7CE': 'tintBg', 'FFFFF6EC': 'tintBg',
    'FFFFF5EC': 'tintBg', 'FFF0E6D8': 'tintBg', 'FFF2E7D9': 'tintBg',
}

DECL_RE = re.compile(
    r'^(?P<static>static\s+)?const\s+Color\s+(?P<name>\w+)\s*=\s*'
    r'Color\(0x(?P<hex>[0-9A-Fa-f]{8})\);\s*(?://.*)?$',
    re.M)
INLINE_RE = re.compile(r'(?P<const>const\s+)?Color\(0x(?P<hex>[0-9A-Fa-f]{8})\)')
CONST_KW_RE = re.compile(r'\bconst\b')
DYN_REF_TMPL = r'\b(?:AppPalette\.|(?:%s))\b'


# ---------- opaque range scanning (comments & strings) ----------

def _skip_interp(src, j):
    depth, n = 1, len(src)
    k = j
    while k < n and depth:
        if src[k] == '{':
            depth += 1
        elif src[k] == '}':
            depth -= 1
        k += 1
    return k


def _skip_triple(src, j, q):
    n = len(src)
    while j < n:
        if src.startswith(q, j):
            return j + 3
        if src[j] == '\\':
            j += 2
        elif src[j] == '$' and j + 1 < n and src[j + 1] == '{':
            j = _skip_interp(src, j + 2)
        else:
            j += 1
    return n


def _skip_simple(src, j, q):
    n = len(src)
    while j < n:
        c = src[j]
        if c == '\\':
            j += 2
        elif c == q:
            return j + 1
        elif c == '\n':
            return j
        elif c == '$' and j + 1 < n and src[j + 1] == '{':
            j = _skip_interp(src, j + 2)
        else:
            j += 1
    return j


def scan_opaque(src):
    ranges = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        if two == '//':
            j = src.find('\n', i)
            j = n if j == -1 else j
            ranges.append((i, j))
            i = j
        elif two == '/*':
            j = src.find('*/', i + 2)
            j = n if j == -1 else j + 2
            ranges.append((i, j))
            i = j
        elif c in '\'"':
            if src.startswith(c * 3, i):
                e = _skip_triple(src, i + 3, c * 3)
                ranges.append((i, e))
                i = e
            else:
                e = _skip_simple(src, i + 1, c)
                ranges.append((i, e))
                i = e
        else:
            i += 1
    return ranges


class Opaque:
    def __init__(self, src):
        self.ranges = scan_opaque(src)
        self.starts = [r[0] for r in self.ranges]

    def end_of(self, pos):
        idx = bisect.bisect_right(self.starts, pos) - 1
        if idx >= 0:
            s, e = self.ranges[idx]
            if s <= pos < e:
                return e
        return None

    def jump(self, i):
        """If src[i] is inside an opaque range, return its end; else None."""
        return self.end_of(i)


def find_matching(src, open_idx, op):
    pairs = {'(': ')', '[': ']', '{': '}'}
    depth = 0
    i = open_idx
    n = len(src)
    while i < n:
        e = op.jump(i)
        if e is not None:
            i = e
            continue
        c = src[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def deconst(src, dyn_re):
    """Fix `const` keywords whose expression references dynamic colors.

    - `const SomeCtor(...)` / `const [...]` / `const {...}` -> drop `const`
    - `const name = expr` / `const Type name = expr`        -> replace with `final`
    """
    total = 0
    while True:
        plan = None  # (start, end, replacement)
        op = Opaque(src)
        for m in CONST_KW_RE.finditer(src):
            s = m.start()
            if op.jump(s) is not None:
                continue
            k = m.end()
            while k < len(src) and src[k] in ' \t\r\n':
                k += 1
            if k >= len(src):
                continue
            opener = src[k]
            action = None
            seg_start = close = -1
            if opener in '([{':
                seg_start = k
                close = find_matching(src, k, op)
                action = 'drop'
            elif opener.isalnum() or opener in '_$':
                # walk ahead (crossing newlines/generics) to the first of ( = ; , ) ] }
                lim = min(len(src), k + 600)
                j, depth = k, 0
                while j < lim:
                    c = src[j]
                    if c == '<':
                        depth += 1
                    elif c == '>':
                        depth = max(0, depth - 1)
                    elif c == '(':
                        if depth == 0:
                            break
                    elif c in '=;,)]}':
                        if depth == 0:
                            break
                    j += 1
                else:
                    continue
                if j >= lim:
                    continue
                c = src[j]
                if c == '=' and not src.startswith('==', j):
                    # declaration: only convert when the initializer really
                    # references dynamic colors (find statement end first)
                    i2 = j + 1
                    depth2 = 0
                    end2 = -1
                    while i2 < len(src):
                        e2 = op.jump(i2)
                        if e2 is not None:
                            i2 = e2
                            continue
                        ch = src[i2]
                        if ch in '([{':
                            depth2 += 1
                        elif ch in ')]}':
                            if depth2 == 0:
                                break
                            depth2 -= 1
                        elif ch in ';,' and depth2 == 0:
                            end2 = i2
                            break
                        i2 += 1
                    if end2 == -1:
                        continue
                    dyn = False
                    for dm in dyn_re.finditer(src, j + 1, end2):
                        if op.jump(dm.start()) is None:
                            dyn = True
                            break
                    if not dyn:
                        continue
                    action = 'final'
                elif c == '(':
                    seg_start = j
                    close = find_matching(src, j, op)
                    action = 'drop'
                else:
                    continue
            else:
                continue

            if action is None or (action == 'drop' and close == -1):
                continue

            if action == 'final':
                plan = (s, m.end(), 'final')
            else:
                dyn = False
                for dm in dyn_re.finditer(src, seg_start, close + 1):
                    if op.jump(dm.start()) is None:
                        dyn = True
                        break
                if not dyn:
                    continue
                e = m.end()
                if e < len(src) and src[e] == ' ':
                    e += 1
                plan = (s, e, '')
            break

        if plan is None:
            break
        s, e, repl = plan
        src = src[:s] + repl + src[e:]
        total += 1
    return src, total


def add_import(src):
    if re.search(r"^\s*import\s+'app_palette\.dart';", src, re.M):
        return src
    imports = list(re.finditer(r"^import\s+[^;]+;\s*$", src, re.M))
    line = "import 'app_palette.dart';\n"
    if imports:
        last = imports[-1].end()
        return src[:last] + '\n' + line.rstrip('\n') + src[last:]
    # fallback: after library docblock/first lines
    return line + src


def process(path, global_names, dry):
    with open(path, encoding='utf-8') as f:
        src = f.read()
    orig = src
    stats = {'decl': 0, 'inline': 0, 'deconst': 0}

    # pass 1: declarations -> getters
    def decl_sub(m):
        name = m.group('name')
        slot = HEXMAP.get(m.group('hex').upper())
        if slot is None:
            return m.group(0)
        stats['decl'] += 1
        static = 'static ' if m.group('static') else ''
        return '%sColor get %s => AppPalette.p.%s;' % (static, name, slot)

    src = DECL_RE.sub(decl_sub, src)

    # pass 2: inline replacements (outside strings/comments), strip const prefix
    out = []
    last = 0
    op = Opaque(src)
    for m in INLINE_RE.finditer(src):
        slot = HEXMAP.get(m.group('hex').upper())
        if slot is None:
            continue
        if op.jump(m.start()) is not None:
            continue
        out.append(src[last:m.start()])
        out.append('AppPalette.p.%s' % slot)
        last = m.end()
        stats['inline'] += 1
    out.append(src[last:])
    src = ''.join(out)

    if stats['decl'] or stats['inline']:
        needs_deconst = True
    else:
        # untouched by passes 1/2 but may still reference dynamic getters
        # imported from other libraries (e.g. sText from settings_widgets).
        needs_deconst = False
        probe = Opaque(src)
        dre = re.compile(DYN_REF_TMPL % '|'.join(sorted(set(global_names))))
        for dm in dre.finditer(src):
            if probe.jump(dm.start()) is None:
                needs_deconst = True
                break

    if needs_deconst:
        alt = '|'.join(sorted(set(global_names)))
        src, n_removed = deconst(src, re.compile(DYN_REF_TMPL % alt))
        stats['deconst'] = n_removed
        if n_removed or stats['inline'] or stats['decl']:
            src = add_import(src)

    if src != orig and not dry:
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(src)
    return src != orig, stats


def main():
    dry = '--dry' in sys.argv
    files = []
    for fn in sorted(os.listdir(LIB)):
        if fn.endswith('.dart') and fn != 'app_palette.dart':
            files.append(os.path.join(LIB, fn))

    # global converted-name set (pass over declarations first; idempotent —
    # also recognizes getters produced by a previous run of this script)
    getter_re = re.compile(
        r'^(?:static\s+)?Color\s+get\s+(\w+)\s*=>\s*AppPalette\.p\.\w+;', re.M)
    names = set()
    for path in files:
        with open(path, encoding='utf-8') as f:
            src = f.read()
            for m in DECL_RE.finditer(src):
                if m.group('hex').upper() in HEXMAP:
                    names.add(m.group('name'))
            for m in getter_re.finditer(src):
                names.add(m.group(1))
    print('dynamic names:', ', '.join(sorted(names)))
    if not names:
        raise SystemExit('no dynamic color names found - aborting')

    touched = 0
    for path in files:
        changed, st = process(path, names, dry)
        if changed:
            touched += 1
            print('%-38s decl=%-3d inline=%-4d deconst=%d'
                  % (os.path.basename(path), st['decl'], st['inline'], st['deconst']))
    print('files touched:', touched, '(dry)' if dry else '')


if __name__ == '__main__':
    main()
