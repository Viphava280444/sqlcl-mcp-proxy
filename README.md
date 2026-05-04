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


## Run as archi sidecar (recommended)

Have archi spawn the proxy as a Docker sidecar instead of running it as a host process. Matches Hasan's PR #557 pattern (`build_context` + `host_file_mounts` + `skill`). Operator never installs SQLcl, Java, or Python on their host.

1. Clone this repo onto the archi host:
   ```bash
   git clone https://github.com/Viphava280444/sqlcl-mcp-proxy.git \
     /home/<you>/Archi/sqlcl-mcp-proxy
   ```

2. Create a connections file outside the clone, owner-only. One section per DB. Use TNS aliases (`tns = INT2R`) — `/etc/tnsnames.ora` is mounted in for you — or Easy Connect URLs (`url = //host:port/svc`).
   ```ini
   # /home/<you>/sqlcl-connections.conf  — chmod 600
   [CMS_T0AST_REPLAY1]
   user     = archi_ro
   tns      = INT2R
   password = <the-password>
   ```

3. Add this `mcp_servers.sqlcl` block to your archi config (e.g. `cms-compops/configs/comp_ops/comp_ops_config.yaml`):
   ```yaml
   mcp_servers:
     sqlcl:
       transport: streamable_http
       url: http://localhost:8080/mcp
       build_context: /home/<you>/Archi/sqlcl-mcp-proxy
       skill: sqlcl_mcp
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

4. `a2rchi create --name <deployment> --config <path-to-config> --podman` (or your archi-flavor equivalent). The build downloads SQLcl, mounts your conf, and brings up the sidecar. The chatbot reaches it at `http://localhost:8080/mcp` (requires `host_mode: true` for the deployment).

To **add a database later**, edit `~/sqlcl-connections.conf` and `docker compose restart sqlcl-mcp` — no image rebuild needed.

A long-running query is killed at 60 s by `oracle.jdbc.ReadTimeout`. Tune via the `JAVA_TOOL_OPTIONS` env above.

The agent's read-only policy lives in `cms-compops/configs/comp_ops/skills/sqlcl_mcp.md`. archi loads it once per turn (PR #557) and appends to the system prompt. Don't also keep the policy inside the agent prompt file — they would duplicate.

