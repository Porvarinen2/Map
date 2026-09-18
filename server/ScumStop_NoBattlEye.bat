@echo off
setlocal
echo ==== STOP %DATE% %TIME% ====
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ScumStop_NoBattlEye.ps1"
exit /b %ERRORLEVEL%
