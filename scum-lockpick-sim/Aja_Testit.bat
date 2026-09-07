@echo off
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title Porvarinen - Tiirikkapenkin testit
set PYTHONIOENCODING=utf-8
set PY=python
where py >nul 2>&1
if not errorlevel 1 set PY=py -3
echo === 1/7  lukkomalli ja hakusaanto ===
%PY% -u sim\test_sim.py
echo.
echo === 2/7  tunnistus pelin omia kuvia vasten ===
%PY% -u live\test_vision.py
echo.
echo === 3/7  lukkopesan alue ja tarahdysvartija ===
%PY% -u live\test_inner_chamber.py
echo.
echo === 4/7  success-kulmat pelin kuvista ===
%PY% -u live\test_success_angles.py
echo.
echo === 5/7  tilakone valesyotteella ===
%PY% -u live\test_runner.py
echo.
echo === 6/7  oikean pelivideon toisto ===
%PY% -u live\test_gameplay.py
echo.
echo === 7/7  ohjaimen kayttaytyminen ===
%PY% -u live\test_control.py
echo.
echo === pelaajanauhurin omat testit ===
%PY% -u live\test_recorder.py
echo.
pause
endlocal
