<?php

namespace Extensions\StackTest;

use App\Support\SafeUrl;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\ServiceProvider;

// Mounted only in disposable integration containers, never copied by the installer.
class StackTestServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        if (getenv('STACK_TEST_NETWORK_DISABLED') === 'true') {
            return;
        }
        SafeUrl::resolveUsing(function (string $host): array {
            if ($host !== 'login.stack.test') {
                throw new \RuntimeException('Unexpected test IdP');
            }
            return ['93.184.216.34'];
        });
        Http::globalMiddleware(function (callable $handler): callable {
            return function ($request, array $options) use ($handler) {
                $host = $request->getUri()->getHost();
                if ($host === 'onlyoffice' && $request->getUri()->getScheme() === 'http') {
                    return $handler($request, $options);
                }
                if (!in_array($host, ['login.stack.test', 'portal.stack.test', 'docs.stack.test'], true)) {
                    throw new \RuntimeException('Unexpected test HTTP target');
                }
                // Keep TLS, discovery, real token exchange and signature checks; redirect transport only.
                $options['curl'][CURLOPT_RESOLVE] = [$host . ':443:' . gethostbyname('proxy')];
                $options['verify'] = '/test/cert.pem';
                return $handler($request, $options);
            };
        });
    }
}
