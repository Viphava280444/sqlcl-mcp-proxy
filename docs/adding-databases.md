# Adding databases

Two ways to save a connection; both write to the same `.dbtools/` wallet.

## One-shot CLI

```bash
./add-db.sh NAME USER TNS_OR_URL [PASSWORD]
```

If `PASSWORD` is omitted, it's read from stdin with echo disabled.

- `NAME` — the saved-connection name the LLM uses to switch databases.
- `USER` — database user.
- `TNS_OR_URL` — a TNS alias (requires `$TNS_ADMIN`) **or** an Easy Connect URL (starts with `//`).

Examples:
```bash
./add-db.sh prod_reader HR ORCL                      # prompts for password
./add-db.sh dev_admin scott //dev:1521/XEPDB1 tiger  # Easy Connect URL inline
```

## Bulk from config

Edit `config/connections.conf` (one-time: `cp config/connections.conf.example
config/connections.conf`), then:

```bash
./apply-config.sh
```

Every `[section]` becomes a saved connection. Rerun any time — `-replace`
updates existing entries in place.

## Live-add: the important property

**You do NOT need to restart `./start.sh` when adding a connection.**

Here's why: the SQLcl MCP server reads the connection store on every
`list-connections` call. So the flow is:

```
Terminal 1              Terminal 2                      LLM client
──────────              ──────────                      ──────────
$ ./start.sh            (idle)                          (idle)
                                                        | next LLM turn:
                        $ ./add-db.sh newdb ...         | list-connections()
                        Saved connection: newdb         | → sees newdb immediately
                                                        | connect(newdb)
                                                        | → works
```

The running proxy doesn't cache the connection list. Your LLM session
doesn't break. The new DB is just there.

## When a restart *is* required

- If you change `$TNS_ADMIN` or other env vars — those are frozen at
  `./start.sh` launch time.
- If you upgrade SQLcl itself — new `$SQLCL_HOME/bin/sql` binary means a
  restart to pick it up.
- If you change `.venv/` contents (e.g. `pip upgrade mcp-proxy`) — the proxy
  process was launched from the old binary.

## Removing a connection

SQLcl's own tooling:

```bash
source bin/env.sh        # not strictly needed, but convenient
"$SQLCL_BIN" -S /NOLOG <<'SQL'
CONNMGR DELETE -conn oldname
EXIT
SQL
```

Or edit `config/connections.conf` to remove the section, then run
`./apply-config.sh` — note: that does NOT delete removed sections,
`-replace` only overwrites existing ones. Deletion is always explicit via
`CONNMGR DELETE`.

## Password sources (precedence)

For each saved section the password is resolved in this order:

1. Literal value after `password = ` in the section
2. `${ENV_VAR}` expansion from the current shell
3. `$ORACLE_PASS` env var (fallback)

If all three are empty/unset, the section is skipped with a warning.
