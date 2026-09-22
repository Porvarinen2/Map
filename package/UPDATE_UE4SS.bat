@echo off
chcp 65001 >nul
echo.
echo   Paivittaa UE4SS:n uusimpaan esijulkaisuun.
echo   Kayta tata kun UE4SS kaatuu AOB-skannaukseen.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0INSTALL_UE4SS.ps1" -Force -Experimental
pause
