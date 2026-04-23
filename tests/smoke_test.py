"""End-to-end smoke test for sqlcl-mcp-proxy.

Prereqs (the test will fail with a clear message otherwise):
    1. `./start.sh` is running (defaults to 127.0.0.1:8080).
    2. At least one connection is saved (via add-db.sh or apply-config.sh).

Run from repo root:
    .venv/bin/python tests/smoke_test.py
"""
import asyncio
import os
import sys

from mcp.client.streamable_http import streamablehttp_client
from mcp import ClientSession


URL = os.environ.get("MCP_URL", "http://127.0.0.1:8080/mcp")


async def main() -> int:
    print(f"Connecting to {URL}")
    async with streamablehttp_client(URL) as (read, write, _sid):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print(f"Initialized. Server: {init.serverInfo.name} v{init.serverInfo.version}")

            tools = await session.list_tools()
            expected = {"list-connections", "connect", "run-sql"}
            got = {t.name for t in tools.tools}
            missing = expected - got
            if missing:
                print(f"FAIL: missing tools: {missing}")
                return 1
            print(f"OK: all required tools present (got {len(tools.tools)} total)")

            lc = await session.call_tool("list-connections", {})
            names_text = "\n".join(c.text for c in lc.content if hasattr(c, "text"))
            print(f"list-connections returned: {names_text!r}")

            # Pick first connection name from CSV-ish output.
            first = names_text.strip().split(",")[0].strip()
            if not first:
                print("FAIL: no saved connections. Run ./add-db.sh or ./apply-config.sh.")
                return 1
            print(f"Using first connection: {first}")

            cr = await session.call_tool("connect", {"connection_name": first})
            connect_text = "\n".join(c.text for c in cr.content if hasattr(c, "text"))
            if "Successfully connected" not in connect_text and "connected" not in connect_text.lower():
                print(f"FAIL: connect did not succeed:\n{connect_text}")
                return 1
            print("OK: connect succeeded")

            rs = await session.call_tool(
                "run-sql", {"sql": "SELECT USER AS me FROM DUAL"}
            )
            sql_text = "\n".join(c.text for c in rs.content if hasattr(c, "text"))
            if "ME" not in sql_text.upper():
                print(f"FAIL: query did not return USER:\n{sql_text}")
                return 1
            print(f"OK: run-sql returned\n  {sql_text.strip()[:200]}")

    print("\nSmoke test PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
