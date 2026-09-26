@echo off
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\FIX_UE4SS_SCAN.ps1" %*
pause
