@echo off
setlocal
cd /d "%~dp0"
echo =====================================================================
echo  LOCKPICK v0.17.6.2 FREELEARN - FIXED PER-LOCK GEOMETRY + SOFT 50%% PRIORITY
echo =====================================================================
echo Recommended: use LockpickCommandCenter.exe instead.
echo.
set /p MINUTES=Training minutes [540, 0 = until stopped]: 
if "%MINUTES%"=="" set MINUTES=540
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 freelearn_trainer.py --minutes %MINUTES%
) else (
  python freelearn_trainer.py --minutes %MINUTES%
)
pause
