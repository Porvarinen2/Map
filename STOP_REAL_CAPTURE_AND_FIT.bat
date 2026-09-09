@echo off
setlocal
cd /d "%~dp0"
if not exist "data\real_bridge" mkdir "data\real_bridge" >nul 2>nul
>"data\real_bridge\stop.flag" echo stop

REM Wait briefly for the hidden recorder to flush and exit.
for /l %%I in (1,1,40) do (
  if not exist "data\real_bridge\recorder.pid" goto :fit
  >nul 2>nul ping 127.0.0.1 -n 2
)

:fit
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 real_sim_bridge.py fit
) else (
  python real_sim_bridge.py fit
)
pause
