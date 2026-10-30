#!/usr/bin/env bash
# Opt-in container integration: isolated network, no published host ports.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp=$(mktemp -d)
name="fw-drupal-test-$$"
RUN_WEHRPORTAL_INTEGRATION=${RUN_WEHRPORTAL_INTEGRATION:-false}
RUN_MATRIX_INTEGRATION=${RUN_MATRIX_INTEGRATION:-false}
RUN_OFFICE_INTEGRATION=${RUN_OFFICE_INTEGRATION:-false}
containers=()
cleanup() {
  local result=$? container
  if ((result != 0)); then
    for container in "${containers[@]}"; do docker logs --tail 60 "$container" 2>&1 || true; done
  fi
  docker run --rm --entrypoint chmod -v "$tmp:/cleanup" feuerwehr/drupal:11.4.11-1 \
    -R a+rwX /cleanup/files /cleanup/private /cleanup/matrix >/dev/null
  for container in "${containers[@]}"; do docker rm -f "$container" >/dev/null || true; done
  docker network rm "$name" >/dev/null
  rm -rf -- "$tmp"
  return "$result"
}
trap cleanup EXIT
docker network create "$name" >/dev/null
docker build -q -t feuerwehr/drupal:11.4.11-1 "$ROOT/drupal" >/dev/null
chmod 0755 "$tmp"
mkdir -p "$tmp/secrets" "$tmp/files" "$tmp/private" "$tmp/matrix"
for secret in drupal_db_password drupal_hash_salt drupal_admin_password drupal_oidc_client_secret \
  keycloak_admin_password keycloak_db_password wehrportal_db_password synapse_db_password wehrportal_oidc_client_secret synapse_oidc_client_secret; do
  printf 'test-only-integration\n' > "$tmp/secrets/$secret"
done
printf 'test-only-synapse-oidc\n' > "$tmp/secrets/synapse_oidc_client_secret"
printf 'test-only-onlyoffice-jwt-secret-at-least-32-characters\n' > "$tmp/secrets/onlyoffice_jwt_secret"
printf 'base64:%s\n' "$(openssl rand -base64 32)" > "$tmp/secrets/wehrportal_app_key"
: > "$tmp/secrets/mail_smtp_password"
cat > "$tmp/.env" <<'EOF'
KEYCLOAK_HOST=login.stack.test
KEYCLOAK_REALM=feuerwehr
KEYCLOAK_ADMIN_USER=kcadmin
DRUPAL_HOST=site.stack.test
DRUPAL_OIDC_ENABLED=true
WEHRPORTAL_HOST=portal.stack.test
MATRIX_HOST=matrix.stack.test
EOF
if [[ "$RUN_WEHRPORTAL_INTEGRATION" == true ]]; then
  printf 'WEHRPORTAL_OIDC_ENABLED=true\n' >> "$tmp/.env"
fi
if [[ "$RUN_MATRIX_INTEGRATION" == true ]]; then
  printf 'MATRIX_OIDC_ENABLED=true\n' >> "$tmp/.env"
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$tmp/key.pem" \
  -out "$tmp/cert.pem" -subj '/CN=login.stack.test' \
  -addext 'subjectAltName=DNS:login.stack.test,DNS:site.stack.test,DNS:portal.stack.test,DNS:matrix.stack.test,DNS:chat.stack.test,DNS:docs.stack.test' >/dev/null 2>&1
containers+=("$name-pg")
docker run -d --name "$name-pg" --network "$name" --network-alias postgres \
  -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres -e POSTGRES_PASSWORD=test-only-integration \
  -e KEYCLOAK_DB_PASSWORD_FILE=/run/secrets/keycloak_db_password \
  -e WEHRPORTAL_DB_PASSWORD_FILE=/run/secrets/wehrportal_db_password \
  -e SYNAPSE_DB_PASSWORD_FILE=/run/secrets/synapse_db_password \
  -e DRUPAL_DB_PASSWORD_FILE=/run/secrets/drupal_db_password \
  -v "$tmp/secrets:/run/secrets:ro" \
  -v "$ROOT/scripts/postgres-init.sh:/docker-entrypoint-initdb.d/10-feuerwehr-users.sh:ro" \
  postgres:18-alpine >/dev/null
for ((i = 0; i < 60; i++)); do
  docker exec "$name-pg" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && break
  sleep 2
