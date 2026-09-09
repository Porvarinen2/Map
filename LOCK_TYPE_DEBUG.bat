@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
  py neural_lockpick_smart.py --lock-type-debug
) else (
  python neural_lockpick_smart.py --lock-type-debug
)
if errorlevel 1 pause
