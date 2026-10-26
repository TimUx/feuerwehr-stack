#!/usr/bin/env python3
"""Translate the resolved Compose model into a Docker Swarm stack file.

`docker stack deploy` ignores or rejects several Compose-only options, and the
Traefik swarm provider only reads labels below `deploy.labels`. The model is
therefore taken from `docker compose config --format json` (profiles and .env
interpolation already applied) and rewritten for Swarm.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

UNSUPPORTED = (
    "depends_on", "profiles", "security_opt", "mem_limit", "memswap_limit", "cpus",
    "restart", "container_name", "pull_policy", "build",
)


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def compose_model(root):
    command = ["docker", "compose", "--project-directory", str(root), "-f", str(root / "compose.yml")]
    for name in ("compose.proxy.yml", "compose.remote.yml"):
        if (root / name).is_file():
            command += ["-f", str(root / name)]
    command += ["config", "--format", "json"]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        fail(f"docker compose config failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def node_id():
    if os.environ.get("SWARM_NODE_ID"):
        return os.environ["SWARM_NODE_ID"]
    result = subprocess.run(
        ["docker", "info", "--format", "{{.Swarm.NodeID}} {{.Swarm.ControlAvailable}}"],
        capture_output=True, text=True, check=False,
    )
    parts = result.stdout.split()
    if result.returncode != 0 or len(parts) != 2 or not parts[0] or parts[1] != "true":
        fail("This host is not a Docker Swarm manager (run 'docker swarm init' or use DEPLOY_MODE=compose).")
    return parts[0]


def convert_secrets(model):
    # Swarm secrets are immutable; a content hash in the name lets changed files redeploy cleanly.
    renames = {}
    secrets = {}
    used = {
        entry if isinstance(entry, str) else entry["source"]
        for service in model["services"].values()
        for entry in service.get("secrets", [])
    }
    for key in used:
        definition = model.get("secrets", {}).get(key)
        if not definition or "file" not in definition:
            fail(f"Secret {key} must be defined with a file")
        path = Path(definition["file"])
        if not path.is_file():
            fail(f"Secret file is missing: {path}")
        data = path.read_bytes()
        if not data:
            # Swarm rejects empty secrets; a single newline is stripped by the entrypoints' $(cat ...).
            path = path.with_name(path.name + ".swarm")
            path.write_bytes(b"\n")
            path.chmod(0o644)
            data = b"\n"
        renamed = f"{key}_{hashlib.sha256(data).hexdigest()[:8]}"
        renames[key] = renamed
        secrets[renamed] = {"file": str(path)}
    return renames, secrets


def convert_networks(model):
    networks = {}
    for key, definition in (model.get("networks") or {}).items():
        definition = definition or {}
        if definition.get("external"):
            networks[key] = {"external": True, "name": definition["name"]}
        else:
            networks[key] = {"driver": "overlay"}
            if definition.get("internal"):
                networks[key]["internal"] = True
    return networks


def convert_service(service, node, renames, create_dirs):
    deploy = service.pop("deploy", None) or {}
    labels = service.pop("labels", None) or {}
    if isinstance(labels, list):
        labels = dict(item.split("=", 1) for item in labels)
    if labels:
        deploy.setdefault("labels", {}).update({k: str(v) for k, v in labels.items()})

    limits = deploy.setdefault("resources", {}).setdefault("limits", {})
    if service.get("mem_limit") is not None:
        limits["memory"] = str(service["mem_limit"])
    if service.get("cpus") is not None:
        limits["cpus"] = str(service["cpus"])
    if not limits:
        deploy["resources"].pop("limits")
    if not deploy["resources"]:
        deploy.pop("resources")

    deploy.setdefault("replicas", 1)
    deploy.setdefault("restart_policy", {"condition": "any", "delay": "5s"})
    # Bind-mounted data and file secrets only exist on this node.
    deploy.setdefault("placement", {})["constraints"] = [f"node.id == {node}"]
    service["deploy"] = deploy

    for option in UNSUPPORTED:
        service.pop(option, None)

    volumes = []
    for volume in service.get("volumes", []):
        if isinstance(volume, dict) and volume.get("type") == "bind":
            volume = dict(volume)
            options = dict(volume.pop("bind", None) or {})
            options.pop("create_host_path", None)
            if options:
                volume["bind"] = options
            source = Path(volume["source"])
            if create_dirs and not source.exists() and not volume.get("read_only"):
                source.mkdir(parents=True, mode=0o750)
        volumes.append(volume)
    if volumes:
        service["volumes"] = volumes

    if service.get("secrets"):
        converted = []
        for entry in service["secrets"]:
            source = entry if isinstance(entry, str) else entry["source"]
            target = source if isinstance(entry, str) else entry.get("target") or source
            # Compose normalises targets to /run/secrets/<name>; Swarm expects the file name.
            converted.append({"source": renames[source], "target": os.path.basename(target)})
        service["secrets"] = converted
    return {key: value for key, value in service.items() if value is not None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root")
    parser.add_argument("--output", help="Target file (default: ROOT/stack.swarm.yml)")
    parser.add_argument("--create-bind-dirs", action="store_true",
                        help="Create missing writable bind-mount directories")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    output = Path(args.output) if args.output else root / "stack.swarm.yml"
    model = compose_model(root)
    node = node_id()
    renames, secrets = convert_secrets(model)
    stack = {
        "version": "3.8",
        "services": {
            name: convert_service(service, node, renames, args.create_bind_dirs)
            for name, service in model["services"].items()
        },
        "networks": convert_networks(model),
    }
    if secrets:
        stack["secrets"] = secrets
    # JSON is valid YAML and keeps the output free of a YAML library dependency.
    output.write_text(json.dumps(stack, indent=2) + "\n", encoding="utf-8")
    if str(output) != os.devnull:
        output.chmod(0o640)


if __name__ == "__main__":
    main()
