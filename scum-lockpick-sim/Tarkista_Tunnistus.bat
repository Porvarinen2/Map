@echo off
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0live"
title Porvarinen - AUTOLOCKPICK LIVE - PROBE
set PYTHONIOENCODING=utf-8
where py >nul 2>&1
if not errorlevel 1 goto use_py
where python >nul 2>&1
if not errorlevel 1 goto use_python
echo Pythonia ei loytynyt. Asenna Python 3.10 tai uudempi ja valitse Add Python to PATH.
pause
exit /b 1
:use_py
py -3 -u autolockpick_live.py --probe %*
goto finished
:use_python
python -u autolockpick_live.py --probe %*
:finished
if errorlevel 1 pause
endlocal
