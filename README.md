# c2-wordpress

Production-ready Docker Compose stack for the **Generic Wordpress Single Host* — WordPress (PHP-FPM) + MariaDB + Redis + nginx, deployed on AWS EC2 behind an Application Load Balancer.

---

## Architecture

```
Internet
   │
   ▼
AWS ALB  (TLS termination, HTTPS → HTTP, X-Forwarded-Proto)
   │
   ▼
nginx :80  ──────────────────────────────────┐
   │  real-IP passthrough, static cache,     │
   │  gzip, security headers, /health        │
   ▼                                         │
WordPress PHP-FPM :9000                  wordpress/
   │  redis object cache, WP core             (bind-mount)
   ├──────────────────────────────────────────┘
   ▼
MariaDB :3306         Redis :6379
(mysql_data volume)   (redis_data volume)

Optional (via profile flags):
  --tools → Adminer    :8080  (localhost only)
  --ai    → Qdrant     :6333  (localhost only)
```

All containers share the `c2net` bridge network. Only nginx exposes a public port (`80`). Redis, Adminer, and Qdrant are bound to `127.0.0.1` only.

---

## Services

| Service | Image | Profile | Purpose |
|---------|-------|---------|---------|
| `nginx` | `nginx:<NGINX_VERSION>` + logrotate | core | Reverse proxy, static assets, ALB health check |
| `wordpress` | `wordpress:<WORDPRESS_VERSION>` + redis + calendar | core | PHP-FPM application server |
| `mysql` | `mariadb:<MARIADB_VERSION>` + logrotate | core | Primary database |
| `redis` | `redis:7-alpine` | core | Object cache, transients, sessions |
| `adminer` | `adminer` | `tools` | Web DB admin UI (dev/staging) |
| `qdrant` | `qdrant/qdrant` | `ai` | Vector database for AI-powered search |

---

## Repository Layout

```
c2-wordpress/
├── docker-compose.yml            # Service orchestration
├── start.sh                      # Start stack (supports --tools, --ai flags)
├── stop.sh                       # Stop stack (--wipe deletes all data)
├── .env                          # Secrets & runtime config (git-ignored)
├── env-example                   # Template — copy to .env and fill in values
├── bin/
│   ├── Dockerfile.wordpress      # WordPress + redis (PECL) + calendar extensions
│   ├── Dockerfile.mariadb        # MariaDB + logrotate
│   ├── Dockerfile.nginx          # nginx + logrotate
│   ├── mariadb-entrypoint.sh     # Chains logrotate loop → official entrypoint
│   └── nginx-entrypoint.sh       # Chains logrotate loop → official entrypoint
├── config/
│   ├── mariadb.cnf               # Slow-query log, binary log, InnoDB redo
│   ├── php.conf.ini              # Memory, upload limits, timezone
│   ├── logrotate.mariadb         # Rotate error.log + slow.log at 10 MB
│   └── logrotate.nginx           # Rotate access.log + error.log at 10 MB
├── nginx/
│   └── default.conf              # Vhost: ALB integration, caching, security
├── logs/                         # Created by start.sh (git-ignored)
│   ├── nginx/
│   └── mysql/
├── wordpress/                    # WordPress source & uploads (git-ignored)
└── certs/                        # TLS certs if needed locally (git-ignored)
```

---

## Quick Start

### Prerequisites
- Docker Engine 24+
- Docker Compose v2

### 1. Configure environment

```bash
cp env-example .env
# Edit .env — set passwords, domain, and scheme
```

Key variables:

| Variable | Purpose |
|----------|---------|
| `DB_NAME`, `DB_USER`, `DB_PASSWORD` | Database credentials shared by MariaDB and WordPress (single source of truth) |
| `WORDPRESS_TABLE_PREFIX` | WordPress table prefix |
| `WORDPRESS_SCHEME` | `http` (dev) or `https` (prod behind ALB) |
| `WORDPRESS_DOMAIN` | `localhost` (dev) or `your-domain.com` (prod) |
| `MYSQL_ROOT_PASSWORD` | Separate root password for admin access |
| `REDIS_PASSWORD` | Redis authentication |
| `WORDPRESS_VERSION`, `MARIADB_VERSION`, `NGINX_VERSION` | Pin exact versions for production (no `latest`) |

> **Single source of truth:** `DB_NAME`, `DB_USER`, `DB_PASSWORD` are used by both MariaDB (`MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`) and WordPress (`WORDPRESS_DB_NAME`, `WORDPRESS_DB_USER`, `WORDPRESS_DB_PASSWORD`). No duplication required.

### 2. Start the stack

```bash
# Core stack only (nginx + WordPress + MariaDB + Redis)
./start.sh

# Include DB admin UI
./start.sh --tools

# Include vector DB for AI features
./start.sh --ai

# Everything
./start.sh --tools --ai
```

`start.sh` will:
1. Create `logs/nginx/`, `logs/mysql/`, and `wordpress/` directories
2. Resolve container UIDs from the actual images (no hardcoded IDs)
3. Set correct ownership via a temporary Alpine container (no host `sudo` required)
4. Run `docker compose up -d` with the selected profiles

### 3. Open WordPress

Navigate to `http://localhost` (or your domain). On first run, WordPress will walk through the installation wizard.

