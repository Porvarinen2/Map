@echo off
rem ============================================================================
rem  SCUM 32K kartta - aja tama tuplaklikkaamalla.
rem
rem  Tama tiedosto vain etsii Pythonin. Kaikki muu logiikka on
rem  tools\run_pipeline.py:ssa - batch-kieli on liian hauras
rem  riippuvuustarkistuksiin ja tuntien mittaisen ajon tilanseurantaan.
rem ============================================================================
setlocal
title SCUM 32K kartta
cd /d "%~dp0"

echo(
echo  SCUM 32K kartta
echo  ---------------
echo(

rem --- zipin sisalta ajaminen ei toimi: tiedostot pitaa purkaa ensin ---
echo %~dp0 | find /i "\Temp\" >nul
if not errorlevel 1 (
    echo  VIRHE: nayttaa silta etta ajat tata suoraan zipin sisalta.
    echo  Pura koko kansio ensin esim. C:\SCUM-Map\ ja aja RUN_ALL.bat sielta.
    echo(
    pause
    exit /b 1
)

set "PY="
set "PYARGS="

rem Virtuaaliymparisto ensin, jos se on jo luotu.
if exist ".venv\Scripts\python.exe" set "PY=.venv\Scripts\python.exe"

if not defined PY (
    where py >nul 2>nul && ( set "PY=py" & set "PYARGS=-3" )
)
if not defined PY (
    where python >nul 2>nul && set "PY=python"
)
if not defined PY (
    if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" set "PY=%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
)
if not defined PY (
    if exist "%LOCALAPPDATA%\Programs\Python\Python311\python.exe" set "PY=%LOCALAPPDATA%\Programs\Python\Python311\python.exe"
)

if not defined PY (
    echo  VIRHE: Pythonia ei loytynyt.
    echo(
    echo  Asenna se jommallakummalla tavalla:
    echo    winget install -e --id Python.Python.3.12
    echo    tai https://www.python.org/downloads/
    echo(
    echo  Muista asennuksessa rasti kohtaan "Add python.exe to PATH".
    echo(
    pause
    exit /b 1
)

"%PY%" %PYARGS% tools\run_pipeline.py %*
set "RC=%ERRORLEVEL%"

echo(
if not "%RC%"=="0" (
    echo  Ajo paattyi virheeseen ^(koodi %RC%^).
    echo  Jatka korjauksen jalkeen samasta kohdasta: RUN_ALL_resume.bat
) else (
    echo  Valmis.
)
echo(
pause
exit /b %RC%
