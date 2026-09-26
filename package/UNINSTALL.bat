@echo off
chcp 65001 >nul
title TESLES NPC OVERHAUL - uninstall
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0UNINSTALL.ps1" %*
