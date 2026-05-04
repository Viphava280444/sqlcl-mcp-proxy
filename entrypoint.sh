#!/usr/bin/env bash
# Sidecar entrypoint:
#   1. Wipe any prior .dbtools/ state so saved-connections come solely from
#      the mounted connections.conf (otherwise `docker restart` preserves the
#      writable layer and apply-config.sh's CONN -save -replace can't delete
#      removed sections — live-remove would silently fail).
#   2. If a connections.conf is mounted, register every connection inside it.
#   3. exec start.sh, which is mcp-proxy --pass-environment -- sql -mcp.
set -euo pipefail

DBTOOLS=/opt/sqlcl-mcp-proxy/.dbtools
if [[ -d "$DBTOOLS" ]]; then
  echo "[entrypoint] Wiping prior .dbtools/ state ($DBTOOLS)"
  rm -rf "$DBTOOLS"
fi

CONF=/opt/sqlcl-mcp-proxy/config/connections.conf
if [[ -f "$CONF" ]]; then
  echo "[entrypoint] Registering connections from $CONF"
  ./apply-config.sh "$CONF"
else
  echo "[entrypoint] WARNING: $CONF not mounted — no DBs will be registered."
  echo "[entrypoint] See README §archi sidecar."
fi

exec ./start.sh
