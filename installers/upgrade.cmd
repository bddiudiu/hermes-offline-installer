@echo off
setlocal
set "UPGRADE_PS1=%~dp0upgrade.ps1"
if not exist "%UPGRADE_PS1%" set "UPGRADE_PS1=%~dp0installers\upgrade.ps1"
if not exist "%UPGRADE_PS1%" (
  echo Missing upgrade.ps1
  exit /b 2
)
rem Intentionally synchronous: no start, UAC relaunch, /k or pause.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UPGRADE_PS1%" %*
exit /b %ERRORLEVEL%
