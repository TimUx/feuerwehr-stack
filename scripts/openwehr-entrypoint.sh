#!/bin/sh
set -eu

DB_PASSWORD=$(cat /run/secrets/openwehr_db_password)
APP_KEY=$(cat /run/secrets/openwehr_app_key)
MAIL_PASSWORD=$(cat /run/secrets/mail_smtp_password)
export DB_PASSWORD APP_KEY MAIL_PASSWORD
exec /init "$@"
