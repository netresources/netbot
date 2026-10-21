@echo off
rem Double-click to run install.ps1 (NetBot for Windows). Closes by itself when it worked;
rem stays open when something went wrong, so the message can be read. Wording lives in strings\messages.ps1.
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Launcher
if errorlevel 1 (
  pause >nul
  exit /b 1
)
if not "%NETBOT_NO_AUTOCLOSE%"=="" (
  pause >nul
  exit /b 0
)
timeout /t 3 /nobreak >nul
exit /b 0
