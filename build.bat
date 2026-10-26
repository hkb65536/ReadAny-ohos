@echo off
setlocal

rem Resolve DEVECO_HOME without hard-coding any machine path:
rem environment variable -> AGENTS.local.md -> candidate probe.
rem scripts\env.ps1 owns those rules; see AGENTS.md section 0.
if "%DEVECO_HOME%"=="" (
  for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\env.ps1" -Get DEVECO_HOME`) do set "DEVECO_HOME=%%I"
)
set "DEVECO_SDK_HOME=%DEVECO_HOME%\sdk"

if not exist "%DEVECO_SDK_HOME%" (
  echo [build] ERROR: DevEco Studio SDK not found at "%DEVECO_SDK_HOME%".
  echo [build] Fix one of: set DEVECO_HOME; or put "DEVECO_HOME = ^<install dir^>" in AGENTS.local.md;
  echo [build] or add the install dir to $devecoCandidates in scripts\env.ps1.
  exit /b 1
)

rem The packaging step shells out to `java`, and DevEco's bundled JBR is not on
rem PATH. Without this the build compiles fine and then dies late in PackageHap
rem with "Error Code: 00308018 / spawn java ENOENT" -- which looks like a code
rem problem but is only a missing JDK. Honour an explicit JAVA_HOME if present.
if "%JAVA_HOME%"=="" if exist "%DEVECO_HOME%\jbr\bin\java.exe" set "JAVA_HOME=%DEVECO_HOME%\jbr"
if not "%JAVA_HOME%"=="" set "PATH=%JAVA_HOME%\bin;%PATH%"

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
