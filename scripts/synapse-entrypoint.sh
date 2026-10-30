#!/bin/sh
set -eu

if [ "${1:-run}" = generate ]; then
    exec /start.py "$@"
fi
if [ ! -f "${SYNAPSE_CONFIG_PATH:-/data/homeserver.yaml}" ]; then
    /start.py generate
fi
python /stack/configure_synapse.py
exec /start.py "$@"
