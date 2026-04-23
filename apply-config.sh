#!/usr/bin/env bash
# Bulk-save SQLcl connections from config/connections.conf (INI format).
# Safe to re-run; uses CONN -save -replace.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/bin/env.sh"

[[ -n "${SQLCL_BIN:-}" ]] || { echo "SQLCL_HOME not set or invalid. See README."; exit 1; }

CONFIG="${1:-$CONFIG_FILE}"
if [[ ! -f "$CONFIG" ]]; then
  echo "Config not found: $CONFIG"
  echo "Copy $CONFIG_EXAMPLE to $CONFIG and edit it, or pass a path as an argument."
  exit 1
fi

# Expand ${VAR} references using the current environment.
expand_env() {
  local s="$1" var val
  while [[ "$s" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    var="${BASH_REMATCH[1]}"
    val="${!var-}"
    s="${s/\$\{$var\}/$val}"
  done
  printf '%s' "$s"
}

emit() {
  local name="$1" user="$2" tns="$3" url="$4" pass="$5"

  # Exactly one of tns/url is required.
  if [[ -n "$tns" && -n "$url" ]]; then
    echo "-- skipping $name: both 'tns' and 'url' set (pick one)" >&2; return
  fi
  if [[ -z "$tns" && -z "$url" ]]; then
    echo "-- skipping $name: neither 'tns' nor 'url' set" >&2; return
  fi
  if [[ -z "$user" ]]; then
    echo "-- skipping $name: no user" >&2; return
  fi

  pass="$(expand_env "${pass:-${ORACLE_PASS:-}}")"
  if [[ -z "$pass" ]]; then
    echo "-- skipping $name: no password (set 'password =' in section, or export ORACLE_PASS)" >&2; return
  fi

  local target="${tns:-$url}"
  echo "CONN -save $name -savepwd -replace $user/$pass@$target"
}

{
  name="" user="" tns="" url="" pass=""
  while IFS= read -r raw; do
    # strip comments + leading/trailing whitespace
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      [[ -n "$name" ]] && emit "$name" "$user" "$tns" "$url" "$pass"
      name="${BASH_REMATCH[1]}"; user=""; tns=""; url=""; pass=""
    elif [[ "$line" =~ ^([A-Za-z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      case "${BASH_REMATCH[1]}" in
        user)     user="${BASH_REMATCH[2]}";;
        tns)      tns="${BASH_REMATCH[2]}";;
        url)      url="${BASH_REMATCH[2]}";;
        password) pass="${BASH_REMATCH[2]}";;
      esac
    fi
  done < "$CONFIG"
  [[ -n "$name" ]] && emit "$name" "$user" "$tns" "$url" "$pass"

  echo "CONNMGR LIST"
  echo "EXIT"
} | "$SQLCL_BIN" /NOLOG