done
docker exec "$name-pg" sh /docker-entrypoint-initdb.d/10-feuerwehr-users.sh >/dev/null
docker exec "$name-pg" psql -U drupal -d drupal -c 'CREATE TABLE protected_content (id integer)' >/dev/null
if docker run --rm --network "$name" -e DRUPAL_HOST=site.stack.test \
  -e DRUPAL_ADMIN_EMAIL=admin@stack.test -v "$tmp/secrets:/run/secrets:ro" \
  feuerwehr/drupal:11.4.11-1 true > "$tmp/install-guard.log" 2>&1; then
  echo "Drupal accepted a non-empty, unrelated database." >&2
  exit 1
fi
if ! grep -q 'Refusing to install Drupal into a non-empty database' "$tmp/install-guard.log"; then
  cat "$tmp/install-guard.log" >&2
  exit 1
fi
docker exec "$name-pg" psql -U drupal -d drupal -c 'DROP TABLE protected_content' >/dev/null
if [[ "$RUN_MATRIX_INTEGRATION" == true ]]; then
  containers+=("$name-synapse")
  docker run -d --restart on-failure --name "$name-synapse" --network "$name" --network-alias synapse \
    -e SYNAPSE_SERVER_NAME=identity.stack.test -e SYNAPSE_REPORT_STATS=no -e UID=991 -e GID=991 \
    -e MATRIX_HOST=matrix.stack.test -e FLUFFYCHAT_HOST=chat.stack.test -e MATRIX_OIDC_ENABLED=true \
    -e KEYCLOAK_HOST=login.stack.test -e KEYCLOAK_REALM=feuerwehr -e SSL_CERT_FILE=/test/cert.pem \
    -v "$ROOT/scripts/synapse-entrypoint.sh:/stack/synapse-entrypoint.sh:ro" \
    -v "$ROOT/tests:/tests:ro" -v "$tmp:/test:ro" \
    -v "$ROOT/scripts/configure-synapse.py:/stack/configure_synapse.py:ro" \
    -v "$tmp/matrix:/data" -v "$tmp/secrets:/run/secrets:ro" \
    --entrypoint /bin/sh matrixdotorg/synapse:latest /stack/synapse-entrypoint.sh >/dev/null
fi
if [[ "$RUN_WEHRPORTAL_INTEGRATION" == true ]]; then
  containers+=("$name-redis")
  docker run -d --name "$name-redis" --network "$name" --network-alias redis redis:latest >/dev/null
  containers+=("$name-portal")
  docker run -d --name "$name-portal" --network "$name" --network-alias portal \
    -e APP_ENV=production -e APP_DEBUG=false -e APP_URL=https://portal.stack.test \
    -e APP_LOCALE=de -e ADMIN_EMAILS=admin@stack.test -e SESSION_SECURE_COOKIE=true \
    -e DB_CONNECTION=pgsql -e DB_HOST=postgres -e DB_DATABASE=wehrportal -e DB_USERNAME=wehrportal \
    -e CACHE_STORE=redis -e REDIS_HOST=redis -e SESSION_DRIVER=database -e QUEUE_CONNECTION=sync \
    -e MAIL_MAILER=log -e LOG_CHANNEL=stderr -e OIDC_ENABLED=true \
    -e WEHRPORTAL_HOST=portal.stack.test -e KEYCLOAK_HOST=login.stack.test -e KEYCLOAK_REALM=feuerwehr \
    -e ONLYOFFICE_HOST=docs.stack.test \
    -v "$ROOT/scripts:/stack:ro" -v "$ROOT/tests:/tests:ro" -v "$tmp:/test:ro" \
    -v "$tmp/secrets:/run/secrets:ro" \
    -v "$ROOT/tests/fixtures/StackTest:/var/www/html/extensions/StackTest:ro" \
    --entrypoint /bin/sh ghcr.io/timux/wehrportal:latest /stack/wehrportal-entrypoint.sh /init >/dev/null
