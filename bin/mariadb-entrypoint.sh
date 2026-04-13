#!/bin/sh
set -e

# Run logrotate on an hourly loop in the background.
# Logrotate is a no-op when logs are below 10 MB, so checking frequently
# is safe — it simply exits immediately with no action taken.
# $MYSQL_ROOT_PASSWORD is available here as a container environment variable
# and is inherited by the logrotate postrotate shell.
(
    while true; do
        sleep 3600
        /usr/sbin/logrotate /etc/logrotate.d/c2-mariadb
    done
) &

# Hand off to the official MariaDB Docker entrypoint, which handles first-run
# DB initialisation, user creation, and starting mariadbd.
exec docker-entrypoint.sh "$@"
