# sqlcl-mcp-proxy — Portable install for a SQLcl MCP server behind mcp-proxy

**Status:** Design approved, awaiting implementation plan
**Date:** 2026-04-23
**Target audience:** Public Linux users connecting an LLM to one or more Oracle databases.

---

## 1. Goal

A small, readable git repo that any Linux user can clone and, in a few commands, end up with an HTTP-streamable MCP endpoint backed by Oracle SQLcl. The user can manage multiple Oracle databases (TNS or Easy Connect), add new ones on the fly without restarting anything, and operate the proxy with minimal code and no service-manager setup unless they choose to add one.

Non-goals: shipping SQLcl binaries, vendoring Python deps, bundling a specific TNS file, providing daemon/service infrastructure, or automating secrets delivery.

## 2. Architecture

Thin orchestration. The repo ships shell scripts, a config template, a pinned `requirements.txt`, and a smoke test. It does **not** ship SQLcl, Java, Python, passwords, or a `tnsnames.ora`.

```
User                           Repo checkout                      External deps (user-provided)
─────                          ─────────────                      ──────────────────────────────
git clone ▶ cd repo            ├── install.sh                     ┌─ Java 17+   (OS package)
  ▼                            ├── add-db.sh                      ├─ SQLcl      ($SQLCL_HOME)
./install.sh ─────────────▶    ├── apply-config.sh                └─ Python 3.10+ (OS package)
  ▼ creates .venv/             ├── start.sh
                               ├── bin/env.sh
./add-db.sh / apply ▶          ├── config/
  ▼ saves wallet               │   └── connections.conf.example
                               ├── requirements.txt                            ┌──▶ Oracle DB 1
./start.sh ─────────────▶      │                                               │    (via TNS or
  ▼                            HTTP/SSE 127.0.0.1:8080                         │     Easy Connect)
LLM client ──── /mcp ──────────▲                                               │
                               │                                               │
                               ▼ internally: mcp-proxy spawns `sql -mcp`   ────┘
```

### Key properties

- **Self-contained in the checkout.** `.venv/`, `.dbtools/`, user config all live under the repo directory.
- **Externals are explicit** via three env vars: `SQLCL_HOME` (required), `TNS_ADMIN` (optional), per-connection `${PASSWORD_VAR}` (optional).
- **Idempotent.** All scripts can be re-run safely.
- **Foreground process.** `./start.sh` blocks. User runs it under tmux / nohup / systemd themselves.
- **Localhost by default.** `MCP_PROXY_HOST` / `MCP_PROXY_PORT` env vars override.

## 3. Components

```
sqlcl-mcp-proxy/
├── README.md                          ← everything a user needs
├── LICENSE                            ← MIT
├── .gitignore                         ← excludes .venv/, .dbtools/, config/connections.conf
├── requirements.txt                   ← mcp-proxy pinned
├── install.sh                         ← one-time setup: venv + mcp-proxy
├── add-db.sh                          ← add one connection: ./add-db.sh NAME USER TNS_OR_URL [PASS]
├── apply-config.sh                    ← bulk-save from config/connections.conf
├── start.sh                           ← run mcp-proxy (foreground)
├── bin/
│   └── env.sh                         ← internal: paths + env vars, sourced by others
├── config/
│   └── connections.conf.example       ← documented template
├── docs/
│   └── adding-databases.md            ← short doc explaining the live-add property
└── tests/
    └── smoke_test.py                  ← end-to-end: init → list → connect → run-sql
```

### User-facing script surface

| Script | Signature | Purpose |
|---|---|---|
| `./install.sh` | `./install.sh` | One-time. Verifies prereqs, creates `.venv`, installs `mcp-proxy`. |
| `./add-db.sh` | `./add-db.sh NAME USER TNS_OR_URL [PASSWORD]` | Save one connection on the fly. If `PASSWORD` arg is absent, read from stdin with echo disabled (`read -s`). |
| `./apply-config.sh` | `./apply-config.sh` | Read `config/connections.conf`, save every `[section]` as a connection. |
| `./start.sh` | `./start.sh` | Launch the proxy on `$MCP_PROXY_HOST:${MCP_PROXY_PORT:-8080}` (default `127.0.0.1:8080`). |

### Config file format (`config/connections.conf`)

Plain INI. One `[section]` per saved connection. Section name becomes the connection name.

```ini
[my_first_db]
user = HR
tns  = PROD_DB            # references tnsnames.ora via $TNS_ADMIN
password = ${HR_PASS}     # literal also accepted; if omitted, falls back to $ORACLE_PASS

[my_second_db]
user = scott
url  = //localhost:1521/XEPDB1   # Easy Connect; mutually exclusive with 'tns'
password = tiger
```

- Keys: `user` (required), `tns` **or** `url` (exactly one required; both set or neither set → section skipped with a warning), `password` (optional)
- `${ENV}` references expand from the calling shell's environment
- Literal plaintext passwords are allowed; `.gitignore` excludes `config/connections.conf`

### Environment contract

| Variable | Required? | Purpose |
|---|---|---|
| `SQLCL_HOME` | Yes | Path to an existing SQLcl install with `$SQLCL_HOME/bin/sql` |
| `TNS_ADMIN` | Only if using TNS aliases | Directory containing `tnsnames.ora` |
| `MCP_PROXY_HOST` | No (default `127.0.0.1`) | Bind address for the HTTP server |
| `MCP_PROXY_PORT` | No (default `8080`) | Port for `/mcp` and `/sse` |
| `ORACLE_PASS` | No | Fallback password when a section omits `password` |
| `<custom>` | No | Used via `${VAR}` references in `connections.conf` |

## 4. Data flow

### Install (one shot)

