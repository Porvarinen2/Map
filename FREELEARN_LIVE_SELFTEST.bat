@echo off
setlocal
cd /d "%~dp0"
echo =====================================================================
echo  FREELEARN LIVE SELF-TEST - observation contract + transfer check
echo =====================================================================
echo No game needed. Verifies that the live observation equals the trainer
echo observation and reports how the policy holds up under screen noise.
echo.
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 freelearn_live.py --selftest
  py -3 freelearn_vision.py
) else (
  python freelearn_live.py --selftest
  python freelearn_vision.py
)
pause
