@echo off
setlocal
set "MOD_ROOT=%~dp0.."
for %%I in ("%MOD_ROOT%") do set "MOD_ROOT=%%~fI"
set "NODE_EXE="
set "PORTABLE_NODE=%MOD_ROOT%\..\_Dependencies\Node\node.exe"
if exist "%PORTABLE_NODE%" (
  "%PORTABLE_NODE%" --version >nul 2>&1
  if not errorlevel 1 set "NODE_EXE=%PORTABLE_NODE%" & goto :node_found
)
where node >nul 2>&1
if not errorlevel 1 for /f "delims=" %%N in ('where node') do set "NODE_EXE=%%N" & goto :node_found
if not defined NODE_EXE (
  echo [ERROR] Node.js is not available. Re-run install.bat to bootstrap the portable runtime automatically.
  exit /b 2
)
:node_found
"%NODE_EXE%" "%MOD_ROOT%\brain\tools\launchDetached.js"
exit /b %ERRORLEVEL%
