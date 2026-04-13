#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# stop.sh — Stop and optionally wipe the c2-wordpress Docker stack
#
# Usage:
#   ./stop.sh         Stop all containers (data preserved)
#   ./stop.sh --wipe  Stop containers AND delete all data volumes and log files
#
# --wipe removes: named volumes (mysql_data, redis_data, qdrant_storage),
#                 bind-mount data (wordpress/, logs/), and unused networks.
#                 This is irreversible — use only to fully reset the environment.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

WIPE=false
for arg in "$@"; do
    case $arg in
        --wipe) WIPE=true ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--wipe]"
            exit 1
            ;;
    esac
done

# Stop all services regardless of which profiles are active
echo "INFO: Stopping all containers..."
docker compose --profile tools --profile ai stop

if [ "$WIPE" = true ]; then
    read -rp "This will permanently delete all data. Are you sure? (Y/N) " answer
    if [ "${answer}" != "Y" ]; then
        echo "INFO: Aborted. Containers are stopped but data is intact."
        exit 0
    fi

    echo "INFO: Removing containers, named volumes (mysql_data, redis_data, qdrant_storage) and networks..."
    docker compose --profile tools --profile ai down --volumes

    echo "INFO: Removing data directories (logs/nginx/ logs/mysql/ wordpress/)..."
    # Run as root inside Alpine — avoids sudo for files owned by container users
    # (www-data uid 33, mysql uid 999, etc). Deletes the directories entirely,
    # then recreates them empty and owned by the current host user.
    docker run --rm \
        -v "$(pwd):/clean" \
        alpine sh -c '
            rm -rf /clean/logs/nginx /clean/logs/mysql /clean/wordpress
            mkdir -p /clean/logs/nginx /clean/logs/mysql /clean/wordpress
            chown -R '"$(id -u):$(id -g)"' /clean/logs /clean/wordpress
        '

    echo "INFO: Done. All data has been removed."
else
    echo "INFO: Containers stopped. Data and volumes are preserved."
    echo "INFO: Run './stop.sh --wipe' to also delete all data."
fi
