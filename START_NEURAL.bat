@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
  py neural_lockpick_smart.py
) else (
  python neural_lockpick_smart.py
)
if errorlevel 1 pause