fi
if [[ "$RUN_OFFICE_INTEGRATION" == true ]]; then
  containers+=("$name-onlyoffice")
  docker run -d --name "$name-onlyoffice" --network "$name" --network-alias onlyoffice \
    -e JWT_HEADER=Authorization -e NODE_EXTRA_CA_CERTS=/test/cert.pem \
    -e ALLOW_PRIVATE_IP_ADDRESS=true \
    -v "$ROOT/scripts/onlyoffice-entrypoint.sh:/stack/onlyoffice-entrypoint.sh:ro" \
    -v "$tmp:/test:ro" -v "$tmp/secrets:/run/secrets:ro" \
    --entrypoint /bin/bash onlyoffice/documentserver:latest /stack/onlyoffice-entrypoint.sh >/dev/null
fi
containers+=("$name-keycloak")
docker run -d --name "$name-keycloak" --network "$name" --network-alias keycloak \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=kcadmin -e KC_BOOTSTRAP_ADMIN_PASSWORD=test-only-integration \
  -e KC_HOSTNAME=https://login.stack.test -e KC_PROXY_HEADERS=xforwarded \
  quay.io/keycloak/keycloak:26.6.1 start-dev >/dev/null
containers+=("$name-drupal")
docker run -d --name "$name-drupal" --network "$name" --network-alias drupal \
  -e DRUPAL_HOST=site.stack.test -e DRUPAL_ADMIN_EMAIL=admin@stack.test \
  -e DRUPAL_OIDC_ENABLED=true -e KEYCLOAK_HOST=login.stack.test -e KEYCLOAK_REALM=feuerwehr \
  -v "$tmp/secrets:/run/secrets:ro" -v "$tmp/files:/opt/drupal/web/sites/default/files" \
  -v "$tmp/private:/var/drupal/private" feuerwehr/drupal:11.4.11-1 >/dev/null
cat > "$tmp/nginx.conf" <<'EOF'
events {}
http {
  server {
    listen 443 ssl;
    server_name login.stack.test;
    ssl_certificate /test/cert.pem;
    ssl_certificate_key /test/key.pem;
    location / {
      proxy_pass http://keycloak:8080;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Proto https;
    }
  }
  server {
    listen 443 ssl;
    server_name site.stack.test;
    ssl_certificate /test/cert.pem;
    ssl_certificate_key /test/key.pem;
    location / {
      proxy_pass http://drupal:80;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Proto https;
    }
  }
}
EOF
if [[ "$RUN_MATRIX_INTEGRATION" == true ]]; then
  sed -i '$d' "$tmp/nginx.conf"
  cat >> "$tmp/nginx.conf" <<'EOF'
  server {
    listen 443 ssl;
    server_name matrix.stack.test;
    ssl_certificate /test/cert.pem;
    ssl_certificate_key /test/key.pem;
    location / {
      proxy_pass http://synapse:8008;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-For $remote_addr;
    }
  }
  server {
    listen 443 ssl;
    server_name chat.stack.test;
    ssl_certificate /test/cert.pem;
    ssl_certificate_key /test/key.pem;
    location / { return 200 'Matrix client login return'; }
  }
}
EOF
fi
if [[ "$RUN_WEHRPORTAL_INTEGRATION" == true ]]; then
  # Insert another server into the existing http block.
  sed -i '$d' "$tmp/nginx.conf"
  cat >> "$tmp/nginx.conf" <<'EOF'
  server {
    listen 443 ssl;
    server_name portal.stack.test;
    ssl_certificate /test/cert.pem;
    ssl_certificate_key /test/key.pem;
    location / {
      proxy_pass http://portal:8080;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Proto https;
    }
  }
}
EOF
fi
containers+=("$name-proxy")
if [[ "$RUN_OFFICE_INTEGRATION" == true ]]; then
  sed -i '$d' "$tmp/nginx.conf"
  cat >> "$tmp/nginx.conf" <<'EOF'
  server {
    listen 443 ssl;
    server_name docs.stack.test;
    ssl_certificate /test/cert.pem;
    ssl_certificate_key /test/key.pem;
    location / {
      proxy_pass http://onlyoffice:80;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Proto https;
    }
  }
}
EOF
fi
docker run -d --name "$name-proxy" --network "$name" --network-alias login.stack.test \
  --network-alias site.stack.test --network-alias portal.stack.test --network-alias proxy \
  --network-alias matrix.stack.test --network-alias chat.stack.test -v "$tmp:/test:ro" \
  --network-alias docs.stack.test \
  -v "$tmp/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:stable-alpine >/dev/null
