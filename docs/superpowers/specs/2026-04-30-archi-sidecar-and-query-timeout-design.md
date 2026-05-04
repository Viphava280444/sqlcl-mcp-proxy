# Archi sidecar packaging + long-query timeout — design

Date: 2026-04-30
Author: Viphava
Status: Draft (post-audit)

## Context

Two action items from Hasan (CompOps weekly, 2026-04-30):

1. **Spawn the SQLcl MCP from archi instead of running it as a host process.** Today the user runs `mcp-proxy` via `nohup ./start.sh` on `127.0.0.1:8080`, and the chatbot reaches it via that URL. Hasan wants archi to own the container lifecycle, mirroring what he did for rucio-mcp.
2. **Investigate whether long-running Oracle queries can be killed.** Today nothing terminates a tool call mid-flight; a slow query can block until `services.chat_app.client_timeout_seconds` (default 600 s) fires.

The supporting infrastructure landed in archi PR #557 (`f496886a`, "Generic MCP sidecar + domain-knowledge skills + tool-use observability"):

- New `mcp_servers.<name>` schema fields: `transport`, `url`, `command`, `args`, `env`, `env_from_secrets`, `host_file_mounts`, `build_context`, `image`, `path`, `skill` (`base-config.yaml:13-44`).
- New compose render block that auto-generates a sidecar service for any entry with `build_context` or `image` (`base-compose.yaml:712-755`).
- `host_file_mounts` are mounted **read-only** (`:ro` is hard-coded in the template at lines 741, 743). `env_from_secrets` materializes Docker secrets at `/run/secrets/<name>` and exposes a `<NAME>_FILE` env var (lines 727-729).
- Top-level `secrets:` block (lines 764-770) only emits definitions for `required_secrets`, which `secrets_manager.get_secrets()` builds from every key in the deployment's `.env` file (`secrets_manager.py:40-44`).
- PR #557 added zero per-tool-call timeout machinery; topic 2 has to be solved below archi.

Hasan's deployed rucio-mcp is the canonical example (`/data/viphava-archi/hasan/cms-compops/configs/comp_ops/comp_ops_config.yaml:220-246`):

```yaml
mcp_servers:
  rucio:
    transport: streamable_http
    url: http://localhost:8000/mcp
    build_context: /home/haozturk/Archi/rucio-mcp
    skill: rucio_mcp
    env:
      RUCIO_HOST: http://cms-rucio.cern.ch
      RUCIO_AUTH_TYPE: x509_proxy
      X509_USER_PROXY: /tmp/x509up
      # …more env…
    env_from_secrets: []
    host_file_mounts:
      - /etc/pki/tls/certs/CERN-bundle.pem
      - src: /home/haozturk/.globus
        dest: /root/.globus
```

Three observations that drive every decision below:

1. Hasan uses `build_context:` (a path on his archi host), not `image:`. He clones each MCP source into `/home/haozturk/Archi/<mcp-name>/`.
2. `url: http://localhost:8000/mcp` implies `host_mode: true` is on for this deployment — every sidecar shares the host network namespace.
3. Credentials and CERN system files come in via `host_file_mounts:`, not Docker secrets. `env_from_secrets:` is empty. This matters because Hasan deploys with `--podman`, where Docker-style secrets are unreliable (`secrets_manager.py:148-150` writes a `.env` fallback for that reason).

## Audit findings the design must address

