#!/usr/bin/env bash
# Sidecar entrypoint:
#   1. If a connections.conf is mounted, register every connection inside it.
#   2. exec start.sh, which is mcp-proxy --pass-environment -- sql -mcp.
set -euo pipefail

CONF=/opt/sqlcl-mcp-proxy/config/connections.conf
if [[ -f "$CONF" ]]; then
  echo "[entrypoint] Registering connections from $CONF"
  ./apply-config.sh "$CONF"
else
  echo "[entrypoint] WARNING: $CONF not mounted — no DBs will be registered."
  echo "[entrypoint] See README §archi sidecar."
fi

exec ./start.sh
