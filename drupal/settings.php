<?php

$stackSecret = static function (string $name): string {
    $path = '/run/secrets/' . $name;
    if (!is_readable($path) || ($value = trim(file_get_contents($path))) === '') {
        throw new RuntimeException("Missing or empty Drupal secret: $name");
    }
    return $value;
};

$databases['default']['default'] = [
    'driver' => 'pgsql',
    'namespace' => 'Drupal\\pgsql\\Driver\\Database\\pgsql',
    'autoload' => 'core/modules/pgsql/src/Driver/Database/pgsql/',
    'database' => 'drupal',
    'username' => 'drupal',
    'password' => $stackSecret('drupal_db_password'),
    'host' => getenv('DRUPAL_DB_HOST') ?: 'postgres',
    'port' => '5432',
    'prefix' => '',
];
$settings['hash_salt'] = $stackSecret('drupal_hash_salt');
$settings['file_private_path'] = '/var/drupal/private';
$settings['config_sync_directory'] = '/var/drupal/private/config-sync';
$settings['trusted_host_patterns'] = ['^' . preg_quote(getenv('DRUPAL_HOST'), '/') . '$'];
$settings['reverse_proxy'] = TRUE;
// Trust only the directly connected proxy, never a client-supplied forwarding chain.
$settings['reverse_proxy_addresses'] = [$_SERVER['REMOTE_ADDR'] ?? '127.0.0.1'];
$settings['reverse_proxy_trusted_headers'] =
    \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PROTO;
$config['system.logging']['error_level'] = 'hide';
$config['openid_connect.settings.generic']['settings']['client_secret'] =
    getenv('DRUPAL_OIDC_ENABLED') === 'true' ? $stackSecret('drupal_oidc_client_secret') : '';
$settings['update_free_access'] = FALSE;
