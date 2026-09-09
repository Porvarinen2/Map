@echo off
setlocal
cd /d "%~dp0"
echo Installing Lockpick Learner Neural PPO dependencies...
where py >nul 2>nul
if %errorlevel%==0 (
  py -m pip install --upgrade pip
  py -m pip install -r requirements_neural.txt
) else (
  python -m pip install --upgrade pip
  python -m pip install -r requirements_neural.txt
)
echo.
echo Neural setup complete.
echo The program will automatically use CUDA if your installed PyTorch build supports it.
pause
