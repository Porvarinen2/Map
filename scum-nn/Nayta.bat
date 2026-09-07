@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (py nayta.py) || (python nayta.py)
pause
