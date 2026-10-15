#!/usr/bin/env python3
import os
from pathlib import Path

import yaml

config_path = Path("/data/homeserver.yaml")
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
config["allow_registration"] = False
config["report_stats"] = False
if os.environ.get("MATRIX_FEDERATION", "false").lower() != "true":
    config["federation_domain_whitelist"] = []
for listener in config.get("listeners", []):
    for resource in listener.get("resources", []):
        names = resource.get("names", [])
        if os.environ.get("MATRIX_FEDERATION", "false").lower() != "true":
            resource["names"] = [name for name in names if name != "federation"]
config_path.write_text(yaml.safe_dump(config, sort_keys=False))
config_path.chmod(0o600)
