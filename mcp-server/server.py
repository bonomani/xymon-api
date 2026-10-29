# SPDX-License-Identifier: GPL-2.0-or-later
"""MCP server for the Xymon API: xymonapi-mcp(1).

An AI client -- Claude Desktop, Claude Code -- starts this over stdio and
calls its tools. Each tool is one request to a running xymonapi(8), so what
the client gets is what the API answers, now: nothing is stored here, and
nothing in Xymon is changed.

XYMONAPI_URL is where the API is, http://127.0.0.1:1986 by default.
XYMONAPI_USER and XYMONAPI_PASSWORD are sent when the API asks for a user.
"""
from __future__ import annotations

import base64
import json
import os
import urllib.error
import urllib.request
from urllib.parse import urlencode

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ToolAnnotations

URL = os.environ.get("XYMONAPI_URL", "http://127.0.0.1:1986").rstrip("/")
USER = os.environ.get("XYMONAPI_USER", "")
PASSWORD = os.environ.get("XYMONAPI_PASSWORD", "")
READ_ONLY = ToolAnnotations(readOnlyHint=True, openWorldHint=False)

server = MCPServer(
    name="xymon",
    instructions="Read a Xymon monitoring server: its status board, alarms, "
                 "hosts and the numeric history in its RRD files. Read-only.")


def api(path: str, **params: str | None) -> dict:
    """GET PATH under /xymon/api/v1 and return the JSON it answers."""
    query = urlencode({k: v for k, v in params.items() if v})
    req = urllib.request.Request(f"{URL}/xymon/api/v1{path}" + (f"?{query}" if query else ""))
    if USER:
        token = base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    # ToolError, not any other exception: the SDK passes its text on to the
    # client, and treats anything else as a crash whose text it keeps back.
    except urllib.error.HTTPError as e:
        # The API's own explanation, not a bare status.
        raise ToolError(f"xymonapi answered {e.code}: {e.read().decode(errors='replace')}") from e
    except urllib.error.URLError as e:
        raise ToolError(f"cannot reach xymonapi at {URL}: {e.reason}") from e


@server.tool(annotations=READ_ONLY)
def health() -> dict:
    """Whether xymond answers, and its version."""
    return api("/health")


@server.tool(annotations=READ_ONLY)
def states(entity: str | None = None, test: str | None = None,
           verdict: str | None = None) -> dict:
    """The status board: one state per host and test.

    entity: only this host. test: only this test (cpu, disk, conn, http, ...).
    verdict: only ok, warning, critical, disabled, nodata or unknown -- the
    web pages show them green, yellow, red, blue, clear and purple.
    """
    return api("/states", entity=entity, test=test, verdict=verdict)


@server.tool(annotations=READ_ONLY)
def alarms() -> dict:
    """Every state whose verdict is not ok, with its severity."""
    return api("/alarms")


@server.tool(annotations=READ_ONLY)
def entities() -> dict:
    """Each host on the board, once."""
    return api("/entities")


@server.tool(annotations=READ_ONLY)
def series(entity: str, test: str, metric: str | None = None,
           start: str = "-24h", end: str = "now") -> dict:
    """The values of one dataset of a host's RRD file over a time range.

    test is the RRD file without .rrd (la, disk, tcp.http, ...), metric the
    dataset in it (default lambda). start and end are now, seconds since the
    epoch, or relative like -30m, -24h, -7d.
    """
    return api("/series", entity=entity, test=test, metric=metric,
               **{"from": start, "to": end})


if __name__ == "__main__":
    server.run("stdio")
