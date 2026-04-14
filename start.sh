#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start.sh — Start the c2-wordpress Docker stack
#
# Usage:
#   ./start.sh              Core stack only (mysql, wordpress, nginx, redis)
#   ./start.sh --tools      + adminer  (DB admin UI — dev/staging only)
#   ./start.sh --ai         + qdrant   (vector DB — when AI features enabled)
#   ./start.sh --tools --ai Full stack (all services)
#   ./start.sh --all        Alias for --tools --ai
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Check Docker availability ─────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed or not in PATH."
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running."
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: docker compose plugin is not available."
    exit 1
fi

# ── Parse profile flags ──────────────────────────────────────────────────────
PROFILE_ARGS=""
DRY_RUN=false
FORCE=false
for arg in "$@"; do
    case $arg in
        --tools)   PROFILE_ARGS="$PROFILE_ARGS --profile tools" ;;
        --ai)      PROFILE_ARGS="$PROFILE_ARGS --profile ai"    ;;
        --all)     PROFILE_ARGS="--profile tools --profile ai"  ;;
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--tools] [--ai] [--all] [--dry-run] [--force]"
            exit 1
            ;;
    esac
done

# ── Load env vars from .env ───────────────────────────────────────────────────
# shellcheck source=/dev/null
[ -f .env ] && . .env

# ── Validate versions (fail fast on 'latest' in production) ──────────────────
validate_version() {
    local var_name="$1"
    local var_value="$2"
    local env="${3:-}"

    if [ "$var_value" = "latest" ]; then
        echo "ERROR: $var_name is set to 'latest'. Pin an exact version in .env"
        echo "  e.g. $var_name=6.9.4-php8.3-fpm"
        [ -n "$env" ] && echo "  See $env for pinned versions."
        exit 1
    fi
}

MARIADB_VERSION="${MARIADB_VERSION:-latest}"
WORDPRESS_VERSION="${WORDPRESS_VERSION:-latest}"
NGINX_VERSION="${NGINX_VERSION:-latest}"

validate_version "WORDPRESS_VERSION" "$WORDPRESS_VERSION" "env-example"
validate_version "MARIADB_VERSION" "$MARIADB_VERSION" "env-example"
validate_version "NGINX_VERSION" "$NGINX_VERSION" "env-example"

# ── Helper: look up a user's uid inside a Docker image ───────────────────────
# Usage: image_uid IMAGE USERNAME
# Pulls the image if needed (Docker caches it), runs `id -u`, returns the uid.
image_uid() {
    local uid
    for attempt in {1..3}; do
        if uid=$(docker run --rm "$1" id -u "$2" 2>/dev/null); then
            echo "$uid"
            return 0
        fi
        echo "Attempt $attempt failed for $1 $2, retrying in 1s..." >&2
        sleep 1
    done
    echo "Failed to get UID for $2 in $1 after 3 attempts" >&2
    return 1
}

# ── Helper: check if directory is owned by expected uid ──────────────────────
# Usage: check_owner UID HOSTPATH
check_owner() {
    local expected_uid="$1"
    local dir="$2"
    local actual_uid
    actual_uid=$(stat -f %u "$dir" 2>/dev/null || echo "unknown")
    [ "$actual_uid" = "$expected_uid" ]
}

# ── Helper: apply uid ownership to a host directory via Alpine ───────────────
# Usage: set_owner UID HOSTPATH
# Runs a throwaway Alpine container as root to chown the bind-mount.
# No host sudo required.
set_owner() {
    docker run --rm -v "${2}:/mnt" alpine chown -R "${1}:${1}" /mnt
}

# ── Create directories ───────────────────────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    echo "Would create directories: logs/nginx logs/mysql wordpress"
else
    mkdir -p logs/nginx/
    mkdir -p logs/mysql/
    mkdir -p wordpress/
fi

# ── Fix bind-mount ownership for each service ────────────────────────────────
# Ownership is resolved dynamically from the actual image so it stays correct
# across image updates and works on any EC2 AMI regardless of which system
# accounts happen to own uid N on the host.

