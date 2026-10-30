"""Real authorization-code/PKCE exchange through the isolated integration proxy."""
import html
import http.cookiejar
import json
import quopri
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

cookies = http.cookiejar.CookieJar()
browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))


def request(url, data=None, token=None):
    headers = {"Authorization": "Bearer " + token} if token else {}
    if isinstance(data, dict):
        data = urllib.parse.urlencode(data).encode()
    return browser.open(urllib.request.Request(url, data=data, headers=headers), timeout=30)

if "--magic" in sys.argv:
    mail = quopri.decodestring(Path("/test/portal-mail.log").read_bytes())
    links = [url.decode("ascii") for url in
             re.findall(rb"https://portal\.stack\.test/anmelden/[A-Za-z0-9]{64}", mail)]
    assert links, "The local administrator mail was not delivered to the test transport"
    response = request(links[-1])
    page = response.read().decode()
    token = re.search(r'name="_token"[^>]*value="([^"]+)"', page)
    assert token, "Magic-link confirmation missing"
    response = request(links[-1], {"_token": html.unescape(token[1])})
    assert urllib.parse.urlparse(response.url).path in ("/", "/willkommen"), response.url
    response = request("https://portal.stack.test/admin")
    assert "/admin" in response.url, "Local system administrator lost admin access"
    print("Local system administrator magic-link login and admin access passed.")
    sys.exit(0)


auth = json.load(request("https://login.stack.test/realms/master/protocol/openid-connect/token", {
    "client_id": "admin-cli", "grant_type": "password",
    "username": "kcadmin", "password": "test-only-integration",
}))
for name in (() if "--repeat" in sys.argv else
             ("portal-member", "portal-unverified", "portal-inactive", "portal-unknown")):
    payload = json.dumps({
        "username": name, "email": name + "@stack.test", "emailVerified": name != "portal-unverified",
        "firstName": "Test", "lastName": "Member", "enabled": True,
        "credentials": [{"type": "password", "value": "test-only-member", "temporary": False}],
    }).encode()
    browser.open(urllib.request.Request(
        "https://login.stack.test/admin/realms/feuerwehr/users", data=payload,
        headers={"Authorization": "Bearer " + auth["access_token"], "Content-Type": "application/json"}))

for name, success in (("portal-member", True), ("portal-member", True),
                      ("portal-unverified", False), ("portal-inactive", False), ("portal-unknown", False)):
    cookies.clear()
    page = request("https://portal.stack.test/anmelden").read().decode()
    assert "/auth/oidc/redirect" in page, "SSO button missing"
    response = request("https://portal.stack.test/auth/oidc/redirect")
    assert "login.stack.test" in response.url, response.url
    query = urllib.parse.parse_qs(urllib.parse.urlparse(response.url).query)
    assert query["code_challenge_method"] == ["S256"]
    assert query["redirect_uri"] == ["https://portal.stack.test/auth/oidc/callback"]
    page = response.read().decode()
    action = html.unescape(re.search(r'<form[^>]*action="([^"]+)"', page)[1])
    response = request(action, {"username": name, "password": "test-only-member", "credentialId": ""})
    page = response.read().decode()
    if success:
        assert urllib.parse.urlparse(response.url).path in ("/", "/willkommen"), response.url
        try:
            request("https://portal.stack.test/admin")
        except urllib.error.HTTPError as error:
            assert error.code == 403, error.code
        else:
            raise AssertionError("SSO user gained admin access")
    else:
        assert urllib.parse.urlparse(response.url).path == "/anmelden", response.url
    print("WehrPortal SSO account check passed:", name, success)

cookies.clear()
page = request("https://portal.stack.test/anmelden/lokal").read().decode()
token = re.search(r'name="_token"[^>]*value="([^"]+)"', page)
if token is None:
    token = re.search(r'name="csrf-token"[^>]*content="([^"]+)"', page)
assert token, "Local magic-link form missing"
response = request("https://portal.stack.test/anmelden", {
    "_token": html.unescape(token[1]), "email": "admin@stack.test",
})
assert "/anmelden/gesendet" in response.url, response.url
print("Local administrator magic-link request accepted (test mail transport).")
