# =============================================================================
# Geodineum Deploy — Scoped sudo for auto-deploy cron
# =============================================================================
# Minimum privilege per operation, no blanket sudo.
# Rendered for the deploy user by install.sh or scripts/sudoers-refresh.sh.
# =============================================================================

# --- Service management (restart only, not stop/enable/disable) ---
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/systemctl restart gnode-daemon
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/systemctl restart geodineum-comms
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/systemctl restart php8.3-fpm
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/systemctl reload php8.3-fpm
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/systemctl restart php8.4-fpm
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/systemctl reload php8.4-fpm
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/systemctl restart php8.5-fpm
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/systemctl reload php8.5-fpm
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/systemctl reload apache2
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/systemctl daemon-reload

# --- Service file installation ---
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/cp /opt/geodineum/gNode/daemon/config/*.service /etc/systemd/system/
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/cp /opt/geodineum/Geodineum-COMMS/config/*.service /etc/systemd/system/

# --- Permission fixes: chown to correct owner:group per component ---
# Daemon components ({{DEPLOY_USER}}:gnode)
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:gnode /opt/geodineum/gNode
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:gnode /opt/geodineum/gNode/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:gnode /opt/geodineum/Geodineum-COMMS
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:gnode /opt/geodineum/Geodineum-COMMS/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:gnode /opt/geodineum/Geodineum-BAK
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:gnode /opt/geodineum/Geodineum-BAK/*
# The deploy repo itself (its descriptor declares group geodineum)
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum /opt/geodineum/Geodineum
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum /opt/geodineum/Geodineum/*

# PHP components: each rule must match the owner:group+path its geodeploy.yaml
# declares; both groups are granted so template and descriptor may differ.
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum-code /opt/geodineum/gCore
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum-code /opt/geodineum/gCore/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum-code /opt/geodineum/gTemplate
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum-code /opt/geodineum/gTemplate/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum-code /opt/geodineum/gCube
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum-code /opt/geodineum/gCube/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum-code /opt/geodineum/gNode-Client
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum-code /opt/geodineum/gNode-Client/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:www-data /opt/geodineum/gCore
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:www-data /opt/geodineum/gCore/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:www-data /opt/geodineum/gTemplate
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:www-data /opt/geodineum/gTemplate/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:www-data /opt/geodineum/gCube
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:www-data /opt/geodineum/gCube/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:www-data /opt/geodineum/gNode-Client
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:www-data /opt/geodineum/gNode-Client/*

# Config directory (gnode:geodineum — never touch individual credential files)
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown gnode\:geodineum /etc/geodineum
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R gnode\:geodineum /etc/geodineum/components
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown gnode\:geodineum /etc/geodineum/credentials
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R gnode\:geodineum /etc/geodineum/sites
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:geodineum /etc/geodineum
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:geodineum /etc/geodineum/services
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown gnode\:geodineum /etc/geodineum/bootstrap.env
# A component running under its own identity must read its own env file;
# the components/ default (gnode:geodineum) locks its service user out.
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:geodineum-comms /etc/geodineum/components/geodineum-comms/geodineum-comms.env
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chmod 0640 /etc/geodineum/components/geodineum-comms/geodineum-comms.env

# Web-deny files (root:geodineum)
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:geodineum /opt/geodineum/*/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:geodineum /opt/geodineum/*/nginx-deny.conf

# Log directory (centralized: /var/log/geodineum/)
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:geodineum /var/log/geodineum
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chmod 750 /var/log/geodineum
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R gnode\:geodineum /var/log/geodineum/gnode
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R gnode\:geodineum /var/log/geodineum/valkey
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R geodineum-comms\:geodineum /var/log/geodineum/comms
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:geodineum /var/log/geodineum/gcore
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:geodineum /var/log/geodineum/apache
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:geodineum /var/log/geodineum/wordpress
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:geodineum /var/log/geodineum/themes
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:geodineum /var/log/geodineum/deploy
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:geodineum /opt/geodineum

# BAK writable directories (gnode:gnode — backup service writes)
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R gnode\:gnode /opt/geodineum/Geodineum-BAK/backups
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R gnode\:gnode /opt/geodineum/Geodineum-BAK/logs

# WordPress site hardening ({{DEPLOY_USER}}:www-data source, www-data:www-data writable dirs)
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R {{DEPLOY_USER}}\:www-data /var/www/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown {{DEPLOY_USER}}\:www-data /var/www/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chmod 750 /var/www/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:www-data /var/www/*/wp-content/uploads
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:www-data /var/www/*/wp-content/cache
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:www-data /var/www/*/wp-content/upgrade
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:www-data /var/www/*/wp-content/wflogs
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:www-data /var/www/*/wp-content/gcore-logs
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:www-data /var/www/*/public_html/wp-content/uploads
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:www-data /var/www/*/public_html/wp-content/cache
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:www-data /var/www/*/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:www-data /var/www/*/wp-content/uploads/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:www-data /var/www/*/wp-content/cache/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chown root\:www-data /var/www/*/wp-content/gcore-logs/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chattr +i /var/www/*/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chattr -i /var/www/*/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chattr +i /var/www/*/wp-content/uploads/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chattr -i /var/www/*/wp-content/uploads/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chattr +i /var/www/*/wp-content/cache/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chattr -i /var/www/*/wp-content/cache/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chattr +i /var/www/*/wp-content/gcore-logs/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chattr -i /var/www/*/wp-content/gcore-logs/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/tee /var/www/*/wp-content/uploads/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/tee /var/www/*/wp-content/cache/.htaccess
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/tee /var/www/*/wp-content/gcore-logs/.htaccess

# chmod on /etc/geodineum (set directory/file perms)
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chmod 750 /etc/geodineum
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chmod 750 /etc/geodineum/*
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chmod 750 /opt/geodineum
# 751 lets www-data traverse to theme and credential symlinks
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chmod 751 /opt/geodineum
{{DEPLOY_USER}} ALL=(root) NOPASSWD: /usr/bin/chmod 751 /opt/geodineum/gNode
