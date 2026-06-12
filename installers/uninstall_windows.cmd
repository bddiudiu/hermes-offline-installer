@echo off
setlocal

title Hermes Agent Uninstall
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
set "UNINSTALL_PS1=%SCRIPT_DIR%uninstall_windows.ps1"
set "PAUSE_ON_EXIT=1"
if "%HERMES_UNINSTALL_NO_PAUSE%"=="1" set "PAUSE_ON_EXIT=0"

if not exist "%UNINSTALL_PS1%" set "UNINSTALL_PS1=%SCRIPT_DIR%installers\uninstall_windows.ps1"

if not exist "%UNINSTALL_PS1%" goto missing_ps1

echo Uninstalling Hermes Agent...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UNINSTALL_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"
goto finish

:missing_ps1
echo Missing uninstall PowerShell script: %UNINSTALL_PS1%
set "EXIT_CODE=1"

:finish
echo.
if "%EXIT_CODE%"=="0" goto success
echo Hermes Agent uninstall failed with exit code %EXIT_CODE%.
goto maybe_pause

:success
echo Hermes Agent uninstall finished successfully.

:maybe_pause
if not "%PAUSE_ON_EXIT%"=="1" goto end
echo.
pause

:end
exit /b %EXIT_CODE%
