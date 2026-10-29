#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Start the MCP server for the Xymon API, xymonapi-mcp(1), on stdio. This is
# the command an AI client is configured to run.
#
# The directory is mcp-server/, not mcp/: run from the repository root, a
# directory named mcp would pass for the mcp module itself.
#
# As xymonapi.sh does, exit 77 when it cannot run here -- no Python 3.10, or
# the mcp module missing -- and say why on stderr, which the client logs:
# stdout carries the protocol and nothing else.

PYTHON=${XYMONAPI_PYTHON:-python3}
here=`dirname "$0"`

command -v "$PYTHON" >/dev/null 2>&1 || {
	echo "xymonapi-mcp: $PYTHON not found; it needs Python 3.10 or later" >&2
	exit 77
}
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || {
	echo "xymonapi-mcp: `$PYTHON -V 2>&1` is too old; it needs Python 3.10 or later" >&2
	exit 77
}
# The module checks run from this script's directory: from the caller's, a
# directory there named like a module would pass for it.
(cd "$here" && "$PYTHON" -c 'import importlib.util as u, sys; sys.exit(u.find_spec("mcp") is None)') || {
	echo "xymonapi-mcp: the Python module mcp is missing (see mcp-server/requirements.txt)" >&2
	exit 77
}

exec "$PYTHON" "$here/server.py"