docker cp "$tmp/cert.pem" "$name-drupal:/usr/local/share/ca-certificates/stack-test.crt"
docker exec "$name-drupal" update-ca-certificates >/dev/null
docker run --rm --network "$name" -e SSL_CERT_FILE=/test/cert.pem \
  -v "$tmp:/test:ro" -v "$ROOT/scripts:/scripts:ro" python:3.13-slim \
  python /scripts/configure-keycloak.py /test
if [[ "$RUN_MATRIX_INTEGRATION" == true ]]; then
  for ((i = 0; i < 120; i++)); do
    if docker exec "$name-synapse" python -c \
      'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8008/_matrix/client/v3/login",timeout=3)' \
      >/dev/null 2>&1; then break; fi
    sleep 2
  done
  docker exec "$name-synapse" register_new_matrix_user -c /data/homeserver.yaml \
    -u local-operator -p test-only-local --no-admin http://127.0.0.1:8008 >/dev/null
  docker run --rm --network "$name" -e SSL_CERT_FILE=/test/cert.pem \
    -v "$tmp:/test:ro" -v "$ROOT/tests:/tests:ro" python:3.13-slim python /tests/synapse-oidc-login.py
  docker exec "$name-pg" psql -U postgres -d synapse -Atqc \
    "SELECT CASE WHEN count(*) = 1 AND NOT bool_or(admin <> 0) THEN 'ok' ELSE 'invalid' END FROM users WHERE name LIKE '@matrix-member:%'" \
    | grep -qx ok
  docker exec "$name-synapse" python /tests/synapse-config-check.py
  docker stop "$name-synapse" >/dev/null
  docker exec "$name-pg" pg_dump -U postgres --no-owner --format=custom synapse > "$tmp/synapse.dump"
  docker exec "$name-pg" dropdb -U postgres --force synapse
  docker exec "$name-pg" createdb -U postgres --owner=synapse --template=template0 \
    --encoding=UTF8 --lc-collate=C --lc-ctype=C synapse
  docker exec -i "$name-pg" pg_restore -U postgres --role=synapse --exit-on-error --no-owner \
    --dbname synapse < "$tmp/synapse.dump"
  docker start "$name-synapse" >/dev/null
  for ((i = 0; i < 90; i++)); do
    if docker exec "$name-synapse" python -c \
      'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8008/_matrix/client/v3/login",timeout=3)' \
      >/dev/null 2>&1; then break; fi
    sleep 2
  done
  docker run --rm --network "$name" -e SSL_CERT_FILE=/test/cert.pem \
    -v "$tmp:/test:ro" -v "$ROOT/tests:/tests:ro" python:3.13-slim python /tests/synapse-oidc-login.py --repeat
  echo "Synapse HTTPS SSO, login-token exchange, non-admin identity and restore checks passed."
