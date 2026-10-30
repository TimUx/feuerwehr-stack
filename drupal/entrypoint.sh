#!/bin/sh
set -eu

cd /opt/drupal
attempt=0
until php -r '
try {
    $db = new PDO("pgsql:host=" . (getenv("DRUPAL_DB_HOST") ?: "postgres") . ";dbname=drupal",
        "drupal", trim(file_get_contents("/run/secrets/drupal_db_password")));
    if (!$db->query("SELECT 1 FROM pg_extension WHERE extname = '\''pg_trgm'\''")->fetchColumn()) {
        throw new RuntimeException("Drupal database requires pg_trgm");
    }
} catch (PDOException $e) { fwrite(STDERR, "Waiting for Drupal PostgreSQL connection.\n"); exit(1); }
'; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 120 ]; then
        echo "Drupal database is not ready; run scripts/setup-drupal.sh." >&2
        exit 1
    fi
    sleep 2
done

mkdir -p web/sites/default/files /var/drupal/private/config-sync
chown www-data:www-data web/sites/default/files /var/drupal/private /var/drupal/private/config-sync
installed=$(php -r '
$db = new PDO("pgsql:host=" . (getenv("DRUPAL_DB_HOST") ?: "postgres") . ";dbname=drupal",
    "drupal", trim(file_get_contents("/run/secrets/drupal_db_password")));
if ($db->query("SELECT to_regclass('\''public.config'\'') IS NOT NULL")->fetchColumn()) {
    echo "yes";
} else {
    $nonempty = $db->query("SELECT EXISTS (
        SELECT FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname NOT LIKE '\''pg_%'\'' AND n.nspname <> '\''information_schema'\''
        AND c.relkind IN ('\''r'\'', '\''p'\'', '\''v'\'', '\''m'\'', '\''S'\'', '\''f'\'')
    )")->fetchColumn();
    echo $nonempty ? "nonempty" : "no";
}
') || { printf '%s\n' "$installed" >&2; exit 1; }
if [ "$installed" = nonempty ]; then
    echo "Refusing to install Drupal into a non-empty database without its config table." >&2
    exit 1
fi
if [ "$installed" = no ]; then
    # Pass the password in a private temporary config, never in argv or logs.
    install_config=$(mktemp /tmp/drupal-install.XXXXXX.yml)
    export DRUPAL_INSTALL_CONFIG="$install_config"
    trap 'rm -f "$install_config"' EXIT
    php -r '
    $password = trim(file_get_contents("/run/secrets/drupal_admin_password"));
    if ($password === "") { throw new RuntimeException("Empty Drupal admin password"); }
    file_put_contents(getenv("DRUPAL_INSTALL_CONFIG"),
        json_encode(["command" => ["site" => ["install" => ["options" => ["account-pass" => $password]]]]]));
    '
    vendor/bin/drush --config="$install_config" site:install standard --yes \
        --account-name=siteadmin --account-mail="$DRUPAL_ADMIN_EMAIL" \
        --site-mail="$DRUPAL_ADMIN_EMAIL" --site-name="Feuerwehr" \
        --uri="https://$DRUPAL_HOST"
    rm -f "$install_config"
    trap - EXIT
    unset DRUPAL_INSTALL_CONFIG
else
    vendor/bin/drush status --field=bootstrap --uri="https://$DRUPAL_HOST" | grep -q Successful || {
        echo "Existing Drupal database cannot bootstrap; refusing to reinstall it." >&2
        exit 1
    }
fi
vendor/bin/drush updatedb --yes --uri="https://$DRUPAL_HOST"
vendor/bin/drush pm:enable openid_connect --yes --uri="https://$DRUPAL_HOST"
vendor/bin/drush php:script /opt/drupal/configure.php --uri="https://$DRUPAL_HOST"
vendor/bin/drush cache:rebuild --uri="https://$DRUPAL_HOST"
exec docker-php-entrypoint "$@"
