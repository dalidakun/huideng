@echo off
rem Huideng APK publisher launcher (double-click me).
rem Opens the GUI with pythonw so no console window stays open.
setlocal
cd /d "%~dp0"

where pythonw >nul 2>nul
if %errorlevel%==0 (
  start "" pythonw "%~dp0tools\publish_apk.py"
  exit /b 0
)

where python >nul 2>nul
if %errorlevel%==0 (
  python "%~dp0tools\publish_apk.py"
  if errorlevel 1 pause
  exit /b 0
)

echo Python 3 not found. Install Python 3 and add it to PATH.
pause
exit /b 1
