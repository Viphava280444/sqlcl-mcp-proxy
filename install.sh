#!/usr/bin/env bash
# One-time setup: verify prereqs, create .venv, install mcp-proxy.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Prereq checks — minimal, actionable.
: "${SQLCL_HOME:?Set SQLCL_HOME to the directory containing bin/sql (example: export SQLCL_HOME=/opt/sqlcl)}"
[[ -x "$SQLCL_HOME/bin/sql" ]] || { echo "SQLcl binary not found at \$SQLCL_HOME/bin/sql (\$SQLCL_HOME=$SQLCL_HOME)"; exit 1; }
command -v java    >/dev/null || { echo "Install Java 17+ and put 'java' on PATH"; exit 1; }

# Prefer python3.12+ (mcp-proxy requires 3.10+); fall back to python3.
PYTHON="$(command -v python3.12 || command -v python3)"
[[ -x "$PYTHON" ]] || { echo "Install Python 3.10+ and put 'python3.12' or 'python3' on PATH"; exit 1; }

echo "Prereqs OK: SQLCL_HOME=$SQLCL_HOME"

# Create venv if absent
if [[ ! -d .venv ]]; then
  echo "Creating .venv with $("$PYTHON" --version)"
  "$PYTHON" -m venv .venv
fi

# Install / upgrade mcp-proxy inside the venv
echo "Installing mcp-proxy into .venv"
.venv/bin/pip install --upgrade pip --quiet
.venv/bin/pip install --upgrade -r requirements.txt --quiet

# Re-pin the exact resolved versions so teammates get reproducible installs.
.venv/bin/pip freeze > requirements.lock.txt

echo "Install complete. mcp-proxy version: $(.venv/bin/mcp-proxy --version 2>&1 | head -1)"
