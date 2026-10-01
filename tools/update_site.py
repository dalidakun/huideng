"""把最新 Release APK 更新到官网站点，并部署到 CloudBase。

给「打包完直接双击」用的：先 flutter build apk --release，
再运行本脚本（或同目录的 bat），它会
  1. 报出 build/app/outputs/flutter-apk/app-release.apk 的大小、构建时间、SHA1
  2. 调 tools/build_site.py：校验 APK 的 versionCode 与 pubspec 一致，
     把 APK 复制进 site/dist/downloads/，重建全部页面与 version.json
  3. tcb hosting deploy 把 site/dist 传到云端子目录
  4. 回源请求一次 APK，确认线上真能下到完整文件

用法：
  python tools/update_site.py
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
APK = ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
BUILD = ROOT / "tools" / "build_site.py"
CONFIG = ROOT / "site" / "site.config.json"
DIST = ROOT / "site" / "dist"


def _reconfigure() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")


def human(n: int) -> str:
    return f"{n / 1024 / 1024:.1f} MB"


def sha1_of(path: pathlib.Path) -> str:
    h = hashlib.sha1()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_build() -> int:
    print("[开始]   正在校验版本号并重建站点……")
    print("-" * 62)
    # 子进程直接写控制台，父进程若被块缓冲会排到它后面，先落盘。
    sys.stdout.flush()
    return subprocess.run([sys.executable, str(BUILD)], cwd=str(ROOT)).returncode


def deploy() -> tuple[int, str]:
    """上传 site/dist，返回 (状态码, 说明)。0=成功 1=失败 2=跳过。"""
    try:
        cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"[部署]   读不到 site.config.json：{e}")
        return 1, "config"

    dep = cfg.get("deploy") or {}
    env_id = dep.get("cloudbaseEnvId")
    cloud_path = dep.get("cloudPath") or ""

    if not env_id:
        print("[部署]   site.config.json 未配置 deploy.cloudbaseEnvId，已跳过。")
        print("         想自动部署就在 config 里加上这个字段。")
        return 2, "未配置"

    tcb = shutil.which("tcb")
    if not tcb:
        print("[部署]   未找到 tcb CLI，已跳过。")
        print("         安装：npm install -g @cloudbase/cli   然后 tcb login")
        return 2, "无 tcb"

    args = [tcb, "hosting", "deploy", str(DIST), cloud_path, "-e", env_id]
    # npm 装出来的 tcb 是 .cmd 包装器，CreateProcess 不能直接跑它
    # （会 WinError 2，而 shutil.which 又会放行），必须交给 cmd.exe。
    if tcb.lower().endswith((".cmd", ".bat")):
        args = ["cmd", "/c", *args]

    print(f"[部署]   tcb hosting deploy {DIST.relative_to(ROOT)} {cloud_path} -e {env_id}")
    sys.stdout.flush()
    proc = subprocess.run(args, cwd=str(ROOT))
    if proc.returncode != 0:
        print()
        print("[部署]   上传失败。常见原因：")
        print("           未登录 → 先执行 tcb login")
        print("           环境到期 → tcb env list 查看到期时间")
        return 1, "上传失败"
    print("[部署]   上传完成。")
    return 0, "已上传"


def verify(cfg: dict) -> int:
    """回源请求一次 APK，确认线上真的能下到完整文件。"""
    base = (cfg.get("baseUrl") or "").rstrip("/")
    apk_url = base + (cfg.get("apkPath") or "/downloads/huideng.apk")
    local_size = APK.stat().st_size
    print(f"[验证]   {apk_url}")
    sys.stdout.flush()
    try:
        with urllib.request.urlopen(apk_url, timeout=60) as resp:
            status = resp.status
            length = int(resp.headers.get("Content-Length") or 0)
            ctype = resp.headers.get("Content-Type", "-")
    except urllib.error.HTTPError as e:
        print(f"         HTTP {e.code}  ← 线上不可访问")
        return 1
    except Exception as e:  # noqa: BLE001 - 网络错误种类多，统一给出提示
        print(f"         请求失败：{e}")
        return 1

    ok = status == 200 and length == local_size
    print(f"         HTTP {status}  {length:,} bytes  {ctype}")
    if length == local_size:
        print(f"         与本地一致（{human(local_size)}）")
    else:
        print(f"         与本地不一致（本地 {local_size:,}）← 线上可能是旧包")
    print(f"{'[验证]   通过。' if ok else '[验证]   未通过，请重新部署。'}")
    return 0 if ok else 1


def main() -> int:
    print("=" * 62)
    print("  燃灯官网 · 更新最新 Release APK 并部署")
    print("=" * 62)
    print()

    if not APK.is_file():
        print("[未找到] 还没有打包产物：")
        print(f"         {APK.relative_to(ROOT)}")
        print()
        print("         请先执行：")
        print("             flutter build apk --release")
        print("         打包完成后再双击本工具。")
        return 1

    st = APK.stat()
    when = _dt.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
    print("[安装包] " + str(APK.relative_to(ROOT)))
    print(f"         大小 {human(st.st_size)}   构建于 {when}")
    print(f"         SHA1 {sha1_of(APK)}")
    print()

    if run_build() != 0:
        print()
        print("[失败]   站点未更新，请看上方的错误信息。")
        print()
        print("         最常见：APK 里的 versionCode 与 pubspec.yaml 的 build 号")
        print("         对不上——改完 pubspec 的 version 再重新打包。")
        return 1

    apk_out = DIST / "downloads" / "huideng.apk"
    print()
    if apk_out.is_file():
        print("[完成]   本地站点已更新：")
        print(f"         {apk_out.relative_to(ROOT)}   {human(apk_out.stat().st_size)}")
        print(f"         页面与 version.json（{DIST.relative_to(ROOT)}）")
    else:
        print("[注意]   构建成功，但 dist 里没找到安装包。")
    print()

    cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
    code, _why = deploy()
    print()

    if code == 0:
        if verify(cfg) != 0:
            return 1
        print()
        print("[上线]   官网地址：")
        print(f"         {cfg.get('baseUrl', '')}/")
        print()
        print("         CDN 若显示旧页面，等几分钟或用无痕窗口看。")
        return 0

    if code == 2:
        print("[未部署] 只更新了本地。手动上传：")
        print("             tcb hosting deploy site/dist huideng -e <环境ID>")
        print()
        print("         只在本地预览的话，刷新浏览器即可看到最新版。")
        return 0

    return 1


if __name__ == "__main__":
    _reconfigure()
    try:
        code = main()
    except KeyboardInterrupt:
        print()
        code = 130
    print()
    try:
        input("按回车键关闭……")
    except EOFError:
        pass
    sys.exit(code)
