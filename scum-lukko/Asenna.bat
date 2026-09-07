@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (py -m pip install -r vaatimukset.txt) || (python -m pip install -r vaatimukset.txt)
echo.
echo Valmis.
pause
