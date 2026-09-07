@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
  py lockpick_learner.py
) else (
  python lockpick_learner.py
)
pause
