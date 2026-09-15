@echo off
setlocal
title SCUM Living NPC - asennus

REM Yksi klikkaus: asentaa tyokalut, kaantaa aivopalvelun ja asentaa modin serverille.
REM Kaytto: setup.bat  tai  setup.bat "F:\SteamLibrary\steamapps\common\SCUM Server"

set "SCRIPT_DIR=%~dp0"
set "SERVER_PATH=%~1"
if "%SERVER_PATH%"=="" set "SERVER_PATH=F:\SteamLibrary\steamapps\common\SCUM Server"

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Tarvitaan admin-oikeudet. Avataan uudelleen korotettuna...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '\"%SERVER_PATH%\"' -Verb RunAs"
  exit /b 0
)

where powershell >nul 2>&1
if %errorlevel% neq 0 (
  echo PowerShell puuttuu. Asennus ei voi jatkua.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup.ps1" -ServerPath "%SERVER_PATH%"
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
  echo Asennus valmis.
) else (
  echo Asennus keskeytyi virheeseen ^(koodi %RC%^). Katso loki: "%SCRIPT_DIR%install.log"
)
pause
exit /b %RC%
