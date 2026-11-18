#!/usr/bin/env python3
"""燃灯 APK 一键发布工具（双击运行）。

功能：
  1. 自动选中 build/app/outputs/flutter-apk/app-release.apk；
  2. 从 pubspec.yaml 读版本号，并校验 APK 里的 versionCode；
  3. 可选先执行 flutter build apk --release --target-platform android-arm64；
  4. 可选同时更新云函数 api（注册 / 邮箱找回等接口有改动时勾选）；
  5. 调用官网仓库 tools/update_site.py：收包 → 写 release.json / changelog
     → 重建站点 → 部署根目录与 /huideng → 回源校验。

命令行用法（自动化 / 排查）：
  python tools/publish_apk.py --cli
  python tools/publish_apk.py --cli --version 3.5.5+41 --notes "更新说明"
  python tools/publish_apk.py --cli --apk D:\\path\\app-release.apk --version 3.5.5+41
  python tools/publish_apk.py --cli --backend-only
  python tools/publish_apk.py --cli --no-deploy    # 只更新本地站点，不上传
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import webbrowser
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[1]
SITE_ROOT_DEFAULT = Path(
    os.environ.get("AIBUILDER_WEB_ROOT") or r"E:\aibuilder-web"
)
ENV_ID_FALLBACK = "randeng-d8gs968w22a3d98e8"
DOWNLOAD_PAGE = "https://aibuilder.top/download.html"
APP_DOWNLOAD_APK = "https://aibuilder.top/downloads/huideng.apk"
IS_WINDOWS = os.name == "nt"
CREATE_NO_WINDOW = 0x08000000 if IS_WINDOWS else 0

APK_CANDIDATES = [
    APP_ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk",
    APP_ROOT / "build" / "app" / "outputs" / "apk" / "release" / "app-release.apk",
]
STAGING_APK_CANDIDATES = sorted(
    (APP_ROOT / "release").glob("*.apk"),
    key=lambda p: p.stat().st_mtime,
    reverse=True,
) if (APP_ROOT / "release").is_dir() else []


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

def newest_apk() -> Path | None:
    """优先用 Flutter 最新构建产物，其次用 release/ 下最新的 apk。"""
    existing = [p for p in APK_CANDIDATES if p.is_file()]
    if existing:
        return max(existing, key=lambda p: p.stat().st_mtime)
    if STAGING_APK_CANDIDATES:
        return STAGING_APK_CANDIDATES[0]
    return None


def read_pubspec_version() -> str:
    pubspec = APP_ROOT / "pubspec.yaml"
    try:
        text = pubspec.read_text(encoding="utf-8")
    except OSError:
        return ""
    match = re.search(r"^version:\s*([^\s#]+)", text, re.MULTILINE)
    return match.group(1).strip() if match else ""


def parse_version(raw: str) -> tuple[str, int]:
    name, _, build = (raw or "").strip().partition("+")
    if not name or not build.isdigit():
        raise ValueError(f"版本号要写成 x.y.z+NN，例如 3.5.5+41；当前：{raw!r}")
    return name, int(build)


def read_env_id(site_root: Path) -> str:
    try:
        cfg = json.loads(
            (site_root / "site" / "site.config.json").read_text(encoding="utf-8")
        )
        env_id = (cfg.get("deploy") or {}).get("cloudbaseEnvId")
        if env_id:
            return str(env_id)
    except (OSError, json.JSONDecodeError):
        pass
    return ENV_ID_FALLBACK


def read_published_release(site_root: Path) -> dict:
    try:
        return json.loads(
            (site_root / "site" / "release.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError):
        return {}


def load_apk_version_code(apk: Path, site_root: Path) -> int | None:
    """复用官网仓库 build_site.py 的 AXML 解析，取 APK 的 versionCode。"""
    build_site = site_root / "tools" / "build_site.py"
    if not build_site.is_file():
        return None
    try:
        spec = importlib.util.spec_from_file_location(
            "_huideng_build_site", build_site
        )
        if spec is None or spec.loader is None:
            return None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.apk_version_code(apk)
    except Exception:  # noqa: BLE001 - 读不出来就交给 update_site.py 再做硬校验
        return None


def run_stream(
    cmd: list[str],
    cwd: Path,
    on_line,
    stdin_text: str | None = None,
    env_extra: dict[str, str] | None = None,
) -> int:
    """运行子进程，逐行回调输出；stdin_text 用于回答交互式确认。"""
    env = os.environ.copy()
    env.setdefault("PYTHONIOENCODING", "utf-8")
    env.setdefault("PYTHONUTF8", "1")
    if env_extra:
        env.update(env_extra)

    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd),
        stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        creationflags=CREATE_NO_WINDOW,
    )
    if stdin_text is not None and proc.stdin is not None:
        try:
            proc.stdin.write(stdin_text)
            proc.stdin.flush()
        except (BrokenPipeError, OSError):
            pass
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass
    assert proc.stdout is not None
    for line in proc.stdout:
        on_line(line.rstrip("\r\n"))
    return proc.wait()


# ---------------------------------------------------------------------------
# 发布步骤
# ---------------------------------------------------------------------------

def deploy_cloud_function(site_root: Path, log) -> bool:
    """更新云函数 api。必须在 cloudfunctions/api 目录里跑：
    CLI 在无 cloudbaserc 时会把 functionPath 记成 '.'，在仓库根目录跑会
    把整个仓库打包（>1.5MB），在函数目录里跑才只打包函数本身。
    """
    api_dir = site_root / "cloudfunctions" / "api"
    if not api_dir.is_dir():
        log(f"[云函数] 目录不存在：{api_dir}")
        return False
    tcb = shutil.which("tcb")
    if not tcb:
        log("[云函数] 未找到 tcb CLI，请先 npm install -g @cloudbase/cli && tcb login")
        return False
    env_id = read_env_id(site_root)
    # --deployMode zip 避免 COS 上传偶发 60s 超时；
    # 传入一个回车选择「使用当前配置更新」。
    cmd = [
        "cmd", "/c", tcb, "fn", "code", "update", "api",
        "--dir", ".", "-e", env_id, "--deployMode", "zip",
    ] if IS_WINDOWS else [
        tcb, "fn", "code", "update", "api",
        "--dir", ".", "-e", env_id, "--deployMode", "zip",
    ]
    log(f"[云函数] tcb fn code update api -e {env_id} --deployMode zip")
    code = run_stream(cmd, api_dir, log, stdin_text="\n")
    if code != 0:
        log(f"[云函数] 更新失败（exit {code}）。若是未登录，先在终端执行 tcb login。")
        return False
    log("[云函数] 更新成功。")
    return True


def build_release_apk(log) -> bool:
    flutter = shutil.which("flutter")
    if not flutter:
        log("[构建] 未找到 flutter，请确认已加入 PATH。")
        return False
    # 只打 arm64：安装包约 33MB；universal（含 armeabi-v7a/x86_64）会到 80MB。
    # 线上一直下发的是 arm64 包，保持与旧版一致的体积。
    cmd = [
        "cmd", "/c", flutter, "build", "apk", "--release",
        "--target-platform", "android-arm64",
    ] if IS_WINDOWS else [
        flutter, "build", "apk", "--release",
        "--target-platform", "android-arm64",
    ]
    log("[构建] flutter build apk --release --target-platform android-arm64")
    code = run_stream(cmd, APP_ROOT, log)
    if code != 0:
        log(f"[构建] 失败（exit {code}）。")
        return False
    log("[构建] 打包完成。")
    return True


def publish_site(
    site_root: Path,
    apk: Path,
    version: str,
    notes: str,
    no_deploy: bool,
    log,
) -> bool:
    update_site = site_root / "tools" / "update_site.py"
    if not update_site.is_file():
        log(f"[发布] 找不到 {update_site}")
        return False
    cmd = [
        sys.executable, "-u", str(update_site),
        "--apk", str(apk),
        "--version", version,
        "--notes", notes.strip() or "本次更新以修复与体验优化为主。",
    ]
    if no_deploy:
        cmd.append("--no-deploy")
    log(f"[发布] {'本地构建（不上传）' if no_deploy else '上传到 aibuilder.top'}")
    code = run_stream(cmd, site_root, log)
    if code != 0:
        log(f"[发布] 失败（exit {code}）。")
        return False
    log("[发布] 完成。")
    return True


def validate_inputs(
    apk: Path,
    version: str,
    site_root: Path,
    *,
    require_apk: bool = True,
) -> tuple[bool, str]:
    if require_apk and not apk.is_file():
        return False, f"APK 不存在：{apk}"
    try:
        name, build = parse_version(version)
    except ValueError as exc:
        return False, str(exc)
    if not (site_root / "tools" / "update_site.py").is_file():
        return False, f"官网仓库路径不对，找不到 {site_root / 'tools' / 'update_site.py'}"
    if not require_apk:
        return True, ""
    actual = load_apk_version_code(apk, site_root)
    if actual is not None and actual != build:
        return False, (
            f"APK 的 versionCode={actual}，与版本号 {version} 的 build={build} 不一致。\n"
            "请重新打包，或把版本号改成与 APK 一致。"
        )
    return True, ""


def publish_all(
    apk: Path,
    version: str,
    notes: str,
    site_root: Path,
    *,
    deploy_backend: bool,
    build_first: bool,
    no_deploy: bool,
    log,
) -> bool:
    # 统一转绝对路径：update_site.py 在官网仓库目录里运行，相对路径会解析错。
    apk = apk.expanduser().resolve()
    site_root = site_root.expanduser().resolve()
    if build_first:
        if not build_release_apk(log):
            return False
        rebuilt = newest_apk()
        if rebuilt is not None:
            apk = rebuilt
    ok, message = validate_inputs(apk, version, site_root)
    if not ok:
        log(f"[校验] {message}")
        return False
    apk_code = load_apk_version_code(apk, site_root)
    log(f"[校验] APK：{apk}")
    log(f"[校验] 版本：{version}  APK versionCode={apk_code if apk_code is not None else '未知'}")
    if deploy_backend:
        if not deploy_cloud_function(site_root, log):
            return False
    return publish_site(site_root, apk, version, notes, no_deploy, log)


# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

class PublishApp:
    def __init__(self, root):
        import tkinter as tk
        from tkinter import ttk

        self.tk = tk
        self.root = root
        self.root.title("燃灯 APK 发布工具")
        self.root.geometry("820x680")
        self.root.minsize(720, 560)

        self.running = False
        self.queue: queue.Queue = queue.Queue()

        self.apk_var = tk.StringVar(value=str(newest_apk() or ""))
        self.version_var = tk.StringVar(value=read_pubspec_version())
        self.site_var = tk.StringVar(value=str(SITE_ROOT_DEFAULT))
        self.backend_var = tk.BooleanVar(value=True)
        self.build_var = tk.BooleanVar(value=False)
        self.status_var = tk.StringVar(value="就绪")

        self._build_ui()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.after(100, self._poll_queue)

    def _build_ui(self):
        from tkinter import ttk

        pad = {"padx": 10, "pady": 4}
        outer = ttk.Frame(self.root, padding=12)
        outer.pack(fill="both", expand=True)

        form = ttk.LabelFrame(outer, text="发布内容", padding=10)
        form.pack(fill="x")

        ttk.Label(form, text="APK：").grid(row=0, column=0, sticky="w", **pad)
        ttk.Entry(form, textvariable=self.apk_var).grid(
            row=0, column=1, sticky="ew", **pad
        )
        ttk.Button(form, text="浏览…", command=self._browse_apk).grid(
            row=0, column=2, **pad
        )

        ttk.Label(form, text="版本：").grid(row=1, column=0, sticky="w", **pad)
        ttk.Entry(form, textvariable=self.version_var, width=22).grid(
            row=1, column=1, sticky="w", **pad
        )
        self.check_label = ttk.Label(form, text="")
        self.check_label.grid(row=1, column=2, sticky="w", **pad)

        ttk.Label(form, text="官网仓库：").grid(row=2, column=0, sticky="w", **pad)
        ttk.Entry(form, textvariable=self.site_var).grid(
            row=2, column=1, sticky="ew", **pad
        )
        ttk.Button(form, text="选择…", command=self._browse_site).grid(
            row=2, column=2, **pad
        )

        ttk.Label(form, text="更新说明：").grid(
            row=3, column=0, sticky="nw", **pad
        )
        self.notes_text = self.tk.Text(form, height=4, wrap="word")
        self.notes_text.grid(row=3, column=1, columnspan=2, sticky="ew", **pad)

        opts = ttk.Frame(form)
        opts.grid(row=4, column=1, columnspan=2, sticky="w", **pad)
        ttk.Checkbutton(
            opts,
            text="同时更新云函数 api（接口/注册登录有改动时勾选）",
            variable=self.backend_var,
        ).pack(side="left", padx=(0, 16))
        ttk.Checkbutton(
            opts,
            text="发布前重新构建 APK（flutter build apk --release，arm64）",
            variable=self.build_var,
        ).pack(side="left")

        form.columnconfigure(1, weight=1)

        actions = ttk.Frame(outer)
        actions.pack(fill="x", pady=(8, 4))
        self.publish_btn = ttk.Button(
            actions, text="发布到官网", command=lambda: self._start(False)
        )
        self.publish_btn.pack(side="left", padx=(0, 8))
        self.local_btn = ttk.Button(
            actions, text="仅本地构建（不上传）", command=lambda: self._start(True)
        )
        self.local_btn.pack(side="left", padx=(0, 8))
        ttk.Button(
            actions, text="打开下载页", command=lambda: webbrowser.open(DOWNLOAD_PAGE)
        ).pack(side="left", padx=(0, 8))
        ttk.Button(actions, text="校验 APK", command=self._check_apk).pack(
            side="left", padx=(0, 8)
        )
        ttk.Button(actions, text="清空日志", command=self._clear_log).pack(side="left")
        ttk.Label(actions, textvariable=self.status_var).pack(side="right")

        log_frame = ttk.LabelFrame(outer, text="日志", padding=6)
        log_frame.pack(fill="both", expand=True, pady=(6, 0))
        self.log_text = self.tk.Text(log_frame, height=18, wrap="word")
        scroll = ttk.Scrollbar(
            log_frame, orient="vertical", command=self.log_text.yview
        )
        self.log_text.configure(yscrollcommand=scroll.set)
        self.log_text.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

    # -- 选择 / 校验 -----------------------------------------------------
    def _browse_apk(self):
        from tkinter import filedialog

        initial = Path(self.apk_var.get()).parent if self.apk_var.get() else APP_ROOT
        path = filedialog.askopenfilename(
            title="选择要发布的 APK",
            initialdir=str(initial if initial.is_dir() else APP_ROOT),
            filetypes=[("APK 安装包", "*.apk"), ("所有文件", "*.*")],
        )
        if path:
            self.apk_var.set(path)
            self._check_apk()

    def _browse_site(self):
        from tkinter import filedialog

        path = filedialog.askdirectory(
            title="选择 aibuilder-web 仓库目录",
            initialdir=self.site_var.get() or str(SITE_ROOT_DEFAULT),
        )
        if path:
            self.site_var.set(path)

    def _check_apk(self):
        apk = Path(self.apk_var.get().strip())
        site_root = Path(self.site_var.get().strip())
        version = self.version_var.get().strip()
        ok, message = validate_inputs(apk, version, site_root)
        if not ok:
            self.check_label.configure(text="✗ 校验失败", foreground="#B00020")
            self._log(f"[校验] {message}")
            return
        actual = load_apk_version_code(apk, site_root)
        self.check_label.configure(
            text=f"✓ versionCode={actual}" if actual is not None else "✓（未读到 versionCode）",
            foreground="#1B7F3B",
        )
        self._log("[校验] 通过。")

    # -- 发布 ------------------------------------------------------------
    def _start(self, no_deploy: bool):
        from tkinter import messagebox

        if self.running:
            messagebox.showwarning("正在发布", "请等待当前任务完成。")
            return
        apk = Path(self.apk_var.get().strip())
        site_root = Path(self.site_var.get().strip())
        version = self.version_var.get().strip()
        notes = self.notes_text.get("1.0", "end").strip()

        ok, message = validate_inputs(
            apk,
            version,
            site_root,
            # 勾选「先构建」时允许 APK 还不存在，构建后再做硬校验。
            require_apk=not self.build_var.get(),
        )
        if not ok:
            messagebox.showerror("无法发布", message)
            return

        published = read_published_release(site_root)
        if (
            not no_deploy
            and published.get("version")
            and str(published.get("version")) == version.split("+")[0]
            and int(published.get("versionCode") or 0) == int(version.split("+")[1])
        ):
            if not messagebox.askyesno(
                "版本已在线",
                f"线上已经是 v{published.get('version')}（build {published.get('versionCode')}）。\n"
                "继续发布会用同名版本覆盖它，老用户不会收到更新提示。\n\n仍要发布吗？",
            ):
                return

        target = "本地站点（不上传）" if no_deploy else "aibuilder.top"
        if not messagebox.askyesno(
            "确认发布",
            f"目标：{target}\n版本：{version}\nAPK：{apk.name}\n\n开始发布？",
        ):
            return

        self.running = True
        self.publish_btn.configure(state="disabled")
        self.local_btn.configure(state="disabled")
        self.status_var.set("发布中…")
        self._log("=" * 60)
        self._log(f"开始发布 {version} → {target}")

        def worker():
            try:
                ok = publish_all(
                    apk,
                    version,
                    notes,
                    site_root,
                    deploy_backend=self.backend_var.get(),
                    build_first=self.build_var.get(),
                    no_deploy=no_deploy,
                    log=lambda line: self.queue.put(("log", line)),
                )
                self.queue.put(("done", ok, no_deploy))
            except Exception as exc:  # noqa: BLE001 - 界面上显示，不让线程静默死掉
                self.queue.put(("log", f"[错误] {exc}"))
                self.queue.put(("done", False, no_deploy))

        threading.Thread(target=worker, daemon=True).start()

    def _poll_queue(self):
        try:
            while True:
                item = self.queue.get_nowait()
                if item[0] == "log":
                    self._log(item[1])
                elif item[0] == "done":
                    self._finish(item[1], item[2])
        except queue.Empty:
            pass
        self.root.after(100, self._poll_queue)

    def _finish(self, ok: bool, no_deploy: bool):
        from tkinter import messagebox

        self.running = False
        self.publish_btn.configure(state="normal")
        self.local_btn.configure(state="normal")
        if ok:
            self.status_var.set("完成")
            if no_deploy:
                messagebox.showinfo(
                    "完成", "本地站点已重建（未上传）。\n确认无误后可再点「发布到官网」。"
                )
            else:
                messagebox.showinfo(
                    "发布成功",
                    "已上线：\n"
                    + DOWNLOAD_PAGE
                    + "\n\n安装包：\n"
                    + APP_DOWNLOAD_APK,
                )
                webbrowser.open(DOWNLOAD_PAGE)
        else:
            self.status_var.set("失败")
            messagebox.showerror(
                "发布失败", "请查看日志末尾的错误信息；常见原因是 tcb 未登录或网络超时。"
            )

    # -- 日志 / 关闭 -----------------------------------------------------
    def _log(self, line: str):
        self.log_text.insert("end", line + "\n")
        self.log_text.see("end")

    def _clear_log(self):
        self.log_text.delete("1.0", "end")

    def _on_close(self):
        from tkinter import messagebox

        if self.running:
            messagebox.showwarning("正在发布", "发布过程中请不要关闭窗口。")
            return
        self.root.destroy()


# ---------------------------------------------------------------------------
# 命令行
# ---------------------------------------------------------------------------

def cli_main(args) -> int:
    def log(line: str):
        print(line, flush=True)

    site_root = (
        Path(args.site) if args.site else SITE_ROOT_DEFAULT
    ).expanduser().resolve()
    version = (args.version or read_pubspec_version()).strip()
    apk = Path(args.apk).expanduser().resolve() if args.apk else newest_apk()
    if not version:
        log("[错误] 没读到版本号，请用 --version 指定，例如 3.5.5+41")
        return 2
    if apk is None:
        log("[错误] 没找到 APK，请用 --apk 指定路径。")
        return 2
    if args.backend_only:
        if deploy_cloud_function(site_root, log):
            return 0
        return 1
    ok = publish_all(
        apk,
        version,
        args.notes or "",
        site_root,
        deploy_backend=not args.skip_backend,
        build_first=args.build,
        no_deploy=args.no_deploy,
        log=log,
    )
    return 0 if ok else 1


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError):
            pass

    parser = argparse.ArgumentParser(
        description="燃灯 APK 一键发布工具（双击运行会打开窗口）"
    )
    parser.add_argument("--cli", action="store_true", help="命令行模式（不打开窗口）")
    parser.add_argument("--apk", help="APK 路径；省略则自动找最新构建产物")
    parser.add_argument("--version", help="版本号 x.y.z+NN；省略则读 pubspec.yaml")
    parser.add_argument("--notes", default="", help="更新说明")
    parser.add_argument("--site", help="aibuilder-web 仓库路径")
    parser.add_argument("--no-deploy", action="store_true", help="只更新本地站点，不上传")
    parser.add_argument("--skip-backend", action="store_true", help="不更新云函数 api")
    parser.add_argument("--build", action="store_true", help="发布前先 flutter build apk --release（arm64）")
    parser.add_argument("--backend-only", action="store_true", help="只更新云函数 api")
    args = parser.parse_args()

    if args.cli or args.backend_only:
        return cli_main(args)

    try:
        import tkinter as tk
    except ImportError:
        print("缺少 tkinter，无法打开窗口；请用 --cli 模式。", file=sys.stderr)
        return 1
    root = tk.Tk()
    PublishApp(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
