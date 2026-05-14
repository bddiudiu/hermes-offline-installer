@echo off
setlocal

if not "%HERMES_INSTALLER_KEEP_OPEN%"=="1" if not "%HERMES_NO_RELAUNCH%"=="1" (
  set "HERMES_INSTALLER_KEEP_OPEN=1"
  start "Hermes Agent Offline Installer" cmd.exe /k call "%~f0" %*
  exit /b 0
)

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
