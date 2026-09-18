@echo off
setlocal
set "MOD_ROOT=%~dp0.."
for %%I in ("%MOD_ROOT%") do set "MOD_ROOT=%%~fI"
set "TESLES_BRAIN_TARGET=%MOD_ROOT%\brain\src\server.js"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StopTeslesNPCBrain.ps1"
exit /b %ERRORLEVEL%
