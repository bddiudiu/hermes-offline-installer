@echo off
setlocal EnableExtensions DisableDelayedExpansion
if "%~1"=="" (
  echo Usage: upgrade.cmd "C:\path\to\existing\Hermes" -WhatIf
  echo Run this command from the new ZIP's hermes-offline-installer-win-x64 folder.
  exit /b 2
)
set "UPGRADE_PS1=%~dp0upgrade.ps1"
if not exist "%UPGRADE_PS1%" set "UPGRADE_PS1=%~dp0installers\upgrade.ps1"
if not exist "%UPGRADE_PS1%" (
  echo Missing upgrade.ps1. Fully extract the release ZIP before running upgrade.cmd.
  exit /b 2
)
rem Intentionally synchronous: no start, UAC relaunch, /k or pause.
echo [Hermes upgrade] Starting Windows PowerShell preflight...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UPGRADE_PS1%" %*
exit /b %ERRORLEVEL%
