# sqlcl-mcp-proxy

HTTP-streamable MCP endpoint backed by Oracle SQLcl. Lets an LLM client query
one or more Oracle databases (TNS or Easy Connect) through the standardized
Model Context Protocol.

## What it does

Starts a small HTTP server that accepts MCP tool calls from an LLM client
(Claude Desktop, Cline, your own) and forwards them to Oracle SQLcl's MCP
server mode. The LLM can `list-connections`, `connect`, `run-sql`, and more
against any Oracle DB you've saved.

Multiple databases are supported out of the box — the LLM switches between
saved connections at tool-call time. New databases can be added without
restarting anything.

## Prerequisites

- **Java 17+** (required by SQLcl)
- **Oracle SQLcl 25.2+** — [download from Oracle](https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/download/)
- **Python 3.10+** with `python3` on PATH
- Network access to your Oracle database(s)

## Install

```bash
git clone https://github.com/YOU/sqlcl-mcp-proxy.git
cd sqlcl-mcp-proxy
export SQLCL_HOME=/path/to/sqlcl   # directory containing bin/sql
./install.sh
```

`install.sh` creates `.venv/` and installs `mcp-proxy` inside it.

## Add your first database

Quickest path — one command:

```bash
./add-db.sh mydb HR ORCL                 # TNS alias; prompts for password
./add-db.sh mydb scott //host:1521/XEPDB1 tiger   # Easy Connect URL
```

Or edit a config file:

```bash
cp config/connections.conf.example config/connections.conf
vim config/connections.conf                       # edit, then save
./apply-config.sh                                 # saves every section
```

See `config/connections.conf.example` for the full file format.

> **Using TNS aliases?** Export `TNS_ADMIN=/path/to/tnsnames/dir` before
> running `./start.sh` so SQLcl can resolve aliases. Skip this if you only
> use Easy Connect URLs.

## Run the proxy

```bash
./start.sh                    # foreground, 127.0.0.1:8080
```

Two endpoints become available:
- `http://127.0.0.1:8080/mcp` — streamable HTTP transport
- `http://127.0.0.1:8080/sse` — legacy SSE transport

Override the bind address / port via environment:

```bash
MCP_PROXY_HOST=0.0.0.0 MCP_PROXY_PORT=3000 ./start.sh
```

Keep `start.sh` running in a terminal (or under tmux/nohup/systemd).

## Connect an LLM client

Point any MCP-HTTP-aware client at one of the URLs above. Example clients:
Claude Desktop, Cline, mcp-inspector, your own SDK.

## Adding more databases later

You can add new DBs while the proxy is running. The LLM sees them on its
next `list-connections` tool call. No restart needed. See
[docs/adding-databases.md](docs/adding-databases.md) for details.

## Smoke test

After `./start.sh` is running and at least one connection is saved:

```bash
.venv/bin/python tests/smoke_test.py
```

Runs an end-to-end check (MCP init → list → connect → run-sql).

## Troubleshooting

**`SQLCL_HOME not set or invalid`** — export `SQLCL_HOME=/path/to/sqlcl` (the
directory, not the `sql` binary).

**`mcp-proxy not installed. Run ./install.sh first.`** — you haven't created
the venv yet.

**`ORA-01005: null password given`** — the wallet isn't storing the password.
Re-run `./add-db.sh` or `./apply-config.sh`; make sure the password is
non-empty and you used the `-savepwd` flag (the scripts do).

**`Connection named X not found`** — SQLcl 26.1+ requires `-name` / `-n` to
reference saved connections. The proxy handles this; for manual use do:
`sql -n X`, not `sql X`.

**Port 8080 already in use** — set `MCP_PROXY_PORT=<other>` in the
environment before running `./start.sh`.

## Files

| Path | Purpose |
|---|---|
| `install.sh` | One-time: create venv, install mcp-proxy |
| `add-db.sh` | Save one connection |
| `apply-config.sh` | Save every connection from `config/connections.conf` |
| `start.sh` | Run the proxy |
| `bin/env.sh` | Internal helper (sourced by others) |
| `config/connections.conf.example` | Documented template |
| `tests/smoke_test.py` | End-to-end test |

## Security notes

- `config/connections.conf` is gitignored. Passwords in it are plaintext
  unless you use `${ENV_VAR}` references. `chmod 600` recommended.
- `.dbtools/credentials.sso` is Oracle's SSO wallet, readable only by your
  user.
- The proxy has no authentication. By default it binds to `127.0.0.1`, which
  means only this machine can connect. If you set `MCP_PROXY_HOST=0.0.0.0`,
  anyone reachable on the port can execute SQL as your saved users.

## License

MIT — see [LICENSE](LICENSE).
