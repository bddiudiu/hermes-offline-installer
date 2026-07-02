@echo off
setlocal

title Hermes Agent Repair
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
set "REPAIR_PS1=%SCRIPT_DIR%repair_windows.ps1"
set "PAUSE_ON_EXIT=1"
if "%HERMES_REPAIR_NO_PAUSE%"=="1" set "PAUSE_ON_EXIT=0"

if not exist "%REPAIR_PS1%" set "REPAIR_PS1=%SCRIPT_DIR%installers\repair_windows.ps1"

if not exist "%REPAIR_PS1%" goto missing_ps1

echo Repairing Hermes Agent...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%REPAIR_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"
goto finish

:missing_ps1
echo Missing repair PowerShell script: %REPAIR_PS1%
set "EXIT_CODE=1"

:finish
echo.
if "%EXIT_CODE%"=="0" goto success
echo Hermes Agent repair failed with exit code %EXIT_CODE%.
goto maybe_pause

:success
echo Hermes Agent repair finished successfully.

:maybe_pause
if not "%PAUSE_ON_EXIT%"=="1" goto end
echo.
pause

:end
exit /b %EXIT_CODE%
