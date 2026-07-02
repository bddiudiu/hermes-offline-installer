@echo off
setlocal

set "SCRIPT_DIR=%~dp0"

call :maybe_elevate %*
if "%HERMES_ELEVATION_STARTED%"=="1" exit /b 0

if "%HERMES_INSTALLER_KEEP_OPEN%"=="1" goto run
if "%HERMES_NO_RELAUNCH%"=="1" goto run
set "HERMES_INSTALLER_KEEP_OPEN=1"
start "Hermes Agent Offline Installer" "%ComSpec%" /k ""%~f0" %*"
exit /b 0

:run
title Hermes Agent Offline Installer
chcp 65001 >nul
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

:maybe_elevate
set "HERMES_ELEVATION_STARTED="
if "%HERMES_NO_ELEVATE%"=="1" exit /b 0
call :detect_portable %*
if "%HERMES_PORTABLE_REQUESTED%"=="1" exit /b 0
call :is_admin
if "%ERRORLEVEL%"=="0" exit /b 0
call :uses_custom_offline_home
if "%HERMES_CUSTOM_OFFLINE_HOME%"=="1" exit /b 0
echo Requesting administrator privileges for the default Program Files installation...
set "HERMES_ELEVATED_COMMAND=/d /k set HERMES_INSTALLER_KEEP_OPEN=1 ^&^& ""%~f0"" %*"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ComSpec -ArgumentList $env:HERMES_ELEVATED_COMMAND -Verb RunAs"
if not "%ERRORLEVEL%"=="0" exit /b %ERRORLEVEL%
set "HERMES_ELEVATION_STARTED=1"
exit /b 0

:detect_portable
set "HERMES_PORTABLE_REQUESTED="
if "%~1"=="" goto detect_portable_env
for %%A in (%*) do (
  if /I "%%~A"=="-Portable" set "HERMES_PORTABLE_REQUESTED=1"
  if /I "%%~A"=="/Portable" set "HERMES_PORTABLE_REQUESTED=1"
)
:detect_portable_env
if /I "%HERMES_PORTABLE_MODE%"=="1" set "HERMES_PORTABLE_REQUESTED=1"
if /I "%HERMES_PORTABLE_MODE%"=="true" set "HERMES_PORTABLE_REQUESTED=1"
if /I "%HERMES_PORTABLE_MODE%"=="yes" set "HERMES_PORTABLE_REQUESTED=1"
if /I "%HERMES_PORTABLE_MODE%"=="on" set "HERMES_PORTABLE_REQUESTED=1"
if not defined HERMES_OFFLINE_HOME if exist "%SCRIPT_DIR%.hermes-offline\bin\hermes.cmd" set "HERMES_PORTABLE_REQUESTED=1"
if not defined HERMES_OFFLINE_HOME if exist "%SCRIPT_DIR%..\.hermes-offline\bin\hermes.cmd" set "HERMES_PORTABLE_REQUESTED=1"
exit /b 0

:uses_custom_offline_home
set "HERMES_CUSTOM_OFFLINE_HOME="
if not defined HERMES_OFFLINE_HOME exit /b 0
set "HERMES_LEGACY_OFFLINE_HOME=%USERPROFILE%\.hermes-offline"
if /I "%HERMES_OFFLINE_HOME%"=="%HERMES_LEGACY_OFFLINE_HOME%" exit /b 0
set "HERMES_CUSTOM_OFFLINE_HOME=1"
exit /b 0

:is_admin
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "if ([System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>nul
exit /b %ERRORLEVEL%
