#!/bin/sh
set -eu

read_secret() {
  cat "$1"
}

create_role_and_database() {
  role=$1
  database=$2
  secret_path=$3
  psql \
    --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    --set=db_user="$role" --set=db_password="$(read_secret "$secret_path")" \
    --set=db_name="$database" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'db_user') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db_name') \gexec
SQL
}

create_role_and_database keycloak keycloak "$KEYCLOAK_DB_PASSWORD_FILE"
create_role_and_database wehrportal wehrportal "$WEHRPORTAL_DB_PASSWORD_FILE"
create_role_and_database synapse synapse "$SYNAPSE_DB_PASSWORD_FILE"
