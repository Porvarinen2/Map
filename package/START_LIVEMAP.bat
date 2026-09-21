@echo off
chcp 65001 >nul
set PORT=%1
if "%PORT%"=="" set PORT=8777
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0livemap\server.ps1" -Port %PORT%
pause
