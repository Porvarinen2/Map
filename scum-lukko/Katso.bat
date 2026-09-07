@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (py lukko.py --katso) || (python lukko.py --katso)
pause
