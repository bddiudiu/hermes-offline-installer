@echo off
setlocal

title Hermes Agent Offline Installer
set "SCRIPT_DIR=%~dp0"
set "INSTALL_PS1=%SCRIPT_DIR%install_windows.ps1"
set "PAUSE_ON_EXIT=1"
if "%HERMES_NO_PAUSE%"=="1" set "PAUSE_ON_EXIT=0"

if not exist "%INSTALL_PS1%" (
  set "INSTALL_PS1=%SCRIPT_DIR%installers\install_windows.ps1"
)

if not exist "%INSTALL_PS1%" (
  echo Missing installer PowerShell script: %INSTALL_PS1%
  set "EXIT_CODE=1"
  goto finish
)

echo Installing Hermes Agent...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"

:finish
echo.
if "%EXIT_CODE%"=="0" (
  echo Hermes Agent installer finished successfully.
) else (
  echo Hermes Agent installer failed with exit code %EXIT_CODE%.
)

if "%PAUSE_ON_EXIT%"=="1" (
  echo.
  pause
)

exit /b %EXIT_CODE%
