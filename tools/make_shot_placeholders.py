"""生成截图占位图。

正式截图需要你自己截（我读不了图片内容，也没法凭空造真图）。
先按最终尺寸生成占位图，保证布局能看、真图换上后不用调 CSS。

用法:
  python tools/make_shot_placeholders.py          # 只补缺失的，不覆盖已有
  python tools/make_shot_placeholders.py --force  # 全部重生成

把真截图按同名覆盖进 site/assets/ 即可，尺寸如下：
  shot-home.png    852 x 1846   App 首页（首屏右侧的手机模型）
  shot-reading.png 852 x 1846   精读
  shot-sect.png    852 x 1846   宗门法门
  shot-note.png    852 x 1846   笔记

按你手上截图的 852 x 1846（实际截图比例）统一尺寸，页面里的宽高比
也写成 852/1846，换图后不用动 CSS。
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from PIL import Image, ImageDraw

for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSETS = ROOT / "site" / "assets"

SHOT_W, SHOT_H = 852, 1846

SHOTS = {
    "shot-home.png": ("App 首页", "首屏右侧的手机模型"),
    "shot-reading.png": ("精读界面", "逐段阅读"),
    "shot-sect.png": ("经藏 · 宗门法门", "八宗十二门"),
    "shot-note.png": ("读书笔记", "关联经文段落"),
}

BG = (242, 242, 242)
FG = (171, 171, 171)
ACCENT = (93, 124, 90)


def font(size: int):
    """挑一个能显示中文的字体，挑不到就退回默认。"""
    candidates = [
        pathlib.Path("C:/Windows/Fonts/msyh.ttc"),
        pathlib.Path("C:/Windows/Fonts/msyhl.ttc"),
        pathlib.Path("C:/Windows/Fonts/simhei.ttf"),
        pathlib.Path("C:/Windows/Fonts/simsun.ttc"),
    ]
    for path in candidates:
        if path.is_file():
            try:
                return ImageFont_truetype(str(path), size)
            except OSError:
                continue
    return ImageFont.load_default()


def ImageFont_truetype(name: str, size: int):
    from PIL import ImageFont

    return ImageFont.truetype(name, size)


def make(name: str, label: str, caption: str) -> None:
    w, h = SHOT_W, SHOT_H
    img = Image.new("RGB", (w, h), BG)
    draw = ImageDraw.Draw(img)

    # 顶部一条淡绿的提示带，暗示这是待替换的占位图
    draw.rectangle([0, 0, w, 150], fill=(255, 255, 255))
    draw.line([(0, 150), (w, 150)], fill=(232, 232, 232), width=2)

    def center(text: str, y: int, f, fill) -> None:
        tw = draw.textlength(text, font=f)
        draw.text(((w - tw) / 2, y), text, font=f, fill=fill)

    center("截图待替换", 52, font(38), ACCENT)
    center(label, h / 2 - 70, font(58), FG)
    center(caption, h / 2 + 14, font(34), (214, 214, 214))
    center(f"{w} x {h}", h / 2 + 76, font(30), (200, 200, 200))

    img.save(ASSETS / name, optimize=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true", help="覆盖已有图片")
    args = ap.parse_args()

    ASSETS.mkdir(parents=True, exist_ok=True)
    for name, (label, caption) in SHOTS.items():
        path = ASSETS / name
        if path.is_file() and not args.force:
            print(f"跳过    {name}（已存在，--force 可覆盖）")
            continue
        make(name, label, caption)
        print(f"生成    {name}  {SHOT_W}x{SHOT_H}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
