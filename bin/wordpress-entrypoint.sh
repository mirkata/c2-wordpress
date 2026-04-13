#!/bin/bash
set -e

# Monitor for WordPress installation and copy mu-plugins
copy_mu_plugins_loop() {
    local max_wait=60
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        if [ -d /var/www/html/wp-content ] && [ -f /var/www/html/wp-load.php ]; then
            if [ -d /usr/src/wordpress/wp-content/mu-plugins ]; then
                mkdir -p /var/www/html/wp-content/mu-plugins
                cp /usr/src/wordpress/wp-content/mu-plugins/*.php /var/www/html/wp-content/mu-plugins/ 2>/dev/null || true
            fi
            break
        fi
        sleep 1
        ((waited++))
    done
}

copy_mu_plugins_loop &

exec /usr/local/bin/docker-entrypoint.sh "$@"