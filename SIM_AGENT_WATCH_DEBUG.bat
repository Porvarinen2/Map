@echo off
cd /d "%~dp0"
python lockpick_pdf_simulator.py --mode agent --episodes 30 --speed 6 --level 2 --debug
pause
