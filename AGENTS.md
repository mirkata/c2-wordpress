# c2-wordpress — Agent Guide

## Stack Management

- **Always use `./start.sh` and `./stop.sh`** — they handle UID ownership resolution, directory creation, and profile selection. Do not run `docker compose` directly.
- **Profiles**: `--tools` (Adminer), `--ai` (Qdrant). Default: core only.
- **`--wipe` is destructive**: removes all volumes and data directories. Requires `Y` confirmation.

```bash
./start.sh              # Core stack
./start.sh --tools      # + Adminer (DB admin UI)
./start.sh --ai         # + Qdrant (vector DB)
./start.sh --all        # Everything
./start.sh --dry-run    # Preview actions without executing
./start.sh --force      # Skip ownership checks if directories are already owned correctly

./stop.sh               # Stop, keep data
./stop.sh --wipe        # Stop + delete all data
```

## Database Configuration

Use `DB_NAME`, `DB_USER`, `DB_PASSWORD` in `.env` — they are used by both MariaDB and WordPress (single source of truth). `MYSQL_ROOT_PASSWORD` is separate for admin access.

## AWS Deployment

- TLS terminates on ALB (not in nginx). Set `WORDPRESS_SCHEME=https`.
- ALB health check probes `GET /health` (returns `200 ok`).
- nginx listens on port 80 only; do not add TLS config to `nginx/default.conf`.
- HSTS belongs on ALB HTTPS listener, not in nginx.

## Development Workflow

```bash
# Reload nginx config without restart
docker compose exec nginx nginx -s reload

# Tail logs
docker compose logs -f nginx
docker compose logs -f mysql

# Connect to services
docker compose exec mysql mysql -u root -p
docker compose exec redis redis-cli -a "$REDIS_PASSWORD"
docker compose exec wordpress php -i | grep memory_limit

# Reset stack
./stop.sh --wipe && ./start.sh
```

## Important Notes

- **Do not hardcode UIDs** — `start.sh` resolves them dynamically from images. The bind-mount directories are chowned via Alpine containers, no host `sudo` required.
- **Log rotation is inside containers** — logrotate runs in a background loop inside nginx and MariaDB containers. No host cron needed.
- **Redis is bound to 127.0.0.1** — not exposed publicly.
- WordPress uses Redis object cache via `WP_REDIS_*` constants defined in `docker-compose.yml`.
- **Pin versions in production** — `start.sh` fails fast if `WORDPRESS_VERSION`, `MARIADB_VERSION`, or `NGINX_VERSION` are set to `latest`. See `env-example` for pinned versions.
- **mu-plugins are baked into the image** — `mu-plugins/*.php` are copied into the WordPress image at build time and auto-copied to the host volume on first run. They persist across `--wipe`.

## File Locations

| Path | Purpose |
|------|---------|
| `config/php.conf.ini` | PHP memory, upload, timezone settings |
| `config/mariadb.cnf` | DB slow-query log, binary log, InnoDB redo |
| `nginx/default.conf` | Reverse proxy, caching, security headers |
| `bin/Dockerfile.*` | Custom container images (Redis PECL, logrotate) |
| `mu-plugins/` | Must-use plugins (baked into image, persists after wipe) |
