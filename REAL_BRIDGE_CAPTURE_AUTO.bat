@echo off
cd /d "%~dp0"
echo ===============================================
echo  REAL ^<--^> SIM BRIDGE - SCUM SCREEN CAPTURE
echo ===============================================
echo F12 stops capture. This process does NOT inject F or mouse input.
echo.
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 real_sim_bridge.py record --lock Auto
) else (
  python real_sim_bridge.py record --lock Auto
)
pause
