@echo off
setlocal
cd /d "%~dp0"

echo =====================================================================
echo  LOCKPICK v0.16.4 NIGHT EVOLUTION - CONTINUAL SKILL BANK MAX
echo =====================================================================
echo Game does NOT need to be running.
echo Uses all CPU cores and a large RAM replay bank when hardware allows.
echo Global champion + 15 per-skill champions + plateau escape.
echo 180+ minute runs automatically enable NIGHT EVOLUTION. Ctrl+C is safe.
echo.

set "OMP_NUM_THREADS=%NUMBER_OF_PROCESSORS%"
set "MKL_NUM_THREADS=%NUMBER_OF_PROCESSORS%"
set "NUMEXPR_NUM_THREADS=%NUMBER_OF_PROCESSORS%"
set "OMP_WAIT_POLICY=ACTIVE"
set "MKL_DYNAMIC=FALSE"
set "KMP_BLOCKTIME=0"

where py >nul 2>nul
if %errorlevel%==0 (
  py offline_continual_trainer.py
) else (
  python offline_continual_trainer.py
)
if errorlevel 1 pause
