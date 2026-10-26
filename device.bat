@echo off
setlocal

rem Resolve DEVECO_HOME without hard-coding any machine path:
rem environment variable -> AGENTS.local.md -> candidate probe (AGENTS.md section 0).
if "%DEVECO_HOME%"=="" (
  for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\env.ps1" -Get DEVECO_HOME`) do set "DEVECO_HOME=%%I"
)
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
