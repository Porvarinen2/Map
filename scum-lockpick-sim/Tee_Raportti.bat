@echo off
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0live"
title Porvarinen - DEBUG-RAPORTTI
set PYTHONIOENCODING=utf-8
set PY=python
where py >nul 2>&1
if not errorlevel 1 set PY=py -3
echo.
echo  Tekee viimeisimmasta debug-paketista tai pelaajanauhoituksesta
echo  HTML-raportin ja avaa sen selaimeen.
echo.
echo  Voit myos vetaa kansion taman tiedoston paalle, tai antaa kaksi
echo  kansiota vertailuun: botti ensin, pelaaja toisena.
echo.
%PY% -u debug_report.py --avaa %*
echo.
if errorlevel 1 pause
endlocal