fi
if [[ "$RUN_WEHRPORTAL_INTEGRATION" == true ]]; then
  for ((i = 0; i < 120; i++)); do
    status=0
    docker exec "$name-portal" php /stack/configure-wehrportal-oidc.php --check || status=$?
    if ((status == 0)); then break; fi
    ((status == 75)) || exit "$status"
    sleep 2
  done
  if [[ "$RUN_OFFICE_INTEGRATION" == true ]]; then
    for ((i = 0; i < 120; i++)); do
      status=0
      docker exec "$name-portal" php /stack/configure-wehrportal-office.php --check || status=$?
      if ((status == 0)); then break; fi
      ((status == 75)) || exit "$status"
      sleep 5
    done
    docker exec "$name-portal" php /stack/configure-wehrportal-office.php
    docker exec "$name-portal" php /tests/wehrportal-office-check.php policy
    if docker exec -e ONLYOFFICE_HOST=invalid/path "$name-portal" php /stack/configure-wehrportal-office.php \
      > "$tmp/invalid-office.log" 2>&1; then
      echo "Office setup accepted an invalid server host." >&2; exit 1
    fi
    grep -q 'failed at URL and secret validation' "$tmp/invalid-office.log"
    printf 'short\n' > "$tmp/secrets/onlyoffice_jwt_secret"
    if docker exec "$name-portal" php /stack/configure-wehrportal-office.php \
      > "$tmp/invalid-office-secret.log" 2>&1; then
      echo "Office setup accepted a short JWT secret." >&2; exit 1
    fi
    grep -q 'failed at URL and secret validation' "$tmp/invalid-office-secret.log"
    printf 'test-only-onlyoffice-jwt-secret-at-least-32-characters\n' > "$tmp/secrets/onlyoffice_jwt_secret"
    docker exec "$name-portal" php /stack/configure-wehrportal-office.php
    docker exec "$name-portal" php /tests/wehrportal-office-check.php verify
    docker exec "$name-portal" php /tests/wehrportal-office-check.php roundtrip
  fi
  docker exec "$name-portal" php /stack/configure-wehrportal-oidc.php
  docker exec "$name-portal" php /stack/configure-wehrportal-oidc.php
  if docker exec -e STACK_TEST_NETWORK_DISABLED=true "$name-portal" php /stack/configure-wehrportal-oidc.php \
    > "$tmp/private-idp.log" 2>&1; then
    echo "Production OIDC accepted a private IdP address." >&2
    exit 1
  fi
  grep -q 'public DNS, port 443' "$tmp/private-idp.log"
  docker exec -e APP_CONFIG_CACHE=/tmp/stack-test-no-config-cache.php -e OIDC_FORCE_DISABLED=true \
    "$name-portal" php /stack/configure-wehrportal-oidc.php \
    > "$tmp/emergency.log" 2>&1
  grep -q 'remains disabled by OIDC_FORCE_DISABLED' "$tmp/emergency.log"
  if docker exec -e WEHRPORTAL_HOST=wrong.stack.test "$name-portal" php /stack/configure-wehrportal-oidc.php \
    > "$tmp/callback.log" 2>&1; then
    echo "Provisioning accepted a mismatched callback." >&2
    exit 1
  fi
  grep -q 'callback validation' "$tmp/callback.log"
  mv "$tmp/secrets/wehrportal_oidc_client_secret" "$tmp/portal-secret"
  if docker exec "$name-portal" php /stack/configure-wehrportal-oidc.php > "$tmp/missing-secret.log" 2>&1; then
    echo "Provisioning accepted a missing client secret." >&2
    exit 1
  fi
  mv "$tmp/portal-secret" "$tmp/secrets/wehrportal_oidc_client_secret"
  grep -q 'secret validation' "$tmp/missing-secret.log"
  if docker exec -e APP_CONFIG_CACHE=/tmp/stack-test-no-config-cache.php -e OIDC_ENABLED=false \
    "$name-portal" php /stack/configure-wehrportal-oidc.php --check > "$tmp/plugin-disabled.log" 2>&1; then
    echo "Provisioning accepted a disabled OIDC extension." >&2
    exit 1
  fi
  docker exec "$name-portal" php /tests/wehrportal-oidc-check.php policy
  docker exec "$name-portal" php /stack/configure-wehrportal-oidc.php
  docker exec "$name-portal" php /tests/wehrportal-oidc-check.php policy-verify
  docker exec "$name-portal" php /tests/wehrportal-oidc-check.php seed
  docker run --rm --network "$name" -e SSL_CERT_FILE=/test/cert.pem \
    -v "$tmp:/test:ro" -v "$ROOT/tests:/tests:ro" python:3.13-slim python /tests/wehrportal-oidc-login.py
  docker exec "$name-portal" php /tests/wehrportal-oidc-check.php verify
  docker logs "$name-portal" > "$tmp/portal-mail.log" 2>&1
  docker run --rm --network "$name" -e SSL_CERT_FILE=/test/cert.pem \
    -v "$tmp:/test:ro" -v "$ROOT/tests:/tests:ro" python:3.13-slim python /tests/wehrportal-oidc-login.py --magic
  docker stop "$name-portal" >/dev/null
  docker exec "$name-pg" pg_dump -U postgres --no-owner --format=custom wehrportal > "$tmp/wehrportal.dump"
  docker exec "$name-pg" dropdb -U postgres --force wehrportal
  docker exec "$name-pg" createdb -U postgres --owner=wehrportal wehrportal
  docker exec -i "$name-pg" pg_restore -U postgres --role=wehrportal --exit-on-error --no-owner \
    --dbname wehrportal < "$tmp/wehrportal.dump"
  docker start "$name-portal" >/dev/null
  for ((i = 0; i < 90; i++)); do
    if docker exec "$name-portal" php -r 'exit(@file_get_contents("http://127.0.0.1:8080/up") === false ? 1 : 0);'; then
      break
    fi
    sleep 2
  done
  docker exec "$name-portal" php /stack/configure-wehrportal-oidc.php
  docker run --rm --network "$name" -e SSL_CERT_FILE=/test/cert.pem \
    -v "$tmp:/test:ro" -v "$ROOT/tests:/tests:ro" python:3.13-slim python /tests/wehrportal-oidc-login.py --repeat
  docker exec "$name-portal" php /tests/wehrportal-oidc-check.php verify
  if [[ "$RUN_OFFICE_INTEGRATION" == true ]]; then
    docker exec "$name-portal" php /stack/configure-wehrportal-office.php
    docker exec "$name-portal" php /tests/wehrportal-office-check.php verify
  fi
  echo "WehrPortal SSO, emergency controls, local admin login and database restore passed."
