@echo off
setlocal

title Hermes Agent Shutdown
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
set "SHUTDOWN_PS1=%SCRIPT_DIR%shutdown_windows.ps1"
set "PAUSE_ON_EXIT=1"
if "%HERMES_SHUTDOWN_NO_PAUSE%"=="1" set "PAUSE_ON_EXIT=0"

if not exist "%SHUTDOWN_PS1%" set "SHUTDOWN_PS1=%SCRIPT_DIR%installers\shutdown_windows.ps1"

if not exist "%SHUTDOWN_PS1%" goto missing_ps1

echo Stopping Hermes Agent...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SHUTDOWN_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"
goto finish

:missing_ps1
echo Missing shutdown PowerShell script: %SHUTDOWN_PS1%
set "EXIT_CODE=1"

:finish
echo.
if "%EXIT_CODE%"=="0" goto success
echo Hermes Agent shutdown failed with exit code %EXIT_CODE%.
goto maybe_pause

:success
echo Hermes Agent shutdown finished successfully.

:maybe_pause
if not "%PAUSE_ON_EXIT%"=="1" goto end
echo.
pause

:end
exit /b %EXIT_CODE%
