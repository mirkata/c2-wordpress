#!/bin/sh
set -e

# Run logrotate on an hourly loop in the background.
# Logrotate is a no-op when logs are below 10 MB, so checking frequently
# is safe — it simply exits immediately with no action taken.
# Using a shell loop avoids any dependency on a cron daemon, which can be
# unreliable inside containers due to PID namespace and /run constraints.
(
    while true; do
        sleep 3600
        /usr/sbin/logrotate /etc/logrotate.d/c2-nginx
    done
) &

# Hand off to the standard nginx Docker entrypoint, which processes any
# /docker-entrypoint.d/ scripts before exec-ing nginx.
exec /docker-entrypoint.sh "$@"
