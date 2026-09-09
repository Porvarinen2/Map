@echo off
setlocal
cd /d "%~dp0"
set "OMP_NUM_THREADS=%NUMBER_OF_PROCESSORS%"
set "MKL_NUM_THREADS=%NUMBER_OF_PROCESSORS%"
set "NUMEXPR_NUM_THREADS=%NUMBER_OF_PROCESSORS%"
set "OMP_WAIT_POLICY=ACTIVE"
set "MKL_DYNAMIC=FALSE"
set "KMP_BLOCKTIME=0"
where py >nul 2>nul
if %errorlevel%==0 (
  py offline_continual_trainer.py --minutes 60
) else (
  python offline_continual_trainer.py --minutes 60
)
if errorlevel 1 pause
