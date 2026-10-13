@echo off
setlocal

if "%DEVECO_HOME%"=="" set "DEVECO_HOME=D:\DevEco Studio"
set "DEVECO_SDK_HOME=%DEVECO_HOME%\sdk"

if not exist "%DEVECO_SDK_HOME%" (
  echo [build] ERROR: SDK not found at "%DEVECO_SDK_HOME%".
  echo [build] Set DEVECO_HOME to your DevEco Studio install directory.
  exit /b 1
)

if /I "%~1"=="--install" goto :withdeps
goto :build

:withdeps
call "%DEVECO_HOME%\tools\ohpm\bin\ohpm.bat" install --all
if errorlevel 1 exit /b 1
shift
goto :build

:build
call "%DEVECO_HOME%\tools\hvigor\bin\hvigorw.bat" %* --no-daemon
exit /b %ERRORLEVEL%
