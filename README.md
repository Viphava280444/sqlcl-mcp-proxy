# sqlcl-mcp-proxy

Small HTTP bridge for Oracle SQLcl's MCP server. Lets an LLM agent (e.g. via archi) run read-only Oracle queries through MCP.

Two ways to deploy:
- **[Archi sidecar](#run-as-archi-sidecar-recommended)** — archi spawns the proxy as a Docker sidecar; nothing installed on the archi host. **Recommended.**
- **[Standalone](#run-standalone)** — install Java + Python + SQLcl on the host yourself, run `./start.sh` directly.

---

## Run as archi sidecar (recommended)


### 1. Clone this repo onto the archi host

```bash
git clone https://github.com/Viphava280444/sqlcl-mcp-proxy.git \
  /home/<you>/Archi/sqlcl-mcp-proxy
```

### 2. Create a connections file outside the clone (chmod 600)

One section per DB. Use TNS aliases (`tns = INT2R`) — `/etc/tnsnames.ora` is mounted in for you — or Easy Connect URLs (`url = //host:port/svc`).

```ini
# /home/<you>/sqlcl-connections.conf  — chmod 600
[CMS_T0AST_REPLAY1]
user     = archi_ro
tns      = INT2R
password = <the-password>
```

### 3. Drop in the skill prompt **(required)**

The skill prompt is what makes the agent read-only, prompt-injection resistant, and SQL-transparent. **Without it the agent will run any SQL the user asks for, including `DROP TABLE`.** You can't get this from the SQLcl MCP server alone — the policy lives at the agent layer.

This repo ships a canonical template at [`archi/sqlcl_mcp.md`](archi/sqlcl_mcp.md). Copy it into your archi skills directory:

```bash
cp archi/sqlcl_mcp.md \
  /home/<you>/cms-compops/configs/comp_ops/skills/sqlcl_mcp.md
```

The destination filename must match the `skill:` field of your `mcp_servers.sqlcl` block (default `sqlcl_mcp` → `sqlcl_mcp.md`). You may extend the file with domain-specific guidance — but keep the **read-only policy** and **show-the-SQL-you-ran** sections intact.

### 4. Add the `mcp_servers.sqlcl` block to your archi config

(e.g. `cms-compops/configs/comp_ops/comp_ops_config.yaml`):

```yaml
mcp_servers:
  sqlcl:
    transport: streamable_http
    url: http://localhost:8080/mcp
    build_context: /home/<you>/Archi/sqlcl-mcp-proxy
    skill: sqlcl_mcp                    # matches archi skills/sqlcl_mcp.md from step 3
    env:
      JAVA_TOOL_OPTIONS: "-Doracle.jdbc.ReadTimeout=60000"
      MCP_PROXY_HOST: "0.0.0.0"
      MCP_PROXY_PORT: "8080"
    env_from_secrets: []
    host_file_mounts:
      - src: /home/<you>/sqlcl-connections.conf
        dest: /opt/sqlcl-mcp-proxy/config/connections.conf
      - src: /etc/tnsnames.ora
        dest: /opt/sqlcl-mcp-proxy/tnsnames.ora
```

### 5. Deploy

```bash
a2rchi create --name <deployment> --config <path-to-config> --podman
```

(or your archi-flavor equivalent). The build downloads SQLcl, mounts your conf, and brings up the sidecar. The chatbot reaches it at `http://localhost:8080/mcp` (requires `host_mode: true` for the deployment).

### Add a database later

Edit `~/sqlcl-connections.conf` and `docker compose restart sqlcl-mcp` — no image rebuild needed.

### Timeout behavior

A long-running query is killed at 60 s by `oracle.jdbc.ReadTimeout`. The driver throws `ORA-18730: Socket read timed out`; the agent reports it back to the user; the sidecar stays alive for the next request. Tune via the `JAVA_TOOL_OPTIONS` env in step 4.

---

## Run standalone

Use this if you're not deploying through archi (e.g. local development, a one-off test, or a non-archi orchestrator).

### Need

- Java 17+
- Python 3.10+
- Oracle SQLcl 25.2+ — [download here](https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/download/)
- An Oracle DB you can reach

### Install

```bash
git clone https://github.com/Viphava280444/sqlcl-mcp-proxy.git
cd sqlcl-mcp-proxy
export SQLCL_HOME=/path/to/sqlcl
./install.sh
```

`install.sh` creates `.venv/` and installs `mcp-proxy` in it.

### Set path (every new shell)

`SQLCL_HOME` is needed by every script (install, add-db, apply-config, start). `TNS_ADMIN` is needed only if you use TNS aliases.

```bash
export SQLCL_HOME=/path/to/sqlcl
export TNS_ADMIN=/path/to/tnsnames_dir   # only for TNS
```

Tip: put those two lines at the end of `~/.bashrc` (or `~/.zshrc`) so every new shell has them ready. Or keep them in a small file and `source ./my_env.sh` per session.

### Save a database

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

### Run

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
