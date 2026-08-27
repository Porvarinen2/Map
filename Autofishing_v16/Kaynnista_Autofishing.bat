@echo off
setlocal
cd /d "%~dp0"

title Autofishing v16 - Bar is the trigger in every state

echo ====================================================================
echo  AUTOFISHING v16
echo ====================================================================
echo.
echo  MIKA MUUTTUI:
echo.
echo   v15 etsi palkin ~16 ms:ssa, mutta ajoi heti perassa samalla
echo   silmukan kierroksella vanhan tayssskannauksen:
echo.
echo     detect_minigame  412 ms
echo     detect_waiting   293 ms
echo     detect_bite      304 ms
echo     detect_cast      328 ms
echo     -------------------------
echo     1337 ms peraperaa
echo.
echo   Palkkia siis oikeasti etsittiin ~0.7 kertaa sekunnissa.
echo.
echo  v16:
echo   - palkin haku ajetaan JOKA kierroksella joka tilassa
echo   - cast.png-haku ei aja lainkaan ARMED_FAST-tilassa
echo   - kaikki template-matchaus ajetaan tyosaikeessa
echo   - haku karkeasta tarkkaan + skaalalukitus (cast 328 ms -^> ~2 ms)
echo   - kala erotetaan palkin gradientista kirkkauden perusteella
echo   - kokorajat suhteessa palkin korkeuteen (toimii 720p..4K)
echo.
echo  Mitattu viive palkin ilmestymisesta ensimmaiseen A/D:hen: ~25 ms.
echo.
echo  Katso [PERF]-rivia. Se kertoo silmukan todellisen nopeuden.
echo.
echo  F8 = tauko/jatka
echo  F9 = lopeta
echo ====================================================================
echo.

where py >nul 2>nul
if %errorlevel%==0 (
    py -u "%~dp0autofishing_macro.txt"
    goto :done
)

where python >nul 2>nul
if %errorlevel%==0 (
    python -u "%~dp0autofishing_macro.txt"
    goto :done
)

echo [ERROR] Pythonia ei loytynyt.
pause
exit /b 1

:done
echo.
echo Skripti pysahtyi. Paluukoodi: %errorlevel%
pause
endlocal
