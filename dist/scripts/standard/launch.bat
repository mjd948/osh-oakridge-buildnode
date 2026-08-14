@echo off
setlocal enabledelayedexpansion

REM Directory containing this script. Everything below is resolved against it.
set "SCRIPT_DIR=%~dp0"

REM Optional operator configuration. Keeps machine-specific settings (heap size,
REM store passwords, log location) out of this script so upgrades don't clobber them.
if exist "%SCRIPT_DIR%oscar.env.bat" call "%SCRIPT_DIR%oscar.env.bat"

REM Make sure all the necessary certificates are trusted by the system.
CALL "%SCRIPT_DIR%load_trusted_certs.bat"

if "%KEYSTORE%"=="" set "KEYSTORE=.\osh-keystore.p12"
if "%KEYSTORE_TYPE%"=="" set "KEYSTORE_TYPE=PKCS12"
if "%KEYSTORE_PASSWORD%"=="" set "KEYSTORE_PASSWORD=atakatak"

REM Must match the file name load_trusted_certs.bat actually writes ("trustStore.jks").
if "%TRUSTSTORE%"=="" set "TRUSTSTORE=.\trustStore.jks"
if "%TRUSTSTORE_TYPE%"=="" set "TRUSTSTORE_TYPE=JKS"
if "%TRUSTSTORE_PASSWORD%"=="" set "TRUSTSTORE_PASSWORD=changeit"

if "%INITIAL_ADMIN_PASSWORD_FILE%"=="" set "INITIAL_ADMIN_PASSWORD_FILE=.\.s"

REM Check if INITIAL_ADMIN_PASSWORD_FILE and INITIAL_ADMIN_PASSWORD are empty
REM Set default password if neither is provided
if "%INITIAL_ADMIN_PASSWORD_FILE%"=="" if "%INITIAL_ADMIN_PASSWORD%"=="" (
    set INITIAL_ADMIN_PASSWORD=admin
)

REM Call the next batch script to handle setting the initial admin password.
REM SCRIPT_DIR is now actually set; previously this expanded to an empty string
REM and only worked when the current directory happened to be the node directory.
CALL "%SCRIPT_DIR%set-initial-admin-password.bat"

REM JVM crash dumps go outside the install directory. Without ErrorFile they land in the
REM JVM's working directory and accumulate there unnoticed.
if "%OSCAR_CRASH_DUMP_DIR%"=="" set "OSCAR_CRASH_DUMP_DIR=%SCRIPT_DIR%logs"
if not exist "%OSCAR_CRASH_DUMP_DIR%" mkdir "%OSCAR_CRASH_DUMP_DIR%"

REM Heap sizing. A fixed 6g request made the node refuse to start on any machine with
REM less than ~8 GB of RAM. Set OSCAR_HEAP (e.g. OSCAR_HEAP=6g) to pin the heap to a
REM specific size; otherwise scale it to a share of installed RAM.
if not "%OSCAR_HEAP%"=="" (
    set "HEAP_OPTS=-Xms%OSCAR_HEAP% -Xmx%OSCAR_HEAP%"
    goto :heap_done
)

if "%OSCAR_HEAP_INITIAL_PERCENT%"=="" set "OSCAR_HEAP_INITIAL_PERCENT=25"
if "%OSCAR_HEAP_MAX_PERCENT%"=="" set "OSCAR_HEAP_MAX_PERCENT=50"

set "MEM_TOTAL_MB="
for /f "usebackq tokens=*" %%M in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "[math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1MB)"`) do set "MEM_TOTAL_MB=%%M"

if "%MEM_TOTAL_MB%"=="" (
    REM Could not determine memory; fall back to a conservative fixed heap.
    set "HEAP_OPTS=-Xms512m -Xmx2048m"
    goto :heap_done
)

set /a HEAP_MAX_MB=%MEM_TOTAL_MB% * %OSCAR_HEAP_MAX_PERCENT% / 100
set /a HEAP_MIN_MB=%MEM_TOTAL_MB% * %OSCAR_HEAP_INITIAL_PERCENT% / 100
if %HEAP_MAX_MB% LSS 1024 set HEAP_MAX_MB=1024
if %HEAP_MIN_MB% LSS 512 set HEAP_MIN_MB=512
set "HEAP_OPTS=-Xms%HEAP_MIN_MB%m -Xmx%HEAP_MAX_MB%m"

:heap_done
echo Heap: %HEAP_OPTS%

REM Start the node.
REM
REM The javax.net.ssl.* properties are deliberately NOT passed as -D flags: SensorHubWrapper
REM reads the KEYSTORE/TRUSTSTORE environment variables above and sets those properties
REM itself, which is the whole reason it exists (it keeps the store passwords out of the
REM process command line). Passing them here both duplicated and defeated that.
java %HEAP_OPTS% -Xss256k -XX:ReservedCodeCacheSize=512m -XX:+UseG1GC ^
    -XX:+HeapDumpOnOutOfMemoryError ^
    -XX:HeapDumpPath="%OSCAR_CRASH_DUMP_DIR%" ^
    -XX:ErrorFile="%OSCAR_CRASH_DUMP_DIR%\hs_err_pid%%p.log" ^
    -Dlogback.configurationFile=./logback.xml ^
    -cp "lib/*" ^
    -Djava.system.class.loader="org.sensorhub.utils.NativeClassLoader" ^
    com.botts.impl.security.SensorHubWrapper config.json db

endlocal
