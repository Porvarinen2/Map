@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
  py testit.py
) else (
  python testit.py
)
pause
