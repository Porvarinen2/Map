@echo off
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title SCUM autolockpick - testitila
set PYTHONIOENCODING=utf-8
set PY=python
where py >nul 2>&1
if not errorlevel 1 set PY=py -3
echo.
echo  Lukee ruutua lahettamatta yhtaan hiiren tai nappaimen syotetta.
echo  Avaa pelin lukkoruutu ja katso, etta kaanto seuraa kun painat F.
echo.
%PY% -u lockpick.py --testaa
if errorlevel 1 pause
endlocal
