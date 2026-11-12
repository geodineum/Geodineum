# =============================================================================
# Geodineum Deploy — restarts the deploy user may run without a password
# =============================================================================
# The sweep runs as root from root's crontab and needs none of these. Exact
# commands only: no file copies, no chown/chmod/chattr/tee, no wildcards.
# Rendered for the deploy user by install.sh or scripts/sudoers-refresh.sh.
# =============================================================================

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
