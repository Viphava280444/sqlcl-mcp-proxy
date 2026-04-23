#!/usr/bin/env bash
# Launch mcp-proxy in the foreground, bridging SQLcl's MCP server to HTTP/SSE.
# Endpoints:
#   http://HOST:PORT/mcp  — streamable HTTP
#   http://HOST:PORT/sse  — legacy SSE
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/bin/env.sh"

[[ -n "${SQLCL_BIN:-}" ]] || { echo "SQLCL_HOME not set or invalid. See README."; exit 1; }
[[ -x "$VENV_BIN/mcp-proxy" ]] || { echo "mcp-proxy not installed. Run ./install.sh first."; exit 1; }

HOST="${MCP_PROXY_HOST:-127.0.0.1}"
PORT="${MCP_PROXY_PORT:-8080}"

echo "Starting mcp-proxy on http://$HOST:$PORT (backed by $SQLCL_BIN -mcp)"
echo "Ctrl+C to stop."
exec "$VENV_BIN/mcp-proxy" \
  --pass-environment \
  --host "$HOST" \
  --port "$PORT" \
  -- "$SQLCL_BIN" -mcp
