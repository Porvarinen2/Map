@echo off
chcp 65001 >nul
title TESLES DEALER - install
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0INSTALL.ps1" %*
