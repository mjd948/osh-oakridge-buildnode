#!/bin/bash

# Make sure all the necessary certificates are trusted by the system.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
"$SCRIPT_DIR/load_trusted_certs.sh"

 export KEYSTORE="./osh-keystore.p12"
 export KEYSTORE_TYPE=PKCS12
 export KEYSTORE_PASSWORD="atakatak"

  export TRUSTSTORE="./truststore.jks"
  export TRUSTSTORE_TYPE=JKS
  export TRUSTSTORE_PASSWORD="changeit"
  export INITIAL_ADMIN_PASSWORD_FILE="./.s"


# After copying the default configuration file, also look to see if they
# specified what they want the initial admin user's password to be, either
# as a secret file or by providing it as an environment variable.
if [ -z "$INITIAL_ADMIN_PASSWORD_FILE" ] && [ -z "$INITIAL_ADMIN_PASSWORD" ]; then
  export INITIAL_ADMIN_PASSWORD=admin
fi
"$SCRIPT_DIR/set-initial-admin-password.sh"



# JVM crash dumps go outside the install directory. Without ErrorFile they land in the
# JVM's working directory (osh-node-oscar) and accumulate there unnoticed.
CRASH_DUMP_DIR="${OSCAR_CRASH_DUMP_DIR:-/var/log/oscar}"
mkdir -p "$CRASH_DUMP_DIR"
# Dumps are named per-PID, so nothing overwrites anything; age them out instead.
find "$CRASH_DUMP_DIR" -maxdepth 1 -name 'hs_err_pid*.log' -mtime +14 -delete 2>/dev/null || true

# Start the node
java -Xms6g -Xmx6g -Xss256k -XX:ReservedCodeCacheSize=512m -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError \
	-XX:ErrorFile="$CRASH_DUMP_DIR/hs_err_pid%p.log" \
	-Dlogback.configurationFile=./logback.xml \
	-cp "lib/*" \
	-Djava.system.class.loader="org.sensorhub.utils.NativeClassLoader" \
	-Djavax.net.ssl.keyStore="./osh-keystore.p12" \
	-Djavax.net.ssl.keyStorePassword="atakatak" \
	-Djavax.net.ssl.trustStore="$SCRIPT_DIR/trustStore.jks" \
	-Djavax.net.ssl.trustStorePassword="changeit" \
	-Djava.library.path="./nativelibs" \
	com.botts.impl.security.SensorHubWrapper ./config.json ./db
