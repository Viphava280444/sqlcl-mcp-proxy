#!/usr/bin/env bash
# Save one SQLcl connection on the fly. Proxy can stay running — new connections
# are visible to the LLM on its next list-connections tool call.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/bin/env.sh"

usage() {
  cat <<USAGE
Usage: $0 NAME USER TNS_OR_URL [PASSWORD]

  NAME         saved-connection name (what the LLM uses to switch)
  USER         database user
  TNS_OR_URL   a TNS alias (e.g. ORCL) or Easy Connect URL (e.g. //host:1521/svc)
  PASSWORD     optional; if absent, read from stdin with echo disabled

Examples:
  $0 prod_reader HR ORCL 'my_password'
  $0 dev_admin   scott //dev-db:1521/DEVPDB
USAGE
  exit 2
}

[[ $# -ge 3 && $# -le 4 ]] || usage
[[ -n "${SQLCL_BIN:-}" ]] || { echo "SQLCL_HOME not set or invalid. See README."; exit 1; }

NAME="$1"
USER="$2"
TARGET="$3"
if [[ $# -eq 4 ]]; then
  PASSWORD="$4"
else
  read -r -s -p "Password for ${USER}@${TARGET}: " PASSWORD; echo
fi

[[ -n "$PASSWORD" ]] || { echo "Password cannot be empty"; exit 1; }

# SQLcl accepts both 'user/pass@TNSALIAS' and 'user/pass@//host:port/svc' —
# no need to distinguish here.
"$SQLCL_BIN" /NOLOG <<SQL
CONN -save $NAME -savepwd -replace $USER/$PASSWORD@$TARGET
EXIT
SQL
echo "Saved connection: $NAME"
