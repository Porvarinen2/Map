@echo off
setlocal
cd /d "%~dp0"
echo =====================================================================
echo  FREELEARN VISUAL TRAINING - the policy sees rendered lock pixels
echo =====================================================================
echo Every frame is rendered from the game lock art and measured with the
echo same reader the live agent uses. Slower than the fast simulator, so
echo use it to finish a policy, not to start one.
echo.
set /p MINUTES=Training minutes [60, 0 = until stopped]: 
if "%MINUTES%"=="" set MINUTES=60
set /p ENVS=Parallel envs [96]: 
if "%ENVS%"=="" set ENVS=96
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 freelearn_trainer.py --visual --envs %ENVS% --minutes %MINUTES%
) else (
  python freelearn_trainer.py --visual --envs %ENVS% --minutes %MINUTES%
)
pause
