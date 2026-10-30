<?php

use App\Models\Setting;
use App\Models\User;
use Extensions\Oidc\Services\OidcClient;
use Extensions\Oidc\Support\OidcSettings;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
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
    if (!class_exists(OidcSettings::class) || !class_exists(OidcClient::class) || !config('oidc.enabled')) {
        throw new RuntimeException('OIDC extension unavailable');
    }

    $stage = 'database readiness';
    try {
        $ready = Schema::hasTable('settings') && Schema::hasTable('x_oidc_identities')
            && Schema::hasColumn('users', 'ext_local_admin');
        if ($ready) {
            foreach (array_filter(array_map('trim', explode(',', strtolower(getenv('ADMIN_EMAILS') ?: '')))) as $email) {
                if (!User::where('email', $email)->where('is_admin', true)->where('is_active', true)->exists()) {
                    $ready = false;
                }
            }
        }
    } catch (\Illuminate\Database\QueryException $error) {
        fwrite(STDERR, "Waiting for WehrPortal database and migrations.\n");
        exit(75);
    }
    if (!$ready) {
        fwrite(STDERR, "Waiting for WehrPortal OIDC migrations and configured administrators.\n");
        exit(75);
    }
    if (in_array('--check', $argv, true)) {
        exit(0);
    }

    $settings = app(OidcSettings::class);
    if ($settings->forceDisabled()) {
        fwrite(STDERR, "WehrPortal OIDC remains disabled by OIDC_FORCE_DISABLED; emergency login is unchanged.\n");
        exit(0);
    }
    $stage = 'callback validation (check APP_URL and HTTPS proxy settings)';
    $expectedCallback = 'https://' . getenv('WEHRPORTAL_HOST') . '/auth/oidc/callback';
    if ($settings->redirectUri() !== $expectedCallback) {
        throw new RuntimeException('Callback mismatch');
    }
    $stage = 'secret validation';
    $path = '/run/secrets/wehrportal_oidc_client_secret';
    if (!is_readable($path) || ($secret = trim(file_get_contents($path))) === '') {
        throw new RuntimeException('Missing OIDC secret');
    }
    $issuer = 'https://' . getenv('KEYCLOAK_HOST') . '/realms/' . getenv('KEYCLOAK_REALM');
    $stage = 'Keycloak HTTPS discovery/JWKS (public DNS, port 443 and trusted TLS required)';
    $result = app(OidcClient::class)->test($issuer);
    if (!$result['ok']) {
        throw new RuntimeException('Discovery or JWKS unavailable');
    }

    $stage = 'settings persistence';
    $keys = ['issuer', 'client_id', 'client_secret', 'scopes', 'label', 'link_by_email', 'jit', 'exclusive', 'enabled'];
    try {
        DB::transaction(function () use ($settings, $issuer, $secret) {
            $settings->set('issuer', $issuer);
            $settings->set('client_id', 'wehrportal');
            $settings->set('scopes', 'openid email profile');
            $settings->set('label', 'Mit Keycloak anmelden');
            if ($settings->secret() !== $secret) {
                $settings->saveSecret($secret);
            }
            foreach (['link_by_email' => true, 'jit' => false, 'exclusive' => false] as $key => $default) {
                if (Setting::get('ext_oidc_' . $key) === null) {
                    $settings->set($key, $default);
                }
            }
            $settings->set('enabled', true);
        });
    } finally {
        // Settings are cached outside the DB transaction, including reads before a rollback.
        foreach ($keys as $key) {
            Cache::forget('setting_ext_oidc_' . $key);
        }
    }
    if (!$settings->isActive() || $settings->secret() !== $secret) {
        throw new RuntimeException('OIDC settings verification failed');
    }
    echo "WehrPortal OIDC configured and active. Login: /anmelden; local login remains governed by portal policy.\n";
} catch (Throwable $error) {
    // Framework exceptions may contain credentials, SQL bindings or tokens.
    fwrite(STDERR, "ERROR: WehrPortal OIDC setup failed at $stage. Check image compatibility and application logs; rerun scripts/setup-apps.sh.\n");
    exit(1);
}
