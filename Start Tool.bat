@echo off
setlocal
chcp 65001 >nul

set "ROOT_DIR=%~dp0"
set "GUI_SCRIPT=%ROOT_DIR%scripts\gui_launcher.ps1"

if not exist "%GUI_SCRIPT%" (
    echo Missing GUI script:
    echo %GUI_SCRIPT%
    pause
    exit /b 1
)

if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%GUI_SCRIPT%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%GUI_SCRIPT%" -InitialFile "%~1"
)

endlocal
