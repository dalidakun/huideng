@echo off
rem ============================================================
rem   燃灯官网 - 一键更新工具
rem   用法：flutter build apk --release 之后，双击本文件。
rem   动作：校验版本号 -> 重建站点（页脚含备案号）
rem         -> 部署到 CloudBase 根目录 + /huideng
rem         -> 回源验证线上 APK 下载
rem ============================================================
cd /d "%~dp0.."
echo.
echo [一键更新] 打包产物：build\app\outputs\flutter-apk\app-release.apk
echo.
chcp 65001 >nul
python "%~dp0update_site.py" || pause
