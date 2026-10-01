"""燃灯官网构建脚本。

把 site/ 下的模板渲染成 site/dist/ 里可直接部署的静态站点，并生成
version.json（供 App 内 lib/update_service.dart 检查更新）。

版本号只有一个真源：pubspec.yaml 的 `version: X.Y.Z+NN`。脚本会读它、
校验 APK 里的 versionCode 与之吻合，再把版本号注入全站，避免 App、APK、
官网、version.json 四处对不上。

用法:
  python tools/build_site.py --notes "1.3.1：新增……"
  python tools/build_site.py --notes "1.3.1：新增……" --dry-run
  python tools/build_site.py --sync          # 只重建站点，不发新版本
  python tools/build_site.py --apk <路径>    # 指定要发布的 APK

发布到腾讯云 CloudBase 静态托管:
  tcb hosting deploy site/dist -e <环境ID>
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import html
import json
import pathlib
import re
import shutil
import sys
import zipfile

try:
    from PIL import Image

    _HAS_PIL = True
except ImportError:  # 缺 Pillow 就照原样复制，页面里仍是 .png
    Image = None
    _HAS_PIL = False

# Windows 控制台默认 GBK，中文输出会直接抛 UnicodeEncodeError（报错信息走 stderr）。
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
DIST = SITE / "dist"
CONFIG_PATH = SITE / "site.config.json"
CHANGELOG_PATH = SITE / "changelog.json"
PUBSPEC = ROOT / "pubspec.yaml"
APK_CANDIDATES = (
    ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk",
    ROOT / "build" / "app" / "outputs" / "apk" / "release" / "app-release.apk",
)

LEGAL_DOCS = {
    "privacy": {
        "title": "隐私政策",
        "source": ROOT / "assets" / "agreements" / "privacy_policy.md",
    },
    "terms": {
        "title": "用户协议",
        "source": ROOT / "assets" / "agreements" / "user_agreement.md",
    },
}

# 协议页由 assets/agreements/ 现场生成，模板本身不部署。
TEMPLATES = {"legal.template.html"}


# --------------------------------------------------------------------------
# 读取
# --------------------------------------------------------------------------


def load_config() -> dict:
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def read_pubspec_version() -> tuple[str, int]:
    """从 pubspec.yaml 取 (version, build)。

    只解析 `version:` 这一行，不引 yaml 依赖——pubspec 里带 Flutter 专有
    标签和注释，完整 YAML 解析反而容易出错。
    """
    text = PUBSPEC.read_text(encoding="utf-8")
    m = re.search(r"^version:\s*([0-9A-Za-z.\-+]+)\s*$", text, re.MULTILINE)
    if not m:
        raise SystemExit("pubspec.yaml 里找不到 version 字段")
    raw = m.group(1).strip("'\"")
    name, _, build = raw.partition("+")
    if not build.isdigit():
        raise SystemExit(f"pubspec.yaml 的 version 缺少 build 号：{raw}")
    return name, int(build)


def _read_axml_strings(data: bytes) -> list[str]:
    """取出 AXML 首个字符串池里的全部字符串。"""
    if len(data) < 8 or int.from_bytes(data[0:2], "little") != 0x0003:
        return []

    strings: list[str] = []
    pos = 8  # 跳过 XML 文档头
    while pos + 8 <= len(data):
        ctype = int.from_bytes(data[pos : pos + 2], "little")
        chunk_size = int.from_bytes(data[pos + 4 : pos + 8], "little")
        if chunk_size < 8 or pos + chunk_size > len(data):
            break

        if ctype == 0x0001:  # RES_STRING_POOL_TYPE
            count = int.from_bytes(data[pos + 8 : pos + 12], "little")
            flags = int.from_bytes(data[pos + 16 : pos + 20], "little")
            strings_start = int.from_bytes(data[pos + 20 : pos + 24], "little")
            # 偏移表紧跟 28 字节的块头。
            offsets_at = pos + 28
            is_utf8 = bool(flags & 0x80)

            for i in range(count):
                at = offsets_at + i * 4
                if at + 4 > pos + chunk_size:
                    break
                off = int.from_bytes(data[at : at + 4], "little")
                p = pos + strings_start + off
                if p + 2 > len(data):
                    strings.append("")
                    continue
                if is_utf8:
                    # UTF-8：u8 utf16 长度、u8 utf8 长度、字节、0x00
                    n8 = data[p + 1]
                    strings.append(data[p + 2 : p + 2 + n8].decode("utf-8", "replace"))
                else:
                    # UTF-16：u16 字符数、内容、0x0000
                    n16 = int.from_bytes(data[p : p + 2], "little")
                    strings.append(
                        data[p + 2 : p + 2 + n16 * 2].decode("utf-16-le", "replace")
                    )
            return strings

        pos += chunk_size
    return []


def apk_version_code(path: pathlib.Path) -> int | None:
    """从 APK 的 AndroidManifest.xml 里读 manifest 节点的 versionCode。

    AndroidManifest.xml 是 AXML 二进制格式：这里按块结构取出字符串池，
    再遍历 START_ELEMENT 的属性表，找 name 为 versionCode 的那一项，
    取其 typedValue.data。取不到返回 None，由调用方决定是否算硬错误。
    """
    try:
        with zipfile.ZipFile(path) as zf:
            data = zf.read("AndroidManifest.xml")
    except (KeyError, zipfile.BadZipFile, OSError):
        return None

    strings = _read_axml_strings(data)
    if not strings:
        return None

    def s(idx: int) -> str:
        return strings[idx] if 0 <= idx < len(strings) else ""

    pos = 8
    while pos + 8 <= len(data):
        ctype = int.from_bytes(data[pos : pos + 2], "little")
        chunk_size = int.from_bytes(data[pos + 4 : pos + 8], "little")
        if chunk_size < 8 or pos + chunk_size > len(data):
            break

        # START_ELEMENT: 头 16 字节后是 attr 起始/大小/个数，再跟属性表。
        if ctype == 0x0102:
            name_idx = int.from_bytes(data[pos + 20 : pos + 24], "little")
            attr_start = int.from_bytes(data[pos + 24 : pos + 26], "little")
            attr_size = int.from_bytes(data[pos + 26 : pos + 28], "little")
            attr_count = int.from_bytes(data[pos + 28 : pos + 30], "little")

            if s(name_idx) == "manifest" and attr_size >= 20:
                base = pos + 16 + attr_start
                for i in range(attr_count):
                    a = base + i * attr_size
                    if a + 20 > len(data):
                        break
                    attr_name = s(int.from_bytes(data[a + 4 : a + 8], "little"))
                    if attr_name == "versionCode":
                        return int.from_bytes(data[a + 16 : a + 20], "little")

        pos += chunk_size
    return None


def copy_assets() -> None:
    """把 site/assets 复制到 dist，并把截图归一化成 JPEG。

    源图只读不动（体积大、尺寸也略有出入），产物统一成 852x1846 的
    JPEG q88：实测比原 PNG 小约 88%，且全平台支持，页面不会因为四张
    截图进 6MB 而拖慢首屏。HTML 里引用的是 shot-*.jpg。
    """
    if not _HAS_PIL:
        raise SystemExit(
            "缺 Pillow，无法压缩截图：pip install pillow\n"
            "（缺了它页面会引用不到 shot-*.jpg）"
        )

    dest = DIST / "assets"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(SITE / "assets", dest)

    sources = list(dest.glob("shot-*.png")) + list(dest.glob("shot-*.jpg"))
    if not sources:
        print("提示      没有 shot-*.png/jpg，截图位将为空")

    for src in sorted(sources):
        target = dest / (src.stem + ".jpg")
        try:
            im = Image.open(src).convert("RGB")
        except (OSError, Image.UnidentifiedImageError) as exc:
            print(f"警告      跳过无法读取的截图 {src.name}（{exc}）")
            continue
        if im.size != SHOT_SIZE:
            im = im.resize(SHOT_SIZE, Image.LANCZOS)
        im.save(
            target,
            format="JPEG",
            quality=SHOT_QUALITY,
            optimize=True,
            progressive=True,
        )
        before = src.stat().st_size / 1024
        after = target.stat().st_size / 1024
        print(f"截图      {src.name} -> {target.name}   {before:.0f} -> {after:.0f} KB")
        if src != target and src.exists():
            src.unlink()


# 截图归一化尺寸与质量，须与 site.css 里的 aspect-ratio 保持一致。
SHOT_SIZE = (852, 1846)
SHOT_QUALITY = 88


def find_apk(explicit: str | None) -> pathlib.Path:
    if explicit:
        p = pathlib.Path(explicit)
        if not p.is_absolute():
            p = ROOT / p
        if not p.is_file():
            raise SystemExit(f"指定的 APK 不存在：{p}")
        return p
    for p in APK_CANDIDATES:
        if p.is_file():
            return p
    raise SystemExit(
        "没找到 APK。先执行 flutter build apk --release，"
        "或用 --apk 指定安装包路径。"
    )


def human_size(n: int) -> str:
    return f"{n / 1024 / 1024:.1f} MB"


def sha256_of(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------
# Markdown → HTML
# --------------------------------------------------------------------------


def inline_md(text: str) -> str:
    out = html.escape(text, quote=False)
    out = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        r'<a href="\2">\1</a>',
        out,
    )
    return out


def _strip_legal_banner(md: str) -> str:
    """去掉协议开头的标题与生效日期行。

    这两处在页面模板里已经各有一处（页头大标题 + 生效日期徽章），
    正文里再出现一次就是重复。这里只动开头两行，正文内容不改。
    """
    lines = md.splitlines()
    i = 0
    # 跳过 md 允许的、开头那行之下的空行
    while i < len(lines) and not lines[i].strip():
        i += 1
    if i < len(lines) and re.match(r"^#\s+", lines[i].strip()):
        i += 1
    while i < len(lines) and not lines[i].strip():
        i += 1
    # 生效日期独占一行，或被整行加粗
    if i < len(lines) and re.search(r"生效日期", lines[i]):
        i += 1
    return "\n".join(lines[i:]).strip("\n")


def md_to_html(md: str) -> str:
    """把协议 md 转成 HTML。

    只覆盖这两份文件实际用到的语法：一到三级标题、有序/无序列表、
    加粗、行内链接、段落。够用即可，不引第三方库。
    """
    out: list[str] = []
    list_kind: str | None = None

    def close_list() -> None:
        nonlocal list_kind
        if list_kind:
            out.append(f"</{list_kind}>")
            list_kind = None

    body = _strip_legal_banner(md)

    for raw in body.splitlines():
        line = raw.rstrip()
        stripped = line.strip()

        if not stripped:
            close_list()
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            close_list()
            level = min(len(m.group(1)), 3)
            out.append(f"<h{level}>{inline_md(m.group(2))}</h{level}>")
            continue

        m = re.match(r"^(\d+)[.)]\s+(.*)$", stripped)
        if m:
            if list_kind != "ol":
                close_list()
                out.append("<ol>")
                list_kind = "ol"
            out.append(f"<li>{inline_md(m.group(2))}</li>")
            continue

        m = re.match(r"^[-*+]\s+(.*)$", stripped)
        if m:
            if list_kind != "ul":
                close_list()
                out.append("<ul>")
                list_kind = "ul"
            out.append(f"<li>{inline_md(m.group(1))}</li>")
            continue

        close_list()
        out.append(f"<p>{inline_md(stripped)}</p>")

    close_list()
    return "\n".join(out)


def legal_updated(md: str) -> str:
    m = re.search(r"生效日期[:：]\s*(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日", md)
    if m:
        return f"{m.group(1)} 年 {int(m.group(2))} 月 {int(m.group(3))} 日"
    return ""


def write_qr(target: pathlib.Path, url: str) -> str:
    """生成下载页二维码 PNG。指向 download.html 这类固定地址，永不过期。"""
    try:
        import segno
    except ImportError:
        return ""
    qr = segno.make(url, error="m")
    qr.save(target, scale=10, border=3, dark="#1A1A1A", light="#FFFFFF")
    return url


# --------------------------------------------------------------------------
# 片段
# --------------------------------------------------------------------------


def render_log(releases: list[dict], latest: str) -> str:
    items = []
    for i, r in enumerate(releases):
        is_latest = r["version"] == latest
        cls = "log__item log__item--latest" if is_latest else "log__item"
        badge = '<span class="log__badge">当前版本</span>' if is_latest else ""
        items.append(
            f'<div class="{cls}">'
            f'<div class="log__ver">'
            f"<h3>v{html.escape(r['version'])}</h3>{badge}"
            f'<span class="log__date">{html.escape(r.get("date", ""))}</span>'
            f"</div>"
            f'<div class="log__body">{html.escape(r.get("notes", ""))}</div>'
            f"</div>"
        )
    return "\n".join(items)


# --------------------------------------------------------------------------
# 构建
# --------------------------------------------------------------------------


def build(args: argparse.Namespace) -> pathlib.Path:
    config = load_config()
    version, version_code = read_pubspec_version()
    today = _dt.date.today().isoformat()

    apk = find_apk(args.apk)
    apk_size = apk.stat().st_size
    print(f"版本      v{version} (build {version_code})   ← pubspec.yaml")
    print(f"APK       {apk.relative_to(ROOT)}   {human_size(apk_size)}")

    # 版本一致性校验：APK 里的 versionCode 必须等于 pubspec 的 build 号。
    if not args.skip_verify:
        code = apk_version_code(apk)
        if code is None:
            print("警告      读不出 APK 的 versionCode，跳过校验（不影响构建）")
        elif code != version_code:
            raise SystemExit(
                f"版本号对不上：APK 内 versionCode={code}，"
                f"但 pubspec.yaml 是 {version_code}。\n"
                f"请先在 pubspec.yaml 里把 version 改成 x.y.z+{code}，或重新构建 APK。"
            )
        else:
            print(f"校验      APK versionCode={code} ✓")

    base = config["baseUrl"].rstrip("/")
    apk_url = base + config["apkPath"]
    # 页面按钮用不含前导斜杠的相对路径：本站所有页面都在同一目录，
    # 这样本地预览、正式域名、以及将来放到 /xxx/ 子路径下都能指到同一个文件；
    # 绝对的 apk_url 只留给 version.json（App 更新检查需要绝对地址）。
    apk_href = config["apkPath"].lstrip("/")
    apk_filename = config.get("apkFilename") or "huideng.apk"

    # 更新日志：--notes 传入时把新版本插到最前。
    changelog = json.loads(CHANGELOG_PATH.read_text(encoding="utf-8"))
    releases = changelog["releases"]
    notes = args.notes
    if notes:
        releases = [r for r in releases if r["version"] != version]
        releases.insert(
            0,
            {
                "version": version,
                "versionCode": version_code,
                "date": today,
                "notes": notes,
            },
        )
        changelog["releases"] = releases
        CHANGELOG_PATH.write_text(
            json.dumps(changelog, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"更新日志  已插入 v{version}（{today}）")
    else:
        notes = next(
            (r.get("notes", "") for r in releases if r["version"] == version),
            "",
        )

    # 页面文案里的 APK 体积会随每次构建变，下载页/首页都要跟着更新，
    # 所以所有页面都吃同一份 common 变量。
    # ASSET_VER = site.css 内容指纹，拼在 link 的查询串里。
    # 没有它浏览器会长期缓存旧样式，改了 CSS 用户看不到（已实际踩过）。
    css_ver = hashlib.md5((SITE / "assets" / "site.css").read_bytes()).hexdigest()[:8]
    common = {
        "SITE_NAME": config["siteName"],
        "ASSET_VER": css_ver,
        "TAGLINE": config["tagline"],
        "DESCRIPTION": config["description"],
        "BASE_URL": base,
        "APK_URL": apk_url,
        "APK_HREF": apk_href,
        "APK_FILENAME": apk_filename,
        "APK_SIZE": human_size(apk_size),
        "APK_SHA256": sha256_of(apk) if not args.no_hash else "",
        "VERSION": version,
        "VERSION_CODE": str(version_code),
        "RELEASE_DATE": today,
        "NOTES": notes or "本次更新以修复与体验优化为主。",
        "YEAR": str(_dt.date.today().year),
        "MIN_ANDROID": config.get("minAndroid", ""),
        "PACKAGE_NAME": config.get("packageName", ""),
        "PLATFORM": config.get("platform", "Android"),
        "CONTACT_EMAIL": config.get("contactEmail", ""),
        "RELEASE_COUNT": str(len(releases)),
        "CHANGELOG_PREVIEW": render_log(releases[:3], version),
        "CHANGELOG_ALL": render_log(releases, version),
    }

    DIST.mkdir(parents=True, exist_ok=True)

    copy_assets()

    # 按钮链到 /downloads/xxx.apk，这里必须把包也放进 dist，
    # 否则部署后点击 404——链接和文件要成对落地。
    apk_dest = DIST / "downloads" / apk_filename
    apk_dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(apk, apk_dest)
    print(f"安装包    downloads/{apk_filename}   {human_size(apk_dest.stat().st_size)}")

    # 二维码指向 download.html（固定地址，页面内容随版本更新），所以只需生成一次。
    qr_target = DIST / "assets" / "qr-download.png"
    qr_url = write_qr(qr_target, f"{base}/download.html")
    if qr_url:
        print(f"二维码    assets/qr-download.png  ->  {qr_url}")
    else:
        print("警告      未安装 segno，跳过二维码生成（pip install segno）")

    pages = 0
    for src in sorted(SITE.glob("*.html")):
        if src.name in TEMPLATES:
            continue
        out = src.read_text(encoding="utf-8")
        for key, value in common.items():
            out = out.replace("{{" + key + "}}", value)
        left = sorted(set(re.findall(r"\{\{([A-Z_]+)\}\}", out)))
        if left:
            raise SystemExit(f"{src.name} 还有未替换的占位符：{left}")
        (DIST / src.name).write_text(out, encoding="utf-8")
        pages += 1

    # 协议页：由 assets/agreements/ 的原文生成，保证与 App 内展示一致。
    legal_tpl = (SITE / "legal.template.html").read_text(encoding="utf-8")
    for slug, meta in LEGAL_DOCS.items():
        md = meta["source"].read_text(encoding="utf-8")
        out = legal_tpl
        for key, value in {
            **common,
            "LEGAL_TITLE": meta["title"],
            "LEGAL_SLUG": slug,
            "LEGAL_UPDATED": legal_updated(md),
            "LEGAL_BODY": md_to_html(md),
            "LEGAL_NAV_A": ' aria-current="page"' if slug == "privacy" else "",
            "LEGAL_NAV_B": ' aria-current="page"' if slug == "terms" else "",
        }.items():
            out = out.replace("{{" + key + "}}", value)
        (DIST / f"{slug}.html").write_text(out, encoding="utf-8")
        pages += 1

    # App 内更新检查用的版本信息。
    (DIST / "version.json").write_text(
        json.dumps(
            {
                "version": version,
                "versionCode": version_code,
                "downloadPage": f"{base}/download.html",
                "downloadUrl": apk_url,
                "notes": notes or "",
                "apkSize": apk_size,
                "sha256": common["APK_SHA256"],
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    print(f"输出      {pages + 1} 个文件 -> {DIST.relative_to(ROOT)}")
    print(f"          下载直链 {apk_url}")
    print(f"          更新检查 {base}/version.json")

    if args.dry_run:
        print("\n--dry-run：未部署。")
    return DIST


def main() -> int:
    ap = argparse.ArgumentParser(description="构建燃灯官网静态站点")
    ap.add_argument("--notes", help="新版本更新说明，会写入 changelog.json 并插到最前")
    ap.add_argument("--apk", help="要发布的 APK 路径")
    ap.add_argument("--sync", action="store_true", help="只重建站点，不写更新日志")
    ap.add_argument("--dry-run", action="store_true", help="只生成，不部署")
    ap.add_argument("--no-hash", action="store_true", help="跳过 SHA-256 计算（大文件更快）")
    ap.add_argument("--skip-verify", action="store_true", help="跳过 APK versionCode 校验")
    args = ap.parse_args()
    if args.sync and args.notes:
        raise SystemExit("--sync 与 --notes 不能同时用")
    build(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
