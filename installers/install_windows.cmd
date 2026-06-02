@echo off
setlocal

if "%HERMES_INSTALLER_KEEP_OPEN%"=="1" goto run
if "%HERMES_NO_RELAUNCH%"=="1" goto run
set "HERMES_INSTALLER_KEEP_OPEN=1"
start "Hermes Agent Offline Installer" "%ComSpec%" /k ""%~f0" %*"
exit /b 0

:run
title Hermes Agent Offline Installer
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
set "INSTALL_PS1=%SCRIPT_DIR%install_windows.ps1"
set "PAUSE_ON_EXIT=1"
if "%HERMES_NO_PAUSE%"=="1" set "PAUSE_ON_EXIT=0"

if not exist "%INSTALL_PS1%" set "INSTALL_PS1=%SCRIPT_DIR%installers\install_windows.ps1"

if not exist "%INSTALL_PS1%" goto missing_ps1

echo Installing Hermes Agent...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"
goto finish

:missing_ps1
echo Missing installer PowerShell script: %INSTALL_PS1%
set "EXIT_CODE=1"

:finish
echo.
if "%EXIT_CODE%"=="0" goto success
echo Hermes Agent installer failed with exit code %EXIT_CODE%.
goto maybe_pause

:success
echo Hermes Agent installer finished successfully.

:maybe_pause
if not "%PAUSE_ON_EXIT%"=="1" goto end
echo.
pause

:end
exit /b %EXIT_CODE%
