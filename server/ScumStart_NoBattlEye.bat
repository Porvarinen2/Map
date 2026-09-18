@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ScumStart_NoBattlEye.ps1"
exit /b %errorlevel%
