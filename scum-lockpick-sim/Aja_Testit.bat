@echo off
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title Porvarinen - Tiirikkapenkin testit
set PYTHONIOENCODING=utf-8
set PY=python
where py >nul 2>&1
if not errorlevel 1 set PY=py -3
echo === 1/10  lukkomalli ja hakusaanto ===
%PY% -u sim\test_sim.py
echo.
echo === 2/10  tunnistus pelin omia kuvia vasten ===
%PY% -u live\test_vision.py
echo.
echo === 3/10  lukkopesan alue ja tarahdysvartija ===
%PY% -u live\test_inner_chamber.py
echo.
echo === 4/10  success-kulmat pelin kuvista ===
%PY% -u live\test_success_angles.py
echo.
echo === 5/10  pyyhkaisyn ja ajovaiheen perussaannot ===
%PY% -u live\test_fast_scan_deep_target.py
echo.
echo === 6/10  vartijat: tarina vs. aito kaanto ===
%PY% -u live\test_real_motion_guard.py
echo.
echo === 7/10  tilakone valesyotteella ===
%PY% -u live\test_runner.py
echo.
echo === 8/10  oikean pelivideon toisto ===
%PY% -u live\test_gameplay.py
echo.
echo === 9/10  ohjain simuloitua lukkoa vasten ===
%PY% -u live\test_live.py
echo.
echo === 10/10 strategia nauhoitukseen kalibroitua mallia vasten ===
%PY% -u live\test_strategy.py
echo.
echo === pelaajanauhurin omat testit ===
%PY% -u live\test_recorder.py
echo.
pause
endlocal
