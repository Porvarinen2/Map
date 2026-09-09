@echo off
setlocal
cd /d "%~dp0"
if not exist "data\real_bridge" mkdir "data\real_bridge" >nul 2>nul
>"data\real_bridge\stop.flag" echo stop
exit /b 0
