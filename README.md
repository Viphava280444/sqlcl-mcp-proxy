# sqlcl-mcp-proxy

Small HTTP bridge for Oracle SQLcl's MCP server.

## Need

- Java 17+
- Python 3.10+
- Oracle SQLcl 25.2+ — [download here](https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/download/)
- An Oracle DB you can reach

## Install

```bash
git clone https://github.com/Viphava280444/sqlcl-mcp-proxy.git
cd sqlcl-mcp-proxy
export SQLCL_HOME=/path/to/sqlcl
./install.sh
```

`install.sh` creates `.venv/` and installs `mcp-proxy` in it.

## Set path (every new shell)

`SQLCL_HOME` is needed by every script (install, add-db, apply-config, start). `TNS_ADMIN` is needed only if you use TNS aliases.

```bash
export SQLCL_HOME=/path/to/sqlcl
export TNS_ADMIN=/path/to/tnsnames_dir   # only for TNS
```

Tip: put those two lines at the end of `~/.bashrc` (or `~/.zshrc`) so every new shell has them ready. Or keep them in a small file and `source ./my_env.sh` per session.

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


### archi

Add this block to your archi YAML config (e.g. `configs/comp_ops/comp_ops_config_smoke.yaml`) at the top level:

```yaml
mcp_servers:
  sqlcl:
    transport: streamable_http
    url: http://127.0.0.1:8080/mcp
```

Add this paragraph to your archi agent prompt file (the file pointed to by `services.chat_app.agents_dir` in the config) so the agent shows the SQL it ran:

````text
When your final answer is based on data from the Oracle MCP tools (run-sql / run-sqlcl), your response MUST begin with a Markdown fenced code block containing the specific SQL or SQLcl statement(s) that produced the data in your answer. The fence MUST use three backticks followed by the language tag `sql`. Exact format, including the backticks:

```sql
SELECT ... FROM ... WHERE ... ;
```

After the closing triple backticks, write your natural-language answer on the next line. ONLY include the query (or small set of queries) whose results are in your answer — do NOT include exploratory or failed attempts (schema lookups, `DESC` commands, retries, queries that errored, etc.).
````


## Add more databases later

No restart needed. Run `./add-db.sh` or edit `config/connections.conf` + `./apply-config.sh`. The LLM sees new DBs on its next `list-connections` call. See [docs/adding-databases.md](docs/adding-databases.md) for details.

