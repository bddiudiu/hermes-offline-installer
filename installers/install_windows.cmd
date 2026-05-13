@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "INSTALL_PS1=%SCRIPT_DIR%install_windows.ps1"

if not exist "%INSTALL_PS1%" (
  set "INSTALL_PS1=%SCRIPT_DIR%installers\install_windows.ps1"
)

if not exist "%INSTALL_PS1%" (
  echo Missing installer PowerShell script: %INSTALL_PS1%
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_PS1%" %*
exit /b %ERRORLEVEL%
