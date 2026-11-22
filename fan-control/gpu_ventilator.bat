@echo off
setlocal
chcp 65001 >nul
title GPU ventilatorvezerles (x3650 M5)

net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LenovoGpuFanControl.ps1""

:menu
cls
echo ==============================================================
echo   GPU-alapú, oldalankénti ventilátorvezérlés (IMM2)
echo     Z1 = ventilátor 1-3 (CPU1, GPU0)   Z2 = ventilátor 4-6 (CPU2, GPU1)
echo ==============================================================
echo.
echo   1 - Állapot (GPU-k, ventilátorok, háttérfeladat)
echo   2 - Háttérfeladat TELEPÍTÉSE és indítása (gépindításkor is fut)
echo   3 - Háttérfeladat leállítása (gyári automatika vissza)
echo   4 - Háttérfeladat újraindítása
echo   5 - Háttérfeladat ELTÁVOLÍTÁSA
echo   6 - Futtatás előtérben (teszthez; Ctrl+C = leállítás)
echo   7 - Gyári automatika visszaállítása (vészhelyzet)
echo   8 - Mai napló megnyitása
echo   0 - Kilépés
echo.
set "CH="
set /p "CH=Választás: "
echo.
if "%CH%"=="1" %PS% -Mode Status
if "%CH%"=="2" %PS% -Mode Install
if "%CH%"=="3" %PS% -Mode Stop
if "%CH%"=="4" %PS% -Mode Start
if "%CH%"=="5" %PS% -Mode Uninstall
if "%CH%"=="6" (
    %PS% -Mode Run
    %PS% -Mode Restore
)
if "%CH%"=="7" %PS% -Mode Restore
if "%CH%"=="8" (
    for /f %%d in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd"') do start "" notepad "%~dp0logs\fan_run_%%d.txt"
)
if "%CH%"=="0" exit /b 0
echo.
pause
goto menu
