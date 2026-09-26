@echo off
chcp 65001 >nul
title TESLES NPC OVERHAUL - live map
set PORT=%1
if "%PORT%"=="" set PORT=8777
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0livemap\server.ps1" -Port %PORT%
echo.
echo   The live map server stopped.
pause
