#!/usr/bin/env bash
set -Eeuo pipefail

# Harness rejects wildcard listeners; Docker supplies this container's bridge IP.
read -r bind_ip _ <<< "$(hostname -i)"
exec node /app/apps/cli/lib/bin.js --profile web --no-open \
  --host "$bind_ip" --port 3080 \
  --public-url http://127.0.0.1:3080/ --trusted-host localhost "$@"
