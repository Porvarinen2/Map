@echo off
chcp 65001 >nul
echo.
echo   Downloads the latest UE4SS pre-release from GitHub.
echo   INSTALL.bat installs the version shipped with this package;
echo   you only need this if you want a newer one.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\INSTALL_UE4SS.ps1" -Force -Experimental -Online
pause
