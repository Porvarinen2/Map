@echo off
cd /d "%~dp0"
echo ===============================================
echo  REAL ^<--^> SIM BRIDGE - FIT SIMULATOR
echo ===============================================
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 real_sim_bridge.py fit
) else (
  python real_sim_bridge.py fit
)
pause