| # | Finding | Resolution |
|---|---|---|
| A | `sqlcl/` and `tnsnames.ora` are gitignored — Hasan's clone has no SQLcl binary or TNS file. | Stage 1 of Dockerfile downloads `sqlcl-latest.zip`. Hasan mounts `/etc/tnsnames.ora` via `host_file_mounts`. |
| B | `add-db.sh` and `apply-config.sh` report success on connection failure (SQLcl exits 0 even on `ORA-01017`). Silent failure surfaces only when the agent later finds zero saved connections. | Capture-and-grep fix in both scripts (§5, §6). |
| C | `bin/env.sh:21` unconditionally clobbers `JAVA_TOOL_OPTIONS`. | One-line append fix (§4). |
| D | Hasan deploys with `--podman`. `host_file_mounts` (plain volume mounts) is more reliable than `env_from_secrets` (Docker secrets) under podman-compose. | Use `host_file_mounts` for `connections.conf`; `env_from_secrets: []`. |
| E | Two parallel deployments: this user's smoke at `/data/viphava-archi/cms-compops/`, Hasan's prod at `/data/viphava-archi/hasan/cms-compops/`. Both reference `mcp_servers.sqlcl`. | Both get the same `mcp_servers.sqlcl` block; smoke is the user's pre-flight before Hasan rolls. |

## Goals

- Archi owns the SQLcl-MCP container lifecycle. Hasan never installs Java, SQLcl, or Python on his host. He clones the repo, drops one config file, edits `comp_ops_config.yaml`, runs `a2rchi create`.
- The image builds from any clone of the repo — SQLcl is downloaded during build, not bundled in source.
- A reproducible answer to "can we cap a single Oracle query at N seconds, end-to-end."

## Non-goals

- Live-add of a database without restarting the sidecar. Adding a DB = edit one file + restart sidecar. Seconds, not zero.
- Publishing a container image to a registry. Hasan's pattern is local clones; matching it is simpler. Re-evaluate if a multi-host or k8s deployment appears.
- Wiring the speculative `services.chat_app.tools.oracle_databases` block in Hasan's config. That field is not consumed by anything in upstream archi today.
- Changing archi itself. PR #557's primitives are the contract.
- Implementing per-tool-call timeout inside archi. Upstream change Hasan would own.

## Topic 1 — sidecar packaging

### Architecture

```
Hasan's archi host (host_mode: true, --podman)              Oracle (CMS T0AST_REPLAYn)
┌─────────────────────────────────────────────────────────┐
│ /home/haozturk/Archi/sqlcl-mcp-proxy/   (his clone)     │
│ /home/haozturk/sqlcl-connections.conf   (his secrets)   │
│ /etc/tnsnames.ora                       (CERN puppet)   │
│                                                         │
│ archi compose stack                                     │
│  ├── chatbot, data-manager, postgres, …                 │
│  └── sqlcl-mcp (sidecar from build_context)             │
│       │ image built per archi create:                   │
│       │   - downloads SQLcl 26.1.x at build time        │
│       │   - python venv + mcp-proxy installed           │
│       │ runtime mounts (read-only):                     │
│       │   /home/haozturk/sqlcl-connections.conf         │
│       │     → /opt/sqlcl-mcp-proxy/config/connections.conf │
│       │   /etc/tnsnames.ora                             │
│       │     → /opt/sqlcl-mcp-proxy/tnsnames.ora         │
│       │ on boot:                                        │
│       │   entrypoint.sh → apply-config.sh → start.sh    │── JDBC ──▶ INT2R / T0DB
│       │ chatbot reaches it at http://localhost:8080/mcp │
└─────────────────────────────────────────────────────────┘
```

### Components

#### 1. `Dockerfile` (new, at `/data/viphava/Dockerfile`)

Multi-stage. First stage downloads SQLcl from Oracle. Second stage carries that into a smaller image with Python venv + mcp-proxy.

**Build-time vs runtime split** (the rule that decides where each value lives):

| Value | Used at | Where it's set | Why |
|---|---|---|---|
| SQLcl bytes | `docker build` (T1) | Downloaded from `sqlcl-latest.zip` each build. No version pin, no SHA verification. | Internal CERN-ops tool with read-only DB access; reproducibility wouldn't pay off here. Trade-off discussed in §"Version pinning" below. |
| `SQLCL_HOME`, `TNS_ADMIN` | runtime, set by image | Dockerfile `ENV` | Internal paths coupled to where stage 1 unzips and where host_file_mounts land. Don't override at runtime. |
| `JAVA_TOOL_OPTIONS` | runtime, JVM startup | archi config `env:` | Needs to be tunable per deployment (timeout values may differ in dev vs prod). `bin/env.sh` appends `-Duser.home=...` to whatever archi sets. |
| `MCP_PROXY_HOST`, `MCP_PROXY_PORT` | runtime, `start.sh` | archi config `env:`. `start.sh` falls back to `127.0.0.1:8080` if unset (lines 13-14). | Tunable per deployment. No Dockerfile `ENV` — single source of truth in archi config. |

