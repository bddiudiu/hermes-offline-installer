@echo off
setlocal

title Hermes Agent Dashboard
chcp 65001 >nul
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"

set "HERMES_OFFLINE_HOME_EFFECTIVE=%HERMES_OFFLINE_HOME%"
if "%HERMES_OFFLINE_HOME_EFFECTIVE%"=="" set "HERMES_OFFLINE_HOME_EFFECTIVE=%USERPROFILE%\.hermes-offline"

set "HERMES_CMD=%HERMES_OFFLINE_HOME_EFFECTIVE%\bin\hermes.cmd"
if exist "%HERMES_CMD%" goto run

where hermes.cmd >nul 2>nul
if errorlevel 1 goto missing_hermes

for /f "usebackq delims=" %%I in (`where hermes.cmd`) do (
  set "HERMES_CMD=%%I"
  goto run
)

:missing_hermes
echo Hermes command was not found.
echo Please run install.cmd first, then reopen this command window and try again.
echo.
pause
exit /b 1

:run
echo Starting Hermes Dashboard...
echo.
"%HERMES_CMD%" dashboard %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if "%EXIT_CODE%"=="0" goto end
echo Hermes Dashboard exited with code %EXIT_CODE%.
pause

:end
exit /b %EXIT_CODE%
