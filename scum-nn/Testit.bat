@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (py testit.py) || (python testit.py)
pause