```dockerfile
# ── Stage 1: fetch and unpack SQLcl ──────────────────────────────────
FROM eclipse-temurin:17-jre AS sqlcl-fetch
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://download.oracle.com/otn_software/java/sqldeveloper/sqlcl-latest.zip" -o /tmp/sqlcl.zip \
 && unzip -q /tmp/sqlcl.zip -d /opt \
 && rm /tmp/sqlcl.zip
# /opt/sqlcl/bin/sql exists after this stage

# ── Stage 2: runtime image ───────────────────────────────────────────
FROM eclipse-temurin:17-jre
# python3 + python3-venv from the base image's distro (Ubuntu 22.04 ships 3.10,
# which satisfies mcp-proxy's >=3.10 requirement). install.sh auto-detects.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=sqlcl-fetch /opt/sqlcl /opt/sqlcl

WORKDIR /opt/sqlcl-mcp-proxy
COPY install.sh start.sh entrypoint.sh apply-config.sh add-db.sh requirements.txt ./
COPY bin/    ./bin/
COPY config/ ./config/

# Internal paths — coupled to host_file_mounts and stage 1 unzip output.
# Don't override at runtime.
ENV SQLCL_HOME=/opt/sqlcl
ENV TNS_ADMIN=/opt/sqlcl-mcp-proxy

# MCP_PROXY_HOST / MCP_PROXY_PORT are not set here.
# In sidecar use, archi config provides them via the env: block.
# In standalone docker run (debugging), start.sh falls back to 127.0.0.1:8080.

RUN ./install.sh    # creates /opt/sqlcl-mcp-proxy/.venv/, installs mcp-proxy

EXPOSE 8080
CMD ["./entrypoint.sh"]
```

#### Version pinning — deliberately not done

Each `archi create` pulls whatever Oracle has at `sqlcl-latest.zip` that minute. Maintenance: zero. Trade-off accepted:

- Same Dockerfile may produce different images on different days.
- No verification against a known-good SHA — trust whatever bytes Oracle's CDN hands back.
- "Which SQLcl is in production?" requires `docker run image sql -V`, not a one-liner from source.

Why it's OK here: read-only Oracle queries, single internal operator, no regression-bisection workflow that needs reproducible images. If a SQLcl regression breaks the agent, the operator notices, and the next rebuild typically pulls the fix.

If this design is later promoted to a regulated/production environment, pinning is easy to add — bump to `sqlcl-<version>.zip` with a SHA-256 ARG, optionally add `.github/workflows/bump-sqlcl.yml` to auto-PR on upstream changes. Out of scope here.

Other notes:

- No `COPY sqlcl/`, no `COPY tnsnames.ora`, no `COPY sqlcl.md` — those were gitignored in this user's repo for good reason. SQLcl is downloaded fresh; tnsnames is mounted from the host (`/etc/tnsnames.ora`).

#### 2. `.dockerignore` (new, at `/data/viphava/.dockerignore`)

```
.venv
.dbtools
*.log
.git
docs
meeting_saved_closed_caption.txt
sqlcl
tnsnames.ora
sqlcl.md
```

The last three duplicate `.gitignore` for the case where someone builds against a working copy that *does* have local SQLcl — those host artifacts must not leak into the image, since the Dockerfile fetches its own.

#### 3. `entrypoint.sh` (new, at `/data/viphava/entrypoint.sh`)

