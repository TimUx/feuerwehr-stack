from pathlib import Path
import yaml

config = yaml.safe_load(Path("/data/homeserver.yaml").read_text())
assert Path("/run/secrets/synapse_oidc_client_secret").read_text().strip() not in \
    Path("/data/homeserver.yaml").read_text()
provider = next(p for p in config["oidc_providers"] if p["idp_id"] == "keycloak")
assert "client_secret" not in provider
assert provider["client_secret_path"] == "/run/secrets/synapse_oidc_client_secret"
assert provider["allow_existing_users"] is False
assert provider["enable_registration"] is True
assert config["enable_registration"] is False
assert config["public_baseurl"] == "https://matrix.stack.test/"
assert provider["pkce_method"] == "always"
