@echo off
setlocal
cd /d "%~dp0"

title Autofishing FAST-FOLLOW v4

echo ====================================================================
echo  AUTOFISHING FAST-FOLLOW v4
echo ====================================================================
echo.
echo  Tama on sinun v3:si. Poistettu 22 rivia. Arkkitehtuuri ennallaan.
echo.
echo  LOKISTASI:
echo   bar=(850,946,1040,126)  -^> palkkisi on 1040 px levea, eli kala on
echo   noin 67x59 px ja sen cyan-siluetti noin 2600 pikselia.
echo   v3:ssa luki:  if area ^< 35 or area ^> 1400: continue
echo   Kiintea raja -^> jokainen kala hylattiin liian isona ja nopea
echo   muototunnistus ohitettiin kokonaan.
echo.
echo   SendInput=0/1  -^> INPUT-rakenne oli 32 tavua, Windows odottaa 40.
echo   SendInput epaonnistui aina; napit menivat vain varapolun kautta.
echo.
echo  VIISI KORJAUSTA:
echo   1. kalan kokoraja suhteessa palkin korkeuteen
echo   2. INPUT-rakenne 40 tavua -^> SendInput toimii
echo   3. use_last_error -^> LastError on totta lokissa
echo   4. HSV vain palkin sisalta, ei koko framesta per ehdokas
echo   5. vanhaa 821 ms taysskannausta ei ajeta ARMED_FAST-tilassa
echo.
echo  MITATTU, palkki 1040x104 kuten sinulla:
echo    v3   ei ehtinyt aloittaa seurantaa 5 s:ssa, 0/6 kertaa
echo    v4   21 23 19 22 20 23 ms, mediaani 22 ms, 6/6
echo.
echo  Katso konsolista:  [INPUT] ... SendInput=1/1   (ei 0/1)
echo                     [INSTANT-AD]                (heti palkin jalkeen)
echo.
echo  F8 = tauko/jatka
echo  F9 = lopeta + debug-zip
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

echo [ERROR] Python was not found.
pause
exit /b 1

:done
echo.
echo Script stopped. Exit code: %errorlevel%
pause
endlocal
