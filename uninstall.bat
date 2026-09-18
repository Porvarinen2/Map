@echo off
setlocal
set "SCRIPT=%~dp0installer\Uninstall.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
