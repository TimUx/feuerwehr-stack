<?php

use App\Models\Module;
use App\Models\Setting;
use App\Models\User;
use Extensions\Dateien\Models\Version;
use Extensions\Dateien\Office\Jwt;
use Extensions\Dateien\Office\OfficeService;
use Extensions\Dateien\Office\OfficeSettings;
use Extensions\Dateien\Services\FileService;
use Extensions\Locations\Models\Location;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;

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
function check(bool $valid, string $message): void
{
    if (!$valid) {
        throw new RuntimeException($message);
    }
}
$settings = app(OfficeSettings::class);
$secret = trim(file_get_contents('/run/secrets/onlyoffice_jwt_secret'));
check($settings->enabled() && $settings->provider() === 'onlyoffice', 'ONLYOFFICE not enabled');
check($settings->serverUrl() === 'https://docs.stack.test', 'Browser URL mismatch');
check($settings->internalUrl() === 'http://onlyoffice', 'Internal URL mismatch');
check($settings->callbackUrl() === 'https://portal.stack.test', 'Callback base mismatch');
check($settings->secret() === $secret, 'Office secret mismatch');
$encrypted = Setting::get('dateien.office.jwt_secret');
check(is_string($encrypted) && !str_contains($encrypted, $secret), 'Plaintext office secret stored');
if ($argv[1] === 'policy') {
    Setting::set('dateien.office.editing', '0');
    Setting::set('dateien.office.extensions', '["txt"]');
    Setting::set('stack.test.office_encrypted', $encrypted);
    Setting::set('stack.test.module_active', Module::where('key', 'dateien')->value('is_active') ? '1' : '0');
    exit(0);
}
check(!$settings->editing() && $settings->extensions() === ['txt'], 'Setup overwrote office policy');
check(Setting::get('stack.test.office_encrypted') === $encrypted, 'Unchanged secret was re-encrypted');
check((Module::where('key', 'dateien')->value('is_active') ? '1' : '0') ===
    Setting::get('stack.test.module_active'), 'Setup changed module activation');
if ($argv[1] === 'verify') {
    echo "ONLYOFFICE URLs, encrypted shared secret, idempotency and preserved policies passed.\n";
    exit(0);
}

Module::where('key', 'dateien')->update(['is_active' => true]);
Cache::forget('modules_active_keys');
Setting::set('dateien.office.editing', '1');
$location = Location::default();
$user = User::create(['name' => 'Office test admin', 'email' => 'office-admin@stack.test',
    'is_admin' => true, 'is_active' => true, 'ext_location_id' => $location->id]);
$user->moduleAccess()->create(['module' => 'dateien']);
$user->locations()->sync([$location->id => ['role' => 'member']]);
$files = app(FileService::class);
$space = $files->createSpace($user, ['name' => 'Stack office test', 'ext_location_id' => $location->id]);
$content = 'ONLYOFFICE stack integration document';
$upload = tempnam(sys_get_temp_dir(), 'stack-office-');
file_put_contents($upload, $content);
try {
    $node = $files->upload($user, $space, null, new UploadedFile($upload, 'stack-office.txt', 'text/plain', UPLOAD_ERR_OK, true));
} finally {
    unlink($upload);
}
$office = app(OfficeService::class);
[$session, $token] = $office->open($user, $node, true);
$version = Version::where('node_id', $node->id)->firstOrFail();
$editor = $office->connector()->editor($session, $token, $user, $node, $version);
check($editor['script'] === 'https://docs.stack.test/web-apps/apps/api/documents/api.js', 'Editor script mismatch');
check(Jwt::decode($editor['config']['token'], $secret) !== null, 'Editor JWT invalid');
$url = $editor['config']['document']['url'];
$callback = $editor['config']['editorConfig']['callbackUrl'];
check(Http::get($url)->status() === 401, 'Unsigned file download accepted');
check(Http::withToken(Jwt::encode([], str_repeat('wrong', 8)))->get($url)->status() === 401, 'Wrong file JWT accepted');
check(Http::withToken(Jwt::encode(['url' => $url], $secret))->get($url)->body() === $content, 'Signed download failed');

function convert(string $url, string $from, string $to, string $secret, string $suffix): string
{
    $data = ['async' => false, 'url' => $url, 'filetype' => $from, 'outputtype' => $to,
        'key' => 'stack-test-' . bin2hex(random_bytes(8)) . $suffix, 'title' => 'stack-office.' . $from];
    $data['token'] = Jwt::encode($data, $secret);
    $response = Http::timeout(120)->acceptJson()->post('http://onlyoffice/converter', $data);
    check($response->successful() && $response->json('endConvert') === true
        && is_string($response->json('fileUrl')), 'ONLYOFFICE conversion failed: ' . $response->body());
    return $response->json('fileUrl');
}
$docx = convert($url, 'txt', 'docx', $secret, 'docx');
$converted = convert($docx, 'docx', 'txt', $secret, 'txt');
$payload = ['status' => 6, 'key' => $editor['config']['document']['key'],
    'url' => $converted, 'filetype' => 'txt', 'users' => [(string) $user->id]];
check(Http::withToken(Jwt::encode(['payload' => $payload], str_repeat('wrong', 8)))
    ->post($callback, $payload)->status() === 401, 'Wrong save JWT accepted');
$result = Http::withToken(Jwt::encode(['payload' => $payload], $secret))->post($callback, $payload);
check($result->successful() && $result->json('error') === 0, 'Save callback failed: ' . $result->body());
$saved = Version::where('node_id', $node->id)->orderByDesc('number')->firstOrFail();
check($saved->number === 2 && $saved->source === 'office', 'Office version not persisted');
check(str_contains(Http::withToken(Jwt::encode(['url' => $url], $secret))->get($url)->body(), $content),
    'Converted content not available in portal');
Setting::set('dateien.office.editing', '0');
Module::where('key', 'dateien')->update(['is_active' => Setting::get('stack.test.module_active') === '1']);
Cache::forget('modules_active_keys');
echo "Real ONLYOFFICE download/conversion, signed save callback and persisted file version passed.\n";
