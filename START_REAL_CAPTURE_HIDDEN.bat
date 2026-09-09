@echo off
setlocal
cd /d "%~dp0"
if not exist "data\real_bridge" mkdir "data\real_bridge" >nul 2>nul
if exist "data\real_bridge\stop.flag" del /q "data\real_bridge\stop.flag" >nul 2>nul

REM Start passive REAL<->SIM recorder completely hidden. Command Center is NOT required.
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
  "$root=(Get-Location).Path; $py=Get-Command py -ErrorAction SilentlyContinue; if($py){Start-Process -FilePath $py.Source -ArgumentList @('-3','real_sim_bridge.py','record','--lock','Auto') -WorkingDirectory $root -WindowStyle Hidden}else{$p=Get-Command python -ErrorAction SilentlyContinue; if(-not $p){exit 2}; Start-Process -FilePath $p.Source -ArgumentList @('real_sim_bridge.py','record','--lock','Auto') -WorkingDirectory $root -WindowStyle Hidden}"
exit /b %errorlevel%
