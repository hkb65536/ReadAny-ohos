@echo off
setlocal

if "%DEVECO_HOME%"=="" set "DEVECO_HOME=D:\DevEco Studio"
set "HDC=%DEVECO_HOME%\sdk\default\openharmony\toolchains\hdc.exe"

if not exist "%HDC%" (
  echo [device] ERROR: hdc not found at "%HDC%".
  echo [device] Set DEVECO_HOME to your DevEco Studio install directory.
  exit /b 1
)

if "%~1"=="" goto :list
if /I "%~1"=="install" goto :install
if /I "%~1"=="hilog" goto :hilog
goto :passthrough

:list
"%HDC%" list targets -v
exit /b %ERRORLEVEL%

:install
"%HDC%" install -r "%~dp0entry\build\default\outputs\default\entry-default-signed.hap"
exit /b %ERRORLEVEL%

:hilog
"%HDC%" shell hilog -T InkBoat
exit /b %ERRORLEVEL%

:passthrough
"%HDC%" %*
exit /b %ERRORLEVEL%
