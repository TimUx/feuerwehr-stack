<?php

$factory = \Drupal::configFactory();
$enabled = getenv('DRUPAL_OIDC_ENABLED') === 'true';
if ($enabled) {
    $issuer = 'https://' . getenv('KEYCLOAK_HOST') . '/realms/' . getenv('KEYCLOAK_REALM');
    $factory->getEditable('openid_connect.settings.generic')
        ->set('enabled', TRUE)
        ->set('settings', [
            'client_id' => 'drupal',
            // The secret is supplied by settings.php, not exported to Drupal config.
            'client_secret' => '',
            'authorization_endpoint' => $issuer . '/protocol/openid-connect/auth',
            'token_endpoint' => $issuer . '/protocol/openid-connect/token',
            'userinfo_endpoint' => $issuer . '/protocol/openid-connect/userinfo',
        ])->save();
    $factory->getEditable('openid_connect.settings')
        ->set('connect_existing_users', FALSE)
        ->set('override_registration_settings', TRUE)
        ->set('user_login_display', 'above')
        ->set('userinfo_mappings', ['timezone' => 'zoneinfo'])
        ->save();
} else {
    $factory->getEditable('openid_connect.settings.generic')->set('enabled', FALSE)->save();
}
$factory->getEditable('user.settings')->set('register', 'admin_only')->save();
