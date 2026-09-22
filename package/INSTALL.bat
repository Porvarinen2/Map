@echo off
chcp 65001 >nul
title TESLES NPC OVERHAUL - asennus
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0INSTALL.ps1" %*
