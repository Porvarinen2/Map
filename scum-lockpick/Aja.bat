@echo off
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title SCUM autolockpick
set PYTHONIOENCODING=utf-8
set PY=python
where py >nul 2>&1
if not errorlevel 1 set PY=py -3
%PY% -u lockpick.py %*
if errorlevel 1 pause
endlocal