---

## Stopping the Stack

```bash
# Stop containers, keep all data
./stop.sh

# Stop containers and DELETE all data (volumes + wordpress/ + logs/)
./stop.sh --wipe
```

`--wipe` runs `docker compose down --volumes` (removes `mysql_data`, `redis_data`, `qdrant_storage`), then uses a privileged Alpine container to wipe the bind-mount directories. A confirmation prompt is shown before any data is deleted.

---

## nginx Configuration

**`nginx/default.conf`** handles:

- **ALB real-IP passthrough** — trusts `X-Forwarded-For` from RFC-1918 ranges so access logs record the actual client IP
- **HTTPS signal** — maps `X-Forwarded-Proto: https` → PHP `$_SERVER['HTTPS']` via `$fastcgi_https`, so WordPress generates correct URLs behind the ALB
- **ALB health check** — `GET /health` returns `200 ok` without logging; required for ALB target-group health
- **Security headers** — `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` (HSTS belongs on the ALB HTTPS listener, not here)
- **Security blocks** — denies `.htaccess`/hidden files, `xmlrpc.php`, `wp-config.php`, PHP execution inside `uploads/`
- **Static asset caching** — `Cache-Control: public, max-age=31536000, immutable` + `Access-Control-Allow-Origin: *` for:
  - Images: `png jpg jpeg gif ico webp svg`
  - Fonts: `woff woff2 ttf eot otf`
  - Scripts & styles: `js css`
  - Audio: `mp3 aac ogg oga wav flac m4a`
  - Video: `mp4 webm ogv mov m4v avi mpg mpeg`
- **Gzip compression** — level 6, min 256 bytes, for text/CSS/JS/SVG/JSON (audio and video are pre-compressed and excluded)
- **Expires map** — `max` for fonts, images, audio, video, JS, CSS; `epoch` for HTML (always revalidate)
- **FastCGI timeouts** — 360 s, aligned with `max_execution_time` in `php.conf.ini`
- **Client max body size** — 256 MB, aligned with `upload_max_filesize` and `post_max_size`

---

## MariaDB Configuration

**`config/mariadb.cnf`** enables:

| Setting | Value | Purpose |
|---------|-------|---------|
| Error log | `/var/log/mysql/error.log` | Captured in `logs/mysql/` |
| Slow query log | threshold 2 s | Identifies unoptimised queries |
| Binary log | ROW format, 10 MB rotate, 7-day expiry | Point-in-time recovery |
| InnoDB redo log | 256 MB | Circular buffer (MariaDB 10.6+) |

Log rotation is handled inside the container by `logrotate` running in a background loop (10 MB threshold, 3 backups, gzip compressed). No host cron required.

---

## PHP Configuration

**`config/php.conf.ini`** sets:

| Setting | Value |
|---------|-------|
| `memory_limit` | `1024M` |
| `upload_max_filesize` | `256M` |
| `post_max_size` | `256M` |
| `max_execution_time` | `360` |
| `date.timezone` | `Europe/Amsterdam` |
| `allow_url_fopen` | `On` |

The WordPress image is extended in `bin/Dockerfile.wordpress` with:
- `redis` (via PECL) — required by the WP Redis / Redis Object Cache plugin
- `calendar` — built-in PHP extension for calendar functions

---

## Log Rotation

Both nginx and MariaDB containers ship with `logrotate` and run it in a background sleep loop (hourly). No host-level cron or external scheduler is needed.

| Service | Files rotated | Trigger | Retention |
|---------|--------------|---------|-----------|
| nginx | `access.log`, `error.log` | 10 MB | 3 backups |
| MariaDB | `error.log`, `slow.log` | 10 MB | 3 backups |

Rotated logs are gzip-compressed with date-extended filenames (`YYYYMMDD`).

---

## AWS Deployment Notes

- **TLS** — Terminate HTTPS on the ALB using an ACM certificate. nginx only needs to listen on port 80 within the VPC.
- **HSTS** — Set via the ALB HTTPS listener's response-header policy, not in nginx config.
- **Health check** — Configure the ALB target group to probe `GET /health` (HTTP 200 expected).
- **Secrets** — Use AWS Secrets Manager or Parameter Store for `*_PASSWORD` and `MYSQL_ROOT_PASSWORD` values; inject at task/instance start.
- **Scheme** — Set `WORDPRESS_SCHEME=https` in `.env` (or via environment injection) so WordPress generates `https://` URLs and keeps sessions valid.
- **Restart policy** — All core containers use `restart: unless-stopped`, which survives EC2 reboots.
- **Logging** — All containers use the `json-file` driver capped at 10 MB × 3 files to prevent unbounded disk growth.

---

## Development Workflow

```bash
# Reload nginx config without restarting
docker compose exec nginx nginx -s reload

# Tail nginx logs
docker compose logs -f nginx

# Connect to MariaDB
docker compose exec mysql mariadb -u root -p

# Connect to Redis CLI
docker compose exec redis redis-cli -a "$REDIS_PASSWORD"

# Inspect PHP config
docker compose exec wordpress php -i | grep memory_limit

# Full stack wipe and fresh install
./stop.sh --wipe && ./start.sh
```

---

## License

GNU General Public License v3 — see [LICENSE](LICENSE).
