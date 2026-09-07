@echo off
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0"
set PYTHONIOENCODING=utf-8
set PY=python
where py >nul 2>&1
if not errorlevel 1 set PY=py -3
title SCUM autolockpick - kartoitus
echo.
echo  Mittaa rampin leveyden sen sijaan etta avaisi lukon.
echo  Kun ramppi loytyy, se kavellaan yli lyhyin napautuksin
echo  ja profiili kirjataan tiedostoon loki.jsonl.
echo.
echo  Aja tata 15-20 minuuttia yhta lukkotyyppia, sitten Kartta.bat.
echo.
pause
%PY% -u lockpick.py --kartoita
if errorlevel 1 pause
endlocal
