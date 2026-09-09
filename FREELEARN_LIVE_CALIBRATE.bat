@echo off
setlocal
cd /d "%~dp0"
echo ===============================================
echo  FREELEARN LIVE - X / mouse calibration
echo ===============================================
echo Open the SCUM lockpick minigame and do not touch the mouse.
echo.
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 freelearn_live.py --calibrate
) else (
  python freelearn_live.py --calibrate
)
pause
