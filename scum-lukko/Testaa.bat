@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (py lukko.py --testaa) || (python lukko.py --testaa)
pause