echo "Resolving container user IDs..."

# MariaDB — mysql user writes error.log and slow.log
# logrotate runs inside the container (see bin/Dockerfile.mariadb),
# so only ownership of the bind-mount needs to be set here.
MYSQL_UID=$(image_uid "c2-mariadb:${MARIADB_VERSION}" mysql 2>/dev/null \
    || image_uid "mariadb:${MARIADB_VERSION}" mysql)
if [ -z "$MYSQL_UID" ]; then
    echo "ERROR: Failed to resolve UID for mysql user in MariaDB image"
    exit 1
fi
echo "  mariadb:${MARIADB_VERSION}   mysql     → uid ${MYSQL_UID}"
if [ "$DRY_RUN" = true ]; then
    echo "  Would set ownership of $(pwd)/logs/mysql to $MYSQL_UID"
elif [ "$FORCE" = false ] && check_owner "$MYSQL_UID" "$(pwd)/logs/mysql"; then
    echo "  Ownership of $(pwd)/logs/mysql is already correct"
else
    set_owner "$MYSQL_UID" "$(pwd)/logs/mysql"
fi

# nginx — nginx user writes access.log and error.log
# logrotate for nginx runs inside the container (see bin/Dockerfile.nginx),
# so only ownership of the bind-mount needs to be set here.
NGINX_UID=$(image_uid "c2-nginx:${NGINX_VERSION}" nginx 2>/dev/null \
    || image_uid "nginx:${NGINX_VERSION}" nginx)
if [ -z "$NGINX_UID" ]; then
    echo "ERROR: Failed to resolve UID for nginx user in Nginx image"
    exit 1
fi
echo "  nginx:${NGINX_VERSION}       nginx     → uid ${NGINX_UID}"
if [ "$DRY_RUN" = true ]; then
    echo "  Would set ownership of $(pwd)/logs/nginx to $NGINX_UID"
elif [ "$FORCE" = false ] && check_owner "$NGINX_UID" "$(pwd)/logs/nginx"; then
    echo "  Ownership of $(pwd)/logs/nginx is already correct"
else
    set_owner "$NGINX_UID" "$(pwd)/logs/nginx"
fi

# WordPress — www-data (PHP-FPM worker) writes uploads, cache, plugin files.
# We query the upstream wordpress image (same base as our custom build) so
# this works even before `docker compose build` has run.
# Only chown on first install — skipped when the directory is already
# populated to avoid a slow recursive chown over the entire WordPress tree.
WP_UID=$(image_uid "wordpress:${WORDPRESS_VERSION}" www-data)
if [ -z "$WP_UID" ]; then
    echo "ERROR: Failed to resolve UID for www-data user in WordPress image"
    exit 1
fi
echo "  wordpress:${WORDPRESS_VERSION} www-data  → uid ${WP_UID}"
if [ "$DRY_RUN" = true ]; then
    if [ -z "$(ls -A wordpress/ 2>/dev/null)" ]; then
        echo "  Would set ownership of $(pwd)/wordpress to $WP_UID (empty directory)"
    elif [ "$FORCE" = false ] && check_owner "$WP_UID" "$(pwd)/wordpress"; then
        echo "  Ownership of $(pwd)/wordpress is already correct"
    else
        echo "  Would set ownership of $(pwd)/wordpress to $WP_UID"
    fi
elif [ "$FORCE" = true ] || [ -z "$(ls -A wordpress/ 2>/dev/null)" ] || ! check_owner "$WP_UID" "$(pwd)/wordpress"; then
    echo "  Setting ownership of $(pwd)/wordpress to $WP_UID"
    set_owner "$WP_UID" "$(pwd)/wordpress"
else
    echo "  wordpress/ already populated and owned correctly — skipping chown."
fi

# ── Start services ───────────────────────────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    echo "Would run: docker compose $PROFILE_ARGS up -d"
else
    echo "Starting stack${PROFILE_ARGS:+ (profiles:$PROFILE_ARGS)}..."
    # shellcheck disable=SC2086
    docker compose $PROFILE_ARGS up -d
fi
