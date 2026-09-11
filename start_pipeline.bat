@echo off
setlocal EnableExtensions
title GenePipeline Launcher

set "LAUNCHER_DIR=%~dp0"
set "CONFIG_FILE=%LAUNCHER_DIR%.genepipeline_path"
set "PROJECT_DIR="

rem 1) Prefer the folder containing this launcher.
if exist "%LAUNCHER_DIR%decision_ui\api\server.js" (
    set "PROJECT_DIR=%LAUNCHER_DIR%"
)

rem 2) Try a previously selected project folder.
if not defined PROJECT_DIR if exist "%CONFIG_FILE%" (
    set /p PROJECT_DIR=<"%CONFIG_FILE%"
)

if defined PROJECT_DIR if not exist "%PROJECT_DIR%\decision_ui\api\server.js" set "PROJECT_DIR="

rem 3) If still unresolved, ask the user to select the folder containing decision_ui\api\server.js.
if not defined PROJECT_DIR (
    echo.
    echo GenePipeline project folder was not found automatically.
    echo Select the MyPipeline folder that contains decision_ui\api\server.js.
    echo.

    for /f "usebackq delims=" %%I in (`powershell.exe -NoProfile -STA -Command ^
        "Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = 'Select the GenePipeline project folder that contains decision_ui\api\server.js'; if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Write($d.SelectedPath) }"`) do (
        set "PROJECT_DIR=%%I"
    )
)

if not defined PROJECT_DIR (
    echo.
    echo [ERROR] No project folder was selected.
    pause
    exit /b 1
)

if not exist "%PROJECT_DIR%\decision_ui\api\server.js" (
    echo.
    echo [ERROR] decision_ui\api\server.js was not found in:
    echo %PROJECT_DIR%
    echo.
    echo Select the MyPipeline project folder, not the frontend folder.
    del "%CONFIG_FILE%" >nul 2>&1
    pause
    exit /b 1
)

> "%CONFIG_FILE%" echo %PROJECT_DIR%

cd /d "%PROJECT_DIR%"

echo.
echo ========================================
echo   GenePipeline local launcher
echo ========================================
echo Project: %PROJECT_DIR%
echo.

where node >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Node.js was not found.
    echo Install Node.js, then restart this launcher.
    echo.
    pause
    exit /b 1
)

where npm >nul 2>&1
if errorlevel 1 (
    echo [ERROR] npm was not found.
    echo Reinstall Node.js and confirm npm is available in PATH.
    echo.
    pause
    exit /b 1
)

if not exist "node_modules" (
    echo [SETUP] node_modules was not found.
    choice /C YN /M "Run npm install now"
    if errorlevel 2 (
        echo Startup cancelled.
        pause
        exit /b 1
    )

    echo.
    echo [SETUP] Installing Node dependencies...
    call npm install

    if errorlevel 1 (
        echo.
        echo [ERROR] npm install failed.
        pause
        exit /b 1
    )
)

echo [START] Starting GenePipeline server...
echo [OPEN]  Browser URL: http://localhost:3001
echo.
echo Keep this window open while using GenePipeline.
echo Press Ctrl+C in this window to stop the server.
echo.

start "" powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Sleep -Seconds 2; Start-Process 'http://localhost:3001'"

node "decision_ui\api\server.js"

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo GenePipeline server stopped.
pause
exit /b %EXIT_CODE%
