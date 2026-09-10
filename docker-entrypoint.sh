#!/bin/sh
set -eu

# Named volumes and bind mounts can be created as root on the host. Repair their
# ownership before dropping privileges for the Traccar process.
chown -R traccar:traccar /opt/traccar/logs /opt/traccar/data

# The first argument is the existing Dockerfile CMD when no command is given.
# Keep the Java executable and JVM flags outside the user-controlled arguments.
exec su -p -s /bin/sh traccar -c \
    'exec /opt/traccar/jre/bin/java -XX:+ExitOnOutOfMemoryError "$@"' \
    -- traccar "$@"
