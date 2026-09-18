@echo off
setlocal
set "SCRIPT=%~dp0installer\Install.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -SourceRoot "%~dp0." %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo [TeslesNPCOverhaul] Installation failed with code %RC%.
  pause
)
exit /b %RC%
