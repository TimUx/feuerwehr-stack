#!/bin/sh
set -eu

DB_PASSWORD=$(cat /run/secrets/wehrportal_db_password)
APP_KEY=$(cat /run/secrets/wehrportal_app_key)
MAIL_PASSWORD=$(cat /run/secrets/mail_smtp_password)
export DB_PASSWORD APP_KEY MAIL_PASSWORD
# The image does not always run its web server init, which leaves nginx without /etc/nginx/nginx.conf.
if [ ! -f /etc/nginx/nginx.conf ] && [ -f /etc/s6-overlay/scripts/10-init-webserver-config ]; then
  S6_INITIALIZED=true LOG_OUTPUT_LEVEL="${LOG_OUTPUT_LEVEL:-warn}" sh /etc/s6-overlay/scripts/10-init-webserver-config
fi
exec /init "$@"
