<?php

use App\Models\Setting;
use Extensions\Dateien\Office\OfficeSettings;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Schema;

$stage = 'application bootstrap';
try {
    // docker exec does not inherit values exported by the container's entrypoint.
    foreach (['DB_PASSWORD' => 'wehrportal_db_password', 'APP_KEY' => 'wehrportal_app_key'] as $key => $name) {
        $file = '/run/secrets/' . $name;
        if (!is_readable($file) || ($value = trim(file_get_contents($file))) === '') {
            throw new RuntimeException('Missing application secret');
        }
        putenv($key . '=' . $value);
        $_ENV[$key] = $_SERVER[$key] = $value;
    }
    require '/var/www/html/vendor/autoload.php';
    $app = require '/var/www/html/bootstrap/app.php';
    $app->make(Kernel::class)->bootstrap();
    if (!class_exists(OfficeSettings::class) || !app()->bound(OfficeSettings::class)) {
        throw new RuntimeException('Dateien Office extension unavailable');
    }

    $stage = 'database readiness';
    try {
        $ready = Schema::hasTable('settings') && Schema::hasTable('x_files_office_sessions')
            && Schema::hasTable('x_files_versions');
    } catch (\Illuminate\Database\QueryException $error) {
        fwrite(STDERR, "Waiting for WehrPortal database and migrations.\n");
        exit(75);
    }
    if (!$ready) {
        fwrite(STDERR, "Waiting for WehrPortal Dateien/Office migrations.\n");
        exit(75);
    }

    $stage = 'URL and secret validation';
    $server = 'https://' . getenv('ONLYOFFICE_HOST');
    $callback = 'https://' . getenv('WEHRPORTAL_HOST');
    foreach ([$server, $callback] as $url) {
        if (!OfficeSettings::validUrl($url) || parse_url($url, PHP_URL_PATH) !== null) {
            throw new RuntimeException('Invalid application host');
        }
    }
    if (rtrim((string) config('app.url'), '/') !== $callback) {
        throw new RuntimeException('APP_URL mismatch');
    }
    $path = '/run/secrets/onlyoffice_jwt_secret';
    if (!is_readable($path) || strlen($secret = trim(file_get_contents($path))) < 32) {
        throw new RuntimeException('Missing or short ONLYOFFICE JWT secret');
    }
    $internal = 'http://onlyoffice';
    $stage = 'ONLYOFFICE health check';
    try {
        $response = Http::timeout(5)->withOptions(['allow_redirects' => false])->get($internal . '/healthcheck');
    } catch (\Illuminate\Http\Client\ConnectionException $error) {
        fwrite(STDERR, "Waiting for ONLYOFFICE healthcheck.\n");
        exit(75);
    }
    if (!$response->successful() || trim($response->body()) !== 'true') {
        fwrite(STDERR, "Waiting for ONLYOFFICE healthcheck (not ready).\n");
        exit(75);
    }
    if (in_array('--check', $argv, true)) {
        exit(0);
    }

    $stage = 'settings persistence';
    $settings = app(OfficeSettings::class);
    $keys = ['provider', 'server_url', 'internal_url', 'callback_url', 'jwt_secret', 'extensions'];
    try {
        DB::transaction(function () use ($settings, $server, $internal, $callback, $secret) {
            $settings->save([
                'provider' => 'onlyoffice',
                'server_url' => $server,
                'internal_url' => $internal,
                'callback_url' => $callback,
                // Preserve the administrator's format and editing restrictions.
                'extensions' => $settings->extensions(),
            ], $settings->secret() === $secret ? null : $secret);
        });
    } finally {
        foreach ($keys as $key) {
            Cache::forget('setting_dateien.office.' . $key);
        }
    }
    if (!$settings->enabled() || $settings->provider() !== 'onlyoffice'
        || $settings->serverUrl() !== $server || $settings->internalUrl() !== $internal
        || $settings->callbackUrl() !== $callback || $settings->secret() !== $secret
        || Setting::get('dateien.office.jwt_secret') === $secret) {
        throw new RuntimeException('Office settings verification failed');
    }
    echo "WehrPortal Dateien configured for ONLYOFFICE; module access and editing policies are unchanged.\n";
} catch (Throwable $error) {
    // Framework exceptions may contain credentials, SQL bindings or tokens.
    fwrite(STDERR, "ERROR: WehrPortal ONLYOFFICE setup failed at $stage. Check image compatibility, URLs and logs; rerun scripts/setup-apps.sh.\n");
    exit(1);
}
