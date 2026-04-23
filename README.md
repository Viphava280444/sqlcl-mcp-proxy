# sqlcl-mcp-proxy

Small HTTP bridge for Oracle SQLcl's MCP server. Lets any MCP-aware LLM (Claude Desktop, Cline, archi, your own) query your Oracle databases.

## Need

- Java 17+
- Python 3.10+
- Oracle SQLcl 25.2+ — [download here](https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/download/)
- An Oracle DB you can reach

## Install

```bash
git clone <this-repo>.git
cd sqlcl-mcp-proxy
export SQLCL_HOME=/path/to/sqlcl
./install.sh
```

`install.sh` creates `.venv/` and installs `mcp-proxy` in it.

## Save a database

Pick one.

**One at a time:**
```bash
# TNS alias
./add-db.sh mydb HR MY_TNS_ALIAS 'password'

# Easy Connect URL
./add-db.sh mydb scott //host:1521/service 'password'
```

**Bulk from config file:**
```bash
cp config/connections.conf.example config/connections.conf
vim config/connections.conf         # add your [sections]
./apply-config.sh
```

`chmod 600 config/connections.conf` if you write plaintext passwords there.

## Using TNS aliases?

Export `TNS_ADMIN` to the folder with your `tnsnames.ora` before running `./start.sh`:
```bash
export TNS_ADMIN=/path/to/tnsnames_dir
```

Skip this if all your connections use Easy Connect URLs.

## Run

```bash
./start.sh
```

Two endpoints come up:
- `http://127.0.0.1:8080/mcp` — streamable HTTP
- `http://127.0.0.1:8080/sse` — legacy SSE

Keep the terminal open, or put it in background:
```bash
nohup ./start.sh > /tmp/mcp-proxy.log 2>&1 &
disown
```

Change port or expose on the network:
```bash
MCP_PROXY_HOST=0.0.0.0 MCP_PROXY_PORT=3000 ./start.sh
```
Warning: `0.0.0.0` = anyone who can reach your port can run SQL. No auth.

## Connect an LLM client

Point it at `http://127.0.0.1:8080/mcp`. Works with Claude Desktop, Cline, archi, mcp-inspector, or any MCP-HTTP client.

## Add more databases later

No restart needed. Run `./add-db.sh` or edit `config/connections.conf` + `./apply-config.sh`. The LLM sees new DBs on its next `list-connections` call. See [docs/adding-databases.md](docs/adding-databases.md) for details.

## Test

After `./start.sh` is running with at least one saved connection:
```bash
.venv/bin/python tests/smoke_test.py
```
Should print `Smoke test PASSED`.

## Troubleshoot

| Error | Fix |
|---|---|
| `SQLCL_HOME not set` | `export SQLCL_HOME=/path/to/sqlcl` |
| `mcp-proxy not installed` | run `./install.sh` first |
| `ORA-01005: null password` | re-run `./add-db.sh` or `./apply-config.sh` with the right password |
| `Connection named X not found` | use `sql -n X` (SQLcl 26.1+ needs the `-n` flag) |
| Port 8080 already used | `MCP_PROXY_PORT=3000 ./start.sh` |
| Agent says DB tool returns empty | proxy in bad state — `pkill -f mcp-proxy`, then start again |

## Files

| File | Purpose |
|---|---|
| `install.sh` | one-time setup: venv + mcp-proxy |
| `add-db.sh` | save one connection |
| `apply-config.sh` | save every connection from `config/connections.conf` |
| `start.sh` | run the proxy |
| `bin/env.sh` | helper sourced by the scripts |
| `config/connections.conf.example` | template |
| `tests/smoke_test.py` | end-to-end test |

## Security

- `config/connections.conf` is gitignored. Use `chmod 600` if plaintext passwords are in it.
- Passwords are stored in Oracle SSO wallet under `.dbtools/credentials.sso` (perms 0600).
- No auth on the HTTP endpoint. Default bind is `127.0.0.1` (local only). Change `MCP_PROXY_HOST` carefully.

## License

MIT — see [LICENSE](LICENSE).
