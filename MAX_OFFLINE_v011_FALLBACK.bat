@echo off
setlocal
cd /d "%~dp0"
echo Starting legacy v0.11 trainer fallback...
where py >nul 2>nul
if %errorlevel%==0 (
  py offline_max_trainer.py
) else (
  python offline_max_trainer.py
)
if errorlevel 1 pause