```bash
#!/usr/bin/env bash
# Sidecar entrypoint:
#   1. If a connections.conf is mounted, register every connection inside it.
#   2. exec start.sh, which is mcp-proxy --pass-environment -- sql -mcp.
set -euo pipefail

CONF=/opt/sqlcl-mcp-proxy/config/connections.conf
if [[ -f "$CONF" ]]; then
  echo "[entrypoint] Registering connections from $CONF"
  ./apply-config.sh "$CONF"
else
  echo "[entrypoint] WARNING: $CONF not found — no DBs will be registered."
  echo "[entrypoint] Mount it via host_file_mounts. See README."
fi

exec ./start.sh
```

If `apply-config.sh` exits non-zero (after the fix in §6), `set -e` fails the entrypoint and the container exits non-zero. Compose's `restart: on-failure` (PR #557 line 750) retries until backoff gives up. Logs: `docker logs sqlcl-mcp-comp_ops`.

#### 4. `bin/env.sh` — one-line append fix

Current line 21:

```bash
export JAVA_TOOL_OPTIONS="-Duser.home=${REPO_ROOT}"
```

Replaces any externally-set `JAVA_TOOL_OPTIONS` (e.g. `-Doracle.jdbc.ReadTimeout=60000` from archi's `env:` block). Change to append:

```bash
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Duser.home=${REPO_ROOT}"
```

JVM honors the *last* `-Dprop=value` when a property is repeated, so `user.home` always ends up at `$REPO_ROOT`. Archi-injected options are preserved. Backwards-compatible for the host workflow.

#### 5. `add-db.sh` — fail loudly

Current final lines:

```bash
"$SQLCL_BIN" /NOLOG <<SQL
CONN -save $NAME -savepwd -replace $USER/$PASSWORD@$TARGET
EXIT
SQL
echo "Saved connection: $NAME"
```

SQLcl exits 0 even when `CONN -save` errors (e.g. `ORA-01017: invalid username/password`). The unconditional success echo masks the failure. Fix: capture output, grep for `ORA-|ERROR`, exit non-zero.

```bash
out="$("$SQLCL_BIN" /NOLOG <<SQL 2>&1
CONN -save $NAME -savepwd -replace $USER/$PASSWORD@$TARGET
EXIT
SQL
)"
echo "$out"
if grep -Eq '^(Error|ORA-)' <<<"$out"; then
  echo "FAILED to save connection: $NAME" >&2
  exit 1
fi
echo "Saved connection: $NAME"
```

#### 6. `apply-config.sh` — fail loudly

Same pattern. Currently the script builds a sequence of `CONN -save` lines and pipes them all into one SQLcl process. SQLcl continues past per-line errors and exits 0. Fix: capture output, fail if any line errored.

```bash
# was:
} | "$SQLCL_BIN" /NOLOG

# becomes:
out="$({
  ...same body...
} | "$SQLCL_BIN" /NOLOG 2>&1)"
echo "$out"
if grep -Eq '^(Error|ORA-)' <<<"$out"; then
  echo "FAILED: at least one connection failed to save" >&2
  exit 1
fi
```

#### 7. archi config block — Hasan's `comp_ops_config.yaml`

```yaml
mcp_servers:
  sqlcl:
    transport: streamable_http
    url: http://localhost:8080/mcp
    build_context: /home/haozturk/Archi/sqlcl-mcp-proxy
    skill: sqlcl_mcp
    env:
      JAVA_TOOL_OPTIONS: "-Doracle.jdbc.ReadTimeout=60000"
      MCP_PROXY_HOST: "0.0.0.0"
      MCP_PROXY_PORT: "8080"
    env_from_secrets: []
    host_file_mounts:
      - src: /home/haozturk/sqlcl-connections.conf
        dest: /opt/sqlcl-mcp-proxy/config/connections.conf
      - src: /etc/tnsnames.ora
        dest: /opt/sqlcl-mcp-proxy/tnsnames.ora
```

Decisions:

- **`url: http://localhost:8080/mcp`** matches Hasan's rucio-mcp shape. Requires `host_mode: true`.
- **`build_context`** points at his local clone. `git pull` + `archi create` rebuilds the sidecar.
- **`env_from_secrets: []`** matches Hasan's rucio posture and avoids podman secrets quirks.
- **`host_file_mounts`** brings in two things from outside the build context: the connections file (Hasan-managed, owner-only) and the system TNS names (puppet-managed, world-readable). Symmetric with how Hasan mounts X509 certs for rucio.
- **`JAVA_TOOL_OPTIONS`** carries only the read-timeout. `bin/env.sh` appends `-Duser.home=...` — one source of truth.
- **No `image:` field.** Hasan's pattern is `build_context`; no registry needed.

#### 8. Hasan's `connections.conf`

He creates the file outside his clone, owner-only:

```ini
# /home/haozturk/sqlcl-connections.conf  — chmod 600
[CMS_T0AST_REPLAY1]
user     = archi_ro
tns      = INT2R
password = ${REPLAY_PASSWORD}

[CMS_T0AST_REPLAY2]
user     = archi_ro
tns      = INT2R
password = ${REPLAY_PASSWORD}

# …
```

`apply-config.sh` already supports `${VAR}` env-var expansion (line 22-30). Hasan can either inline plaintext passwords (file is owner-only and never copied into the image) or use `${VAR}` and inject the password via archi's `env:` block. We document both; recommend plaintext-in-conf because:

- File is mounted `:ro` from his home directory — it never enters the image, the registry, or the container's writable layer.
- Avoids the `.env`-and-Docker-secrets path that's flaky under `--podman`.
- TNS aliases (`tns = INT2R`) work because we mount `/etc/tnsnames.ora`.

#### 9. `skill: sqlcl_mcp` markdown (new, in cms-compops repo)

Drop a `sqlcl_mcp.md` in `cms-compops/configs/comp_ops/skills/`. PR #557 (`mcp.py:42-46`) loads it and appends to the agent system prompt once per turn. Move the IMMUTABLE read-only policy from `cms-comp-ops.md` into this file — the policy belongs with the tool, not the agent. Mirrors Hasan's `rucio_mcp.md` pattern (read-only intro, MCP-tool→verification-CLI table).

This change happens in the cms-compops repo (Hasan's clone of it on his host), not this user's repo.

### Data flow

1. **Image build** (`archi create`): Compose calls `docker build /home/haozturk/Archi/sqlcl-mcp-proxy/`. Stage 1 downloads SQLcl. Stage 2 installs mcp-proxy via `install.sh`. Image tag is whatever Compose names it.
2. **Boot:** Compose mounts `connections.conf` and `/etc/tnsnames.ora` read-only. `entrypoint.sh` runs `apply-config.sh`, which writes encrypted credentials into `/opt/sqlcl-mcp-proxy/.dbtools/` (container's writable layer; ephemeral). Then `exec start.sh`.
3. **start.sh** (unchanged) execs `mcp-proxy --pass-environment --host 0.0.0.0 --port 8080 -- $SQLCL_BIN -mcp`. PID 1 of the sidecar.
4. **Tool call:** chatbot resolves `localhost:8080` (host network), opens streamable_http, calls `list-connections` / `connect` / `run-sql`. SQLcl uses the connection from `.dbtools/`, opens JDBC to Oracle.
5. **Long query:** `oracle.jdbc.ReadTimeout=60000` (set via archi `env:`, preserved by the env.sh fix) aborts the OCI read at 60 s. Tool call returns an error to the agent.

### Failure modes

| What goes wrong | What you see | Where to look |
|---|---|---|
| Oracle CDN unreachable from Hasan's host during `archi create` | Image build fails at stage 1 (curl error) | `archi create` output |
| `connections.conf` missing or wrong permissions | Container boots, logs warning, `list-connections` returns empty | `docker logs sqlcl-mcp-comp_ops` |
| Bad password in `connections.conf` | `apply-config.sh` exits 1, container exits non-zero, Compose retries | `docker logs` shows `ORA-01017` |
| `/etc/tnsnames.ora` missing | TNS-form connections fail with `ORA-12154`; URL-form still works | `docker logs` |
| Read-only DB user not granted on a schema | tool call returns `ORA-00942` to the agent | agent's response |
| `host_mode` not enabled on the deployment | chatbot can't reach `localhost:8080` | `docker logs chatbot` |

### Migration steps

**On this user's machine (image author):**

1. Stop the host process: `pkill -f "mcp-proxy.*8080"`. Confirm `lsof -i:8080` is empty.
2. Add `Dockerfile`, `.dockerignore`, `entrypoint.sh` to `/data/viphava`.
3. Apply the one-line fix to `bin/env.sh:21`.
4. Apply the silent-failure fixes to `add-db.sh` and `apply-config.sh`.
5. Build once locally to confirm the Dockerfile works: `docker build -t sqlcl-mcp:test .`.
6. Smoke-test the image with a synthetic mount (see Testing).
7. Add `cms-compops/configs/comp_ops/skills/sqlcl_mcp.md`. Move the IMMUTABLE read-only policy out of `cms-comp-ops.md`.
8. Update README with the Hasan-side setup below.
9. Commit, push.

**On Hasan's machine (operator):**

10. Provision the read-only Oracle account with Dima.
11. Clone: `git clone https://github.com/Viphava280444/sqlcl-mcp-proxy.git /home/haozturk/Archi/sqlcl-mcp-proxy`.
12. Create `/home/haozturk/sqlcl-connections.conf` (one section per DB), `chmod 600`.
13. Update his `comp_ops_config.yaml` with the `mcp_servers.sqlcl` block above. Drop the IMMUTABLE policy from `cms-comp-ops.md` if §8 was done.
14. `a2rchi delete --name compops-a2rchi`, then `a2rchi create --name compops-a2rchi --config ... --podman`. Builds the image with the pinned SQLcl version from the Dockerfile.
15. Smoke test: ask archi a question that exercises `list-connections`, `connect`, `run-sql` against each DB.

**Live-add later:**

16. Edit `/home/haozturk/sqlcl-connections.conf`, restart the sidecar (`docker compose restart sqlcl-mcp` or rerun `archi create`). New DB available within seconds.

**On the user's local smoke deployment** (separate host, separate `cms-compops/` clone): same steps as Hasan, but pointed at this user's clone of cms-compops. Optional first step before Hasan rolls it.

### Testing plan

- **Build-time** (this user's machine): `docker build -t sqlcl-mcp:test .` succeeds. SQLcl download succeeds. `mcp-proxy` lands in `.venv`.
- **Boot-time** (this user's machine, before pushing): run with a synthetic mount and a real `tnsnames.ora`:
  ```bash
  docker run --rm -p 8080:8080 \
    -v /tmp/test-connections.conf:/opt/sqlcl-mcp-proxy/config/connections.conf:ro \
    -v /etc/tnsnames.ora:/opt/sqlcl-mcp-proxy/tnsnames.ora:ro \
    sqlcl-mcp:test
  ```
  Confirm `[entrypoint] Registering connections...` then `mcp-proxy` starts. `curl http://localhost:8080/mcp` returns the MCP handshake.
- **Negative — bad password:** boot with a connections.conf containing one good and one bad entry; confirm container exits non-zero with `ORA-01017` in logs.
- **Negative — no conf mount:** boot with no mount; confirm warning log + empty `list-connections` from a manual MCP probe.
- **Integration** (Hasan's archi stack): after migration, archi answers a question that hits each DB end-to-end.
- **Live-add:** edit conf, restart sidecar, confirm new DB appears in `list-connections`.

## Topic 2 — long-query timeout

Hasan asked for an investigation, not a finished design (meeting line 1637). Below is the plan to produce a finding plus what we ship up-front.

### What we ship up-front

`-Doracle.jdbc.ReadTimeout=60000` is included in `JAVA_TOOL_OPTIONS` from day one (component 7 above). Aborts a JDBC read at 60 s at the OCI layer. One env-var line; if it works in our environment it ends the investigation.

### Investigation layers

1. **Archi tool-call cancellation.** Verify (likely false): does `langchain_mcp_adapters`' `MultiServerMCPClient` honor a per-tool timeout? If yes, Hasan can set it in archi config — simplest fix. Time-box: 1 hour.
2. **Confirm `oracle.jdbc.ReadTimeout` actually fires.** Cartesian SELECT against a sandbox account; expect SQLcl error around 60 s.
3. **Oracle Resource Manager / user profile.** `ALTER PROFILE archi_ro_profile LIMIT CPU_PER_CALL 6000 LOGICAL_READS_PER_CALL 1000000` on the read-only account. Server-side cap. Pair with Dima's read-only-account work. Test: same cartesian SELECT, expect `ORA-02393` / `ORA-02395`.
4. **(Last resort) Python watchdog around mcp-proxy.** Wraps each tool call in `asyncio.wait_for(..., timeout=N)`. Doesn't kill the SQL on the DB; only useful as a stopgap.

### Decision rule

- (1) works → use it; remove the JDBC timeout.
- (1) fails, (2) works → keep the JDBC timeout, ship it, done.
- (2) fires but doesn't actually kill the OCI session → escalate to (3).
- Always pursue (3): server-side limits are the real boundary, same as the read-only-grants story.

### Reporting

Findings get appended to this spec as a "Topic 2 — results" section in a follow-up commit.

## Out of scope

- Other MCPs (rucio, opensearch). Hasan is wiring those separately.
- The cms-comp-ops agent prompt itself (after the read-only-policy move, it shrinks; behavior unchanged).
- Switching to a different Oracle MCP implementation. The deprecated `/data/viphava-archi/oracle-mcp-server/` is not part of this work.
- Wiring `services.chat_app.tools.oracle_databases`. Speculative config, not consumed by archi.
- Publishing a container image to a registry. If a multi-host or k8s deployment appears later, revisit.

## Open questions

1. **Read-only DB account name and DSN/TNS alias.** Placeholder `archi_ro` and `tns = INT2R` — replace with what Dima provisions.
2. **Confirm `host_mode: true` is on for Hasan's deployment.** Inferred from his rucio config using `localhost:8000`. He should confirm. If off, the URL becomes `http://sqlcl-mcp:8080/mcp` (the Compose service key, per `base-compose.yaml:715`) and chatbot reaches it via Compose DNS.
3. **Verify `oracle.jdbc.ReadTimeout` is honored by the JDBC driver bundled with the downloaded SQLcl.** If it isn't, fall back to `oracle.net.READ_TIMEOUT` or a Python watchdog.
4. **Where does `services.chat_app.skills_dir` resolve to in Hasan's deployment?** From his config: `/home/haozturk/Archi/cms-compops/configs/comp_ops/skills`. Confirms `sqlcl_mcp.md` location.

## Future work (out of scope here)

Two enhancements worth tracking but explicitly not done now:

**1. Pin SQLcl version + SHA, with auto-bump bot.** If this design is later promoted to a regulated environment, switch from `sqlcl-latest.zip` to `sqlcl-<version>.zip` with a `SQLCL_SHA256` ARG. Add `.github/workflows/bump-sqlcl.yml` running weekly: fetches upstream, compares SHA, opens a PR if it differs. ~40 lines of YAML. Not done now because for an internal CERN-ops read-only tool, the maintenance overhead doesn't pay off.

**2. archi `mcp_servers.<name>.build_args:` field.** Today PR #557's compose render emits `build: <path>` (simple form), not `build: {context, args}`. So Dockerfile `ARG`s can't be set from archi config. ~5-line template addition would expose `build_args:` alongside `env:` and `env_from_secrets:`. Worth proposing to Hasan once the sidecar is stable; needed only if (1) is also pursued.
