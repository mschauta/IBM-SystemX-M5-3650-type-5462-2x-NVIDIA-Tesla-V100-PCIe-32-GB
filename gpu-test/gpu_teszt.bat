@echo off
setlocal
chcp 65001 >nul
title Tesla V100 teszt

rem --- Rendszergazdai jog ellenorzese, szukseg eseten ujrainditas emelt joggal ---
net session >nul 2>&1
if errorlevel 1 (
    echo Rendszergazdai jog szükséges a teljesítménykorlát beállításához.
    echo UAC megerősítés kérése...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

rem --- Python keresese ---
set "PY="
where python >nul 2>&1 && set "PY=python"
if not defined PY (
    where py >nul 2>&1 && set "PY=py -3"
)
if not defined PY (
    echo HIBA: nem található Python. Telepítsd, vagy add hozzá a PATH-hoz.
    pause
    exit /b 1
)

:menu
cls
echo ==============================================================
echo   Tesla V100 teszt  (rendszergazdaként)
echo ==============================================================
echo.
echo   1 - Kíméletes alapteszt (VRAM, PCIe, számítás, könnyű terhelés)
echo   2 - Fokozatos terhelés: 150 / 200 W        (javasolt első lépés)
echo   3 - Fokozatos terhelés: 150 / 200 / 250 W
echo   4 - Teljes: alapteszt + fokozatos terhelés 250 W-ig
echo   5 - Csak alapteszt, terhelés nélkül
echo   0 - Kilépés
echo.
echo   Futás közben Ctrl+C: azonnali leállítás (a korlát visszaáll).
echo.
set "CH="
set /p "CH=Választás: "

set "ARGS="
if "%CH%"=="1" set "ARGS="
if "%CH%"=="2" set "ARGS=--ramp-only --ramp-steps 150,200"
if "%CH%"=="3" set "ARGS=--ramp-only"
if "%CH%"=="4" set "ARGS=--ramp"
if "%CH%"=="5" set "ARGS=--skip-load"
if "%CH%"=="0" exit /b 0
if not "%CH%"=="1" if not defined ARGS goto menu

echo.
echo   Melyik GPU?  0 = első (07:00.0)   1 = második (87:00.0)   M = mindkettő egymás után
set "GPU="
set /p "GPU=GPU [M]: "
if not defined GPU set "GPU=M"
if /i "%GPU%"=="M" set "GPU=all"
if not "%GPU%"=="0" if not "%GPU%"=="1" if not "%GPU%"=="all" goto menu

echo.
%PY% "%~dp0gpu_alapteszt.py" %ARGS% --gpu %GPU%
set "RC=%errorlevel%"
echo.
if "%RC%"=="0" (
    echo === A teszt hiba nélkül lefutott. A napló a mappában: gpu_alapteszt_*.log ===
) else (
    echo === A teszt HIBÁT jelzett ^(kód: %RC%^). Nézd meg a naplót: gpu_alapteszt_*.log ===
)
echo.
pause
goto menu
