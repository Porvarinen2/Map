@echo off
setlocal
cd /d "%~dp0"

echo =====================================================================
echo  LOCKPICK v0.16.4 NIGHT EVOLUTION - 9 HOUR SAFE SIM TRAIN
echo =====================================================================
echo Game does NOT need to be running.
echo 540 min continual PPO + plateau escape tournament + unseen holdout.
echo Global champion is immutable until a candidate passes the gates.
echo Elite replay is persisted periodically for crash recovery.
echo Ctrl+C is safe.
echo.

set "OMP_NUM_THREADS=%NUMBER_OF_PROCESSORS%"
set "MKL_NUM_THREADS=%NUMBER_OF_PROCESSORS%"
set "NUMEXPR_NUM_THREADS=%NUMBER_OF_PROCESSORS%"
set "OMP_WAIT_POLICY=ACTIVE"
set "MKL_DYNAMIC=FALSE"
set "KMP_BLOCKTIME=0"

where py >nul 2>nul
if %errorlevel%==0 (
  py offline_continual_trainer.py --minutes 540 --night
) else (
  python offline_continual_trainer.py --minutes 540 --night
)
if errorlevel 1 pause
