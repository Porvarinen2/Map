@echo off
setlocal
cd /d "%~dp0"
echo =====================================================================
echo  FREELEARN LIVE - the trained policy plays SCUM from the screen
echo =====================================================================
echo Open the SCUM lockpick minigame first. F12 stops, hold F10 pauses.
echo.
set /p LOCKTYPE=Lock type [Auto/Rusted/Basic/Medium/Enforced, default Auto]: 
if "%LOCKTYPE%"=="" set LOCKTYPE=Auto
set /p ATTEMPTS=Attempts [0 = until F12]: 
if "%ATTEMPTS%"=="" set ATTEMPTS=0
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 freelearn_live.py --lock %LOCKTYPE% --attempts %ATTEMPTS%
) else (
  python freelearn_live.py --lock %LOCKTYPE% --attempts %ATTEMPTS%
)
pause
