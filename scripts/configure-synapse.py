#!/usr/bin/env python3
import os
import tempfile
from pathlib import Path

import yaml

config_path = Path(os.environ.get("SYNAPSE_CONFIG_PATH", "/data/homeserver.yaml"))
secret_path = Path("/run/secrets/synapse_db_password")
config = yaml.safe_load(config_path.read_text())
config["server_name"] = os.environ["SYNAPSE_SERVER_NAME"]
config["database"] = {
    "name": "psycopg2",
    "args": {
        "user": "synapse",
        "password": secret_path.read_text().strip(),
        "database": "synapse",
        "host": "postgres",
        "cp_min": 5,
        "cp_max": 10,
    },
}
config.pop("allow_registration", None)
config["enable_registration"] = False
config["report_stats"] = False
config["public_baseurl"] = "https://" + os.environ["MATRIX_HOST"] + "/"
providers = [p for p in config.get("oidc_providers", []) if p.get("idp_id") != "keycloak"]
if os.environ.get("MATRIX_OIDC_ENABLED") == "true":
    oidc_secret = Path("/run/secrets/synapse_oidc_client_secret")
    if not oidc_secret.is_file() or not oidc_secret.read_text().strip():
        raise RuntimeError("Missing or empty Synapse OIDC client secret")
    providers.append({
        "idp_id": "keycloak",
        "idp_name": "Keycloak",
        "issuer": "https://" + os.environ["KEYCLOAK_HOST"] + "/realms/" + os.environ["KEYCLOAK_REALM"],
        "client_id": "synapse",
        "client_secret_path": str(oidc_secret),
        "client_auth_method": "client_secret_basic",
        "scopes": ["openid", "profile"],
        "pkce_method": "always",
        "allow_existing_users": False,
        "enable_registration": True,
        "user_mapping_provider": {
            "config": {
                "subject_claim": "sub",
                "localpart_template": "{{ user.preferred_username }}",
                "display_name_template": "{{ user.name }}",
            },
        },
    })
config["oidc_providers"] = providers
# Trust only the stack's web client for returning a login token without confirmation.
sso = config.setdefault("sso", {})
managed_origin = config.pop("feuerwehr_stack_sso_client_origin", None)
whitelist = [uri for uri in sso.get("client_whitelist", []) if uri != managed_origin]
if os.environ.get("MATRIX_OIDC_ENABLED") == "true":
    origin = "https://" + os.environ["FLUFFYCHAT_HOST"] + "/"
    if origin not in whitelist:
        whitelist.append(origin)
    config["feuerwehr_stack_sso_client_origin"] = origin
sso["client_whitelist"] = whitelist
if os.environ.get("MATRIX_FEDERATION", "false").lower() != "true":
    config["federation_domain_whitelist"] = []
for listener in config.get("listeners", []):
    for resource in listener.get("resources", []):
        names = resource.get("names", [])
        if os.environ.get("MATRIX_FEDERATION", "false").lower() != "true":
            resource["names"] = [name for name in names if name != "federation"]
with tempfile.NamedTemporaryFile(mode="w", dir=config_path.parent, delete=False) as target:
    temporary_path = Path(target.name)
    try:
        target.write(yaml.safe_dump(config, sort_keys=False))
        target.flush()
        os.fchmod(target.fileno(), 0o600)
        os.fchown(target.fileno(), 991, 991)
        os.replace(temporary_path, config_path)
    finally:
        temporary_path.unlink(missing_ok=True)
