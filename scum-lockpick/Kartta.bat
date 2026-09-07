@echo off
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0"
set PYTHONIOENCODING=utf-8
set PY=python
where py >nul 2>&1
if not errorlevel 1 set PY=py -3
title SCUM autolockpick - kartta
%PY% -u lockpick.py --kartta
pause
endlocal
