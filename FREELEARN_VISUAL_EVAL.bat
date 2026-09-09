@echo off
setlocal
cd /d "%~dp0"
echo =====================================================================
echo  VISUAL SIM - evaluate the checkpoint through rendered frames
echo =====================================================================
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 freelearn_visual_sim.py --eval --episodes 96 --envs 48
) else (
  python freelearn_visual_sim.py --eval --episodes 96 --envs 48
)
pause
