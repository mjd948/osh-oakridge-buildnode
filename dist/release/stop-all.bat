@echo off
setlocal enabledelayedexpansion

set CONTAINER_NAME=oscar-postgis-container
set SENSORHUB_NAME=com.botts.impl.security.SensorHubWrapper

echo Stopping SensorHubWrapper Java process...

REM wmic was removed in Windows 11 24H2 and Server 2025, so query via CIM instead.
REM Single quotes throughout keep the PowerShell expression clear of batch quoting.
set FOUND_JAVA=0
FOR /F "usebackq tokens=*" %%A IN (`powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process ^| Where-Object { $_.Name -eq 'java.exe' -and $_.CommandLine -like '*%SENSORHUB_NAME%*' } ^| Select-Object -ExpandProperty ProcessId"`) DO (
    set FOUND_JAVA=1
    echo Stopping SensorHubWrapper with PID %%A...
    REM Ask it to close first so the node can flush its state and commit to the
    REM database; only force the kill if it is still alive afterwards.
    taskkill /PID %%A >NUL 2>NUL
    powershell -NoProfile -Command "Wait-Process -Id %%A -Timeout 60 -ErrorAction SilentlyContinue"
    taskkill /PID %%A /F >NUL 2>NUL
    echo SensorHubWrapper stopped.
)

if "!FOUND_JAVA!"=="0" echo SensorHubWrapper process not found.

echo.
echo Stopping container: %CONTAINER_NAME%...

REM Stop the database only after the node has released it.
docker ps -a --format "{{.Names}}" | findstr /X /C:"%CONTAINER_NAME%" >NUL 2>NUL
if errorlevel 1 (
    echo Container not found. Nothing to stop.
) else (
    docker stop "%CONTAINER_NAME%"
    echo Container stopped.
)

echo.
echo Done.

endlocal
