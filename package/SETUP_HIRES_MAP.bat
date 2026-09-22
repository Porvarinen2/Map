@echo off
chcp 65001 >nul
echo.
echo   TESLES NPC OVERHAUL - tarkan kartan asennus
echo   -------------------------------------------
echo   1. Lataa 14k x 14k SCUM-kartta selaimella.
echo   2. Tallenna se nimella  scum_map_hires.png
echo      tahan kansioon:  %~dp0livemap\map\
echo   3. Paina Enter.
echo.
pause
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0livemap\tile_map.ps1"
if errorlevel 1 (
  echo.
  echo   PowerShell palautti virheen. Kopioi yllaoleva teksti talteen.
)
pause
