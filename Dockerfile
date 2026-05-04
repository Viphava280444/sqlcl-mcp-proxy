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
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=sqlcl-fetch /opt/sqlcl /opt/sqlcl

WORKDIR /opt/sqlcl-mcp-proxy
COPY install.sh start.sh entrypoint.sh apply-config.sh add-db.sh requirements.txt ./
COPY bin/    ./bin/
COPY config/ ./config/

# Internal paths — coupled to host_file_mounts and stage 1 unzip output.
ENV SQLCL_HOME=/opt/sqlcl
ENV TNS_ADMIN=/opt/sqlcl-mcp-proxy

# MCP_PROXY_HOST / MCP_PROXY_PORT are not set here.
# In sidecar use, archi config provides them via the env: block.
# In standalone docker run (debugging), start.sh falls back to 127.0.0.1:8080.

RUN ./install.sh

EXPOSE 8080
CMD ["./entrypoint.sh"]
