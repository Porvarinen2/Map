@echo off
rem Jatkaa keskeytyneesta kohdasta. Valmiit vaiheet ja jo renderoidut tiilet
rem ohitetaan, joten tama on turvallista ajaa niin monta kertaa kuin tarvitsee.
cd /d "%~dp0"
call "%~dp0RUN_ALL.bat" --skip-bootstrap %*
