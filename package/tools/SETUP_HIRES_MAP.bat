@echo off
chcp 65001 >nul
echo.
echo   TESLES NPC OVERHAUL - high resolution map
echo   -----------------------------------------
echo   1. Download the 14k x 14k SCUM map (see README).
echo   2. Save it as  scum_map_hires.png
echo      in this folder:  %~dp0..\livemap\map\
echo   3. Press Enter.
echo.
pause
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\livemap\tile_map.ps1"
if errorlevel 1 (
  echo.
  echo   PowerShell reported an error. Copy the text above.
)
pause
