"""Exercise the Matrix SSO discovery, browser redirect and single-use token exchange."""
import html
import http.cookiejar
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

cookies = http.cookiejar.CookieJar()
browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))


def request(url, data=None, token=None):
    headers = {"Authorization": "Bearer " + token} if token else {}
    if data is not None:
        data = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    for attempt in range(3):
        try:
            return browser.open(urllib.request.Request(url, data=data, headers=headers), timeout=30)
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 2:
                raise
            delay = json.load(error)["retry_after_ms"] / 1000 + 0.1
            assert delay <= 30, f"Unexpected test login throttling: {delay}s"
            time.sleep(delay)


if "--repeat" not in sys.argv:
    data = urllib.parse.urlencode({
        "client_id": "admin-cli", "grant_type": "password",
        "username": "kcadmin", "password": "test-only-integration",
    }).encode()
    auth = json.load(browser.open(urllib.request.Request(
        "https://login.stack.test/realms/master/protocol/openid-connect/token", data=data)))
    for username in ("matrix-member", "local-operator"):
        request("https://login.stack.test/admin/realms/feuerwehr/users", {
            "username": username, "email": username + "@stack.test", "emailVerified": True,
            "firstName": "Matrix", "lastName": "Member", "enabled": True,
            "credentials": [{"type": "password", "value": "test-only-member", "temporary": False}],
        }, auth["access_token"])

flows = json.load(request("https://matrix.stack.test/_matrix/client/v3/login"))["flows"]
assert any(f["type"] == "m.login.sso" and any(p["id"] == "oidc-keycloak"
           for p in f.get("identity_providers", [])) for f in flows), flows
assert any(f["type"] == "m.login.token" for f in flows), flows
assert any(f["type"] == "m.login.password" for f in flows), flows

for attempt, (username, localpart) in enumerate((
        ("matrix-member", "matrix-member"),
        ("matrix-member", "matrix-member"),
        ("local-operator", "local-operator1"))):
    cookies.clear()
    response = request("https://matrix.stack.test/_matrix/client/v3/login/sso/redirect/oidc-keycloak?"
                       + urllib.parse.urlencode({"redirectUrl": "https://chat.stack.test/"}))
    assert urllib.parse.urlparse(response.url).hostname == "login.stack.test", response.url
    query = urllib.parse.parse_qs(urllib.parse.urlparse(response.url).query)
    assert query["code_challenge_method"] == ["S256"]
    assert query["redirect_uri"] == ["https://matrix.stack.test/_synapse/client/oidc/callback"]
    page = response.read().decode()
    action = html.unescape(re.search(r'<form[^>]*action="([^"]+)"', page)[1])
    data = urllib.parse.urlencode({"username": username, "password": "test-only-member",
                                  "credentialId": ""}).encode()
    response = browser.open(urllib.request.Request(action, data=data), timeout=30)
    page = response.read().decode()
    if "/_synapse/client/pick_username" in response.url:
        # A colliding local account must not be linked to the Keycloak identity.
        data = urllib.parse.urlencode({"username": localpart, "use_display_name": "true"}).encode()
        response = browser.open(urllib.request.Request(response.url, data=data), timeout=30)
        page = response.read().decode()
    assert urllib.parse.urlparse(response.url).hostname == "chat.stack.test", (response.url, page[:2000])
    token = urllib.parse.parse_qs(urllib.parse.urlparse(response.url).query)["loginToken"][0]
    login = json.load(request("https://matrix.stack.test/_matrix/client/v3/login",
                             {"type": "m.login.token", "token": token}))
    assert login["user_id"] == "@" + localpart + ":identity.stack.test", login["user_id"]
    whoami = json.load(request("https://matrix.stack.test/_matrix/client/v3/account/whoami",
                              token=login["access_token"]))
    assert whoami["user_id"] == login["user_id"]
    if attempt == 0:
        try:
            request("https://matrix.stack.test/_matrix/client/v3/login",
                    {"type": "m.login.token", "token": token})
        except urllib.error.HTTPError as error:
            assert error.code in (400, 403), error.code
        else:
            raise AssertionError("Matrix login token was reusable")
    print("Matrix Keycloak SSO passed:", login["user_id"])

local = json.load(request("https://matrix.stack.test/_matrix/client/v3/login", {
    "type": "m.login.password", "identifier": {"type": "m.id.user", "user": "local-operator"},
    "password": "test-only-local",
}))
assert local["user_id"] == "@local-operator:identity.stack.test"
try:
    request("https://matrix.stack.test/_matrix/client/v3/register", {
        "username": "unrestricted-registration", "password": "test-only-registration",
        "auth": {"type": "m.login.dummy"},
    })
except urllib.error.HTTPError as error:
    assert error.code == 403 and json.load(error)["errcode"] == "M_FORBIDDEN", error
else:
    raise AssertionError("Open Matrix registration was enabled")
