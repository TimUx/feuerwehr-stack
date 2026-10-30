"""Exercise real Drupal -> Keycloak -> Drupal redirects using a cookie-aware browser."""
import html
import http.cookiejar
import json
import re
import urllib.error
import urllib.parse
import urllib.request

cookies = http.cookiejar.CookieJar()
browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))


def request(url, data=None, token=None):
    headers = {"Authorization": "Bearer " + token} if token else {}
    if isinstance(data, dict):
        data = urllib.parse.urlencode(data).encode()
    return browser.open(urllib.request.Request(url, data=data, headers=headers), timeout=30)


auth = json.load(request("https://login.stack.test/realms/master/protocol/openid-connect/token", {
    "client_id": "admin-cli", "grant_type": "password",
    "username": "kcadmin", "password": "test-only-integration",
}))
data = json.dumps({
    "username": "member", "email": "member@stack.test", "emailVerified": True,
    "firstName": "Test", "lastName": "Member", "enabled": True,
    "credentials": [{"type": "password", "value": "test-only-member", "temporary": False}],
}).encode()
browser.open(urllib.request.Request(
    "https://login.stack.test/admin/realms/feuerwehr/users", data=data,
    headers={"Authorization": "Bearer " + auth["access_token"], "Content-Type": "application/json"}))

for attempt in range(2):
    # First authenticate; second round checks that the same sub reuses the same Drupal user.
    page = request("https://site.stack.test/user/login").read().decode()
    form = re.search(r'<form[^>]*id="openid-connect-login-form"[^>]*>(.*?)</form>', page, re.S)
    if form is None:
        form = re.search(r'<form[^>]*openid-connect[^>]*>(.*?)</form>', page, re.S)
    assert form, "OIDC login form is missing"
    fields = {html.unescape(k): html.unescape(v) for k, v in
              re.findall(r'<input[^>]*name="([^"]*)"[^>]*value="([^"]*)"', form[1])}
    submit = re.search(r'<input[^>]*type="submit"[^>]*value="([^"]*)"', form[1])
    assert submit, "OIDC login submit is missing"
    fields["op"] = html.unescape(submit[1])
    response = request("https://site.stack.test/user/login", fields)
    if "login.stack.test" in response.url:
        page = response.read().decode()
        action = html.unescape(re.search(r'<form[^>]*action="([^"]+)"', page)[1])
        response = request(action, {"username": "member", "password": "test-only-member", "credentialId": ""})
    page = response.read().decode()
    assert response.url.startswith("https://site.stack.test/"), response.url
    assert "Log out" in page or "user/logout" in page, "SSO did not create an authenticated Drupal session"
    profile = response.url
    assert "/user/" in profile, profile
    try:
        request("https://site.stack.test/admin")
    except urllib.error.HTTPError as error:
        assert error.code == 403, error.code
    else:
        raise AssertionError("A regular SSO user could enter the Drupal admin area")
    print("Successful SSO round", attempt + 1, profile)
    # A new browser session forces another round without relying on Drupal's logout confirmation form.
    cookies.clear()
