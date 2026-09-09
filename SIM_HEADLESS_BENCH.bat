@echo off
cd /d "%~dp0"
python lockpick_pdf_simulator.py --mode bench --episodes 100000 --level 2
pause
