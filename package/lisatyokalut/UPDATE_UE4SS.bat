@echo off
chcp 65001 >nul
echo.
echo   Hakee UE4SS:n uusimman esijulkaisun GitHubista.
echo   INSTALL.bat asentaa paketin mukana tulevan version;
echo   tata tarvitset vain jos haluat viela uudemman.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\INSTALL_UE4SS.ps1" -Force -Experimental -Online
pause
