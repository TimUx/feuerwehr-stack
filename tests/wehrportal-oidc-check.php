<?php

foreach (['DB_PASSWORD' => 'wehrportal_db_password', 'APP_KEY' => 'wehrportal_app_key'] as $key => $name) {
    $value = trim(file_get_contents('/run/secrets/' . $name));
    putenv($key . '=' . $value);
    $_ENV[$key] = $_SERVER[$key] = $value;
}
require '/var/www/html/vendor/autoload.php';
$app = require '/var/www/html/bootstrap/app.php';
$app->make(\Illuminate\Contracts\Console\Kernel::class)->bootstrap();
set_exception_handler(function (Throwable $error): void {
    fwrite(STDERR, $error->getMessage() . "\n");
    exit(1);
});
$settings = app(\Extensions\Oidc\Support\OidcSettings::class);
function check(bool $valid, string $message): void
{
    if (!$valid) {
        throw new RuntimeException($message);
    }
}
if ($argv[1] === 'policy') {
    $settings->set('jit', true);
    $settings->set('exclusive', true);
    $settings->set('link_by_email', false);
    exit(0);
}
if ($argv[1] === 'policy-verify') {
    check($settings->jit() && $settings->exclusive() && !$settings->linkByEmail(), 'Setup overwrote account policy');
    $settings->set('jit', false);
    $settings->set('exclusive', false);
    $settings->set('link_by_email', true);
    exit(0);
}
check($settings->isActive(), 'OIDC must be active');
check($settings->linkByEmail() && !$settings->jit() && !$settings->exclusive(), 'Incorrect account policy');
$secret = trim(file_get_contents('/run/secrets/wehrportal_oidc_client_secret'));
check($settings->secret() === $secret, 'Client secret mismatch');
check(\App\Models\Setting::where('key', 'ext_oidc_client_secret')->value('value') !== $secret, 'Plaintext secret stored');
check((bool) \App\Models\User::where('email', 'admin@stack.test')->firstOrFail()->ext_local_admin, 'Local admin missing');
if ($argv[1] === 'seed') {
    foreach (['portal-member', 'portal-unverified', 'portal-inactive'] as $name) {
        \App\Models\User::create([
            'name' => $name, 'email' => $name . '@stack.test', 'is_admin' => false,
            'is_active' => $name !== 'portal-inactive',
        ]);
    }
} else {
    check(\Extensions\Oidc\Models\Identity::count() === 1, 'Duplicate or unexpected identities');
    $user = \App\Models\User::where('email', 'portal-member@stack.test')->firstOrFail();
    check(!$user->is_admin && !$user->ext_local_admin, 'SSO elevated privileges');
    check(!\App\Models\User::where('email', 'portal-unknown@stack.test')->exists(), 'JIT created an unknown account');
}
echo "WehrPortal policy, encrypted secret and identity checks passed.\n";
