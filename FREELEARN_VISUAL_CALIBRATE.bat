@echo off
setlocal
cd /d "%~dp0"
echo =====================================================================
echo  VISUAL SIM - measure the screen reader and teach the fast simulator
echo =====================================================================
echo Renders the lock art at in-game scale, reads it back with the live
echo reader, and writes the measured error into freelearn_config.json.
echo No game needed. Restart training afterwards to apply.
echo.
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 freelearn_visual_sim.py --calibrate
) else (
  python freelearn_visual_sim.py --calibrate
)
pause
