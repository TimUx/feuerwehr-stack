#!/bin/sh
set -eu

read_secret() {
  cat "$1"
}

create_role_and_database() {
  role=$1
  database=$2
  secret_path=$3
  db_options=${4:-}
  psql \
    -X --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    --set=db_user="$role" --set=db_password="$(read_secret "$secret_path")" \
    --set=db_name="$database" --set=db_options="$db_options" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'db_user') \gexec
SELECT format('CREATE DATABASE %I OWNER %I %s', :'db_name', :'db_user', :'db_options')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db_name') \gexec
SQL
}

create_role_and_database keycloak keycloak "$KEYCLOAK_DB_PASSWORD_FILE"
create_role_and_database wehrportal wehrportal "$WEHRPORTAL_DB_PASSWORD_FILE"
# Synapse requires C collation
create_role_and_database synapse synapse "$SYNAPSE_DB_PASSWORD_FILE" \
  "TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C'"
create_role_and_database drupal drupal "$DRUPAL_DB_PASSWORD_FILE"
psql -X --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname drupal \
  -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm'
