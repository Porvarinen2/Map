@echo off
chcp 65001 >nul
title SmartNPC status
setlocal
rem Leave the mod folder so this window never locks it against an update.
cd /d "%TEMP%"
set "PS=powershell.exe"
where /q pwsh.exe && set "PS=pwsh.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0STATUS.ps1"
echo.
pause
