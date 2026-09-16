@echo off
chcp 65001 >nul
title SmartNPC repair
setlocal
set "PS=powershell.exe"
where /q pwsh.exe && set "PS=pwsh.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0REPAIR.ps1" -ServerPath "%~1"
echo.
pause
