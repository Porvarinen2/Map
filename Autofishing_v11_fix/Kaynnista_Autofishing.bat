@echo off
setlocal
cd /d "%~dp0"

title Autofishing v11 - responsiivisuuskorjaus

echo ====================================================================
echo  AUTOFISHING v11 + RESPONSIIVISUUSKORJAUS
echo ====================================================================
echo.
echo  Tama on sinun v11:si. Ohjain, tunnistus ja SPACE-logiikka ovat
echo  ennallaan. Alkuperaisesta koodista on poistettu 7 rivia.
echo.
echo  ONGELMA:
echo   ARMED_FAST ei ole FISHING, joten odottaessaan kalaa silmukka putosi
echo   myos vanhaan skannaushaaraan, joka kavi koko ruudun lapi:
echo.
echo     detect_minigame  250 ms
echo     detect_waiting   177 ms
echo     detect_bite      177 ms
echo     detect_cast      196 ms
echo     ------------------------
echo     800 ms peraperaa
echo.
echo   Palkkia siis ehdittiin katsoa noin kerran sekunnissa.
echo.
echo  KORJAUS - kolme asiaa:
echo   1. vanhaa skannausta ei ajeta ARMED_FAST-tilassa
echo   2. koko ruudun palkkihaku 0.25 s valein, ei joka kierroksella
echo   3. kallis kala-template vasta kun halpa varitesti sanoo etta
echo      kala on ruudulla (0.33 ms vs 26 ms)
echo.
echo  Mitattu, yksi kierros per ajo, 10 ajoa:
echo    ennen   36 40 42 34 699 36 35 726 36 56 ms
echo    jalkeen 37 37 38 41  38 37 38  37 40 40 ms
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