`./install.sh` → check `SQLCL_HOME` + Java + Python → `python -m venv .venv` → `.venv/bin/pip install -r requirements.txt`.

### Add a connection (any time, proxy up or down)

**Path A — one-shot CLI:**
```
./add-db.sh NAME USER TNS_OR_URL PASSWORD
    → sources bin/env.sh
    → sql /NOLOG << "CONN -save NAME -savepwd -replace USER/PASSWORD@TNS_OR_URL"
    → writes .dbtools/connections/<id>/{dbtools.properties,credentials.sso}
```

**Path B — bulk from config:**
```
edit config/connections.conf
./apply-config.sh
    → sources bin/env.sh
    → parses INI, expands ${VAR}s
    → one sql /NOLOG heredoc with CONN -save ... -savepwd -replace per section
```

### Runtime (LLM → DB)

```
LLM ─HTTP POST /mcp─▶ mcp-proxy ─stdio─▶ sql -mcp
                                          │
                                          ├─ list-connections  : reads .dbtools/ fresh each call
                                          ├─ connect(NAME)     : reads wallet, opens connection
                                          └─ run-sql(...)      : executes, returns CSV
```

### Live-add property

Because `list-connections` reads the wallet directory on each invocation and `connect(-name NAME)` resolves at call time, **a new connection created by `add-db.sh` or `apply-config.sh` becomes visible to the LLM on its next `list-connections` call without restarting `start.sh`**. This is a documented user-facing property; see `docs/adding-databases.md`.

## 5. Error handling

Intentionally minimal. All scripts begin with `set -euo pipefail`. Three sanity checks in `install.sh`:

```bash
[[ -x "$SQLCL_HOME/bin/sql" ]] || { echo "Set SQLCL_HOME to your SQLcl install"; exit 1; }
command -v java    >/dev/null || { echo "Install Java 17+"; exit 1; }
command -v python3 >/dev/null || { echo "Install Python 3.10+"; exit 1; }
```

Everything else — bad SQL, wrong password, port in use, missing TNS alias — surfaces directly from SQLcl, pip, or mcp-proxy. No wrapping, retrying, or translating. No `doctor` script. No `--dry-run`.

Non-obvious detail: `apply-config.sh` skips malformed sections (missing required key, both `tns` and `url`, unknown keys ignored silently) with a `-- skipping NAME: <reason>` line and keeps going, so one typo doesn't block the rest.

## 6. Testing

Single smoke test at `tests/smoke_test.py`:

1. Open streamable HTTP session against `http://127.0.0.1:8080/mcp`
2. `list-connections` → expect ≥ 1 result
3. `connect(first_name)` → expect success
4. `run-sql("SELECT USER FROM DUAL")` → expect username match

Passing all four proves proxy + MCP protocol + SQLcl spawn + wallet + TNS/URL + DB auth + query execution.

Run:
```bash
# Terminal 1
./start.sh
# Terminal 2
.venv/bin/python tests/smoke_test.py
```

No CI. Testing requires a real Oracle DB; documented as a post-install step.

## 7. Decisions log

| # | Decision | Rationale |
|---|---|---|
| 1 | Audience: public Linux users | Drives "bring your own SQLcl / Java / Python" stance |
| 2 | Distribution: git clone + plain scripts | Simple, no Makefile, copy-pastable |
| 3 | SQLcl via `SQLCL_HOME`, not auto-downloaded | Avoids redistribution of Oracle binaries; user picks version |
| 4 | Per-connection `tns` **or** `url`, never both | Supports "TNS or not TNS" use cases; minimal parser |
| 5 | `TNS_ADMIN` via env var (no repo-side TNS file) | TNS file is user-specific; don't couple to the checkout |
| 6 | Passwords: literal **or** `${ENV}` ref supported | Flexible; `.gitignore` protects accidental commit |
| 7 | Config lives in repo at `config/connections.conf`, gitignored | Clone-local, minimal path juggling, no XDG magic |
| 8 | Foreground only; no systemd unit shipped | User wraps with tmux/nohup/systemd themselves |
| 9 | No Makefile; top-level `.sh` scripts | Simpler UX, less indirection |
| 10 | Live-add supported (no proxy restart) | SQLcl re-reads wallet each `list-connections`; documented |
| 11 | One smoke test, no CI | Oracle DB is required; infra cost not justified |
| 12 | `-Duser.home=<repo>` via `JAVA_TOOL_OPTIONS` | Keeps SQLcl wallet at `<repo>/.dbtools/` on local disk (works around AFS wallet issues) |

## 8. Out of scope

- Ansible / Chef / Puppet / Helm chart
- Docker image (may come in a follow-up)
- Prometheus / logging / observability integration
- Password rotation automation
- Oracle Wallet (mkstore) integration beyond what SQLcl's `CONN -savepwd` already provides
- Auth on the HTTP endpoint (bearer token, mTLS)
- Multiple concurrent `sql -mcp` backends for parallel queries

## 9. Glossary

- **MCP** — Model Context Protocol; the spec Anthropic published that standardizes tool-use between LLMs and external capabilities.
- **mcp-proxy** — Python package (`sparfenyuk/mcp-proxy`) that bridges a stdio MCP server to HTTP/SSE.
- **SQLcl MCP server** — `sql -mcp`, a mode of Oracle SQLcl 25.2+ that speaks MCP over stdio and exposes DB tools.
- **TNS alias** — Named Oracle connection descriptor resolved through `tnsnames.ora`.
- **Easy Connect** — `//host:port/service` inline string, no TNS file required.
- **SSO wallet** — Oracle's format for storing credentials; SQLcl writes to `~/.dbtools/connections/<id>/credentials.sso`.
- **Live-add** — The property that a newly-saved connection becomes usable by the LLM without restarting the proxy.
