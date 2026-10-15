#!/bin/bash
set -Eeuo pipefail

JWT_SECRET=$(cat /run/secrets/onlyoffice_jwt_secret)
export JWT_ENABLED=true JWT_SECRET
exec /app/ds/run-document-server.sh
