@echo off
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title Porvarinen - Tiirikkapenkin testit
set PYTHONIOENCODING=utf-8
set PY=python
where py >nul 2>&1
if not errorlevel 1 set PY=py -3
echo === lukkomalli ja hakusaanto ===
%PY% -u sim\test_sim.py
echo.
echo === live-ohjain simuloitua lukkoa vasten ===
%PY% -u live\test_live.py
echo.
echo === tunnistus pelin omia kuvia vasten ===
%PY% -u live\test_vision.py
echo.
pause
endlocal
