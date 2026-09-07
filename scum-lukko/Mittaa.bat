@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (py lukko.py --mittaa) || (python lukko.py --mittaa)
pause
