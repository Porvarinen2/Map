@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (py pelaa.py) || (python pelaa.py)
pause
