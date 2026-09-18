@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnostics\CollectDiagnostics.ps1" -PackageRoot "%~dp0."
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
