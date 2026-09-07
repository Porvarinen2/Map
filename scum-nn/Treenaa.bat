@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (py treeni.py) || (python treeni.py)
pause