fi
docker run --rm --network "$name" -e SSL_CERT_FILE=/test/cert.pem \
  -v "$tmp:/test:ro" -v "$ROOT/scripts:/scripts:ro" python:3.13-slim \
  python /scripts/configure-keycloak.py /test
for ((i = 0; i < 120; i++)); do
  if docker exec "$name-drupal" php -r \
    '$c=stream_context_create(["http"=>["header"=>"Host: site.stack.test"]]); exit(@file_get_contents("http://127.0.0.1/user/login",false,$c)===false?1:0);'; then
    break
  fi
  if [[ "$(docker inspect --format '{{.State.Running}}' "$name-drupal")" != true ]]; then
    docker logs "$name-drupal"
    exit 1
  fi
  sleep 2
done
docker run --rm --network "$name" -e SSL_CERT_FILE=/test/cert.pem \
  -v "$tmp:/test:ro" -v "$ROOT/tests:/tests:ro" python:3.13-slim python /tests/drupal-oidc-login.py
docker exec "$name-drupal" vendor/bin/drush php:eval \
  '$u=\Drupal::entityTypeManager()->getStorage("user")->loadByProperties(["mail"=>"member@stack.test"]); $u=reset($u); if (!$u || $u->getRoles() !== ["authenticated"]) { throw new \RuntimeException("SSO user received unexpected privileges"); }'
docker exec "$name-drupal" vendor/bin/drush php:eval \
  '$u=\Drupal\user\Entity\User::load(1); if (!\Drupal::service("password")->check(trim(file_get_contents("/run/secrets/drupal_admin_password")), $u->getPassword())) { throw new \RuntimeException("Local emergency admin password was not applied"); }'
if docker logs "$name-drupal" 2>&1 | grep -q 'User password:'; then
  echo "Drush printed an administrator password." >&2
  exit 1
fi
docker exec "$name-drupal" vendor/bin/drush config:export --yes >/dev/null
if grep -R -q 'test-only-integration' "$tmp/private/config-sync"; then
  echo "Secret leaked into Drupal configuration export." >&2
  exit 1
fi
docker stop "$name-drupal" >/dev/null
docker exec "$name-pg" pg_dump -U postgres --no-owner --format=custom drupal > "$tmp/drupal.dump"
docker exec "$name-pg" dropdb -U postgres --force drupal
docker exec "$name-pg" createdb -U postgres --owner=drupal drupal
docker exec -i "$name-pg" pg_restore -U postgres --role=drupal --exit-on-error --no-owner \
  --dbname drupal < "$tmp/drupal.dump"
docker start "$name-drupal" >/dev/null
ready=false
for ((i = 0; i < 90; i++)); do
  if docker exec "$name-drupal" php -r \
    '$c=stream_context_create(["http"=>["header"=>"Host: site.stack.test"]]); exit(@file_get_contents("http://127.0.0.1/user/login",false,$c)===false?1:0);'; then
    ready=true
    break
  fi
  sleep 2
done
[[ "$ready" == true ]]
docker exec "$name-drupal" vendor/bin/drush php:eval \
  '$n=\Drupal::entityQuery("user")->accessCheck(FALSE)->condition("mail", "member@stack.test")->count()->execute(); if ((int) $n !== 1) { throw new \RuntimeException("Duplicate or lost SSO account"); }'
echo "Drupal/PostgreSQL and HTTPS Keycloak login integration passed, including database restore, repeated provisioning and secret-free config export."
