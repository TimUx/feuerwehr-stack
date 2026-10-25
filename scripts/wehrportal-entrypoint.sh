#!/bin/sh
set -eu

DB_PASSWORD=$(cat /run/secrets/wehrportal_db_password)
APP_KEY=$(cat /run/secrets/wehrportal_app_key)
MAIL_PASSWORD=$(cat /run/secrets/mail_smtp_password)
export DB_PASSWORD APP_KEY MAIL_PASSWORD
exec docker-php-serversideup-entrypoint "$@"
