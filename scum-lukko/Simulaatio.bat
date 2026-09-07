@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (py simu.py) || (python simu.py)
pause
