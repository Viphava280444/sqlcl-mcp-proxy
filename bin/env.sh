# Internal helper — sourced by install.sh, add-db.sh, apply-config.sh, start.sh.
# Not meant to be run directly.

# Resolve repo root relative to this file's location (portable across checkouts).
_BIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$_BIN_DIR")"
unset _BIN_DIR

# SQLCL_HOME is required for everything except install.sh's early prereq phase.
if [[ -n "${SQLCL_HOME:-}" && -x "${SQLCL_HOME}/bin/sql" ]]; then
  SQLCL_BIN="${SQLCL_HOME}/bin/sql"
fi

# Derived paths
VENV_BIN="${REPO_ROOT}/.venv/bin"
CONFIG_FILE="${REPO_ROOT}/config/connections.conf"
CONFIG_EXAMPLE="${REPO_ROOT}/config/connections.conf.example"

# Keep the SQLcl wallet inside the repo checkout on local disk.
# SQLcl uses the JVM's user.home to locate ~/.dbtools, so we redirect it.
export JAVA_TOOL_OPTIONS="-Duser.home=${REPO_ROOT}"

# TNS_ADMIN is user-set. We pass through whatever they export.
# If they don't use TNS aliases, no problem — SQLcl ignores it.
