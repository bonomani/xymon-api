#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Start the Xymon API: xymonapi(8).
#
# Xymon itself needs no Python, so this is the one place that finds out
# whether the API can run here. Exit 77 says it cannot -- no Python 3.10, or a
# module missing -- as distinct from 1, a configuration error; the tests skip
# on 77, as they skip on a missing compiler.

# XYMONAPI_PYTHON names the Python to use, a virtualenv's for instance.
PYTHON=${XYMONAPI_PYTHON:-python3}

command -v "$PYTHON" >/dev/null 2>&1 || {
	echo "xymonapi: $PYTHON not found; the API needs Python 3.10 or later" >&2
	exit 77
}
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || {
	echo "xymonapi: `$PYTHON -V 2>&1` is too old; the API needs Python 3.10 or later" >&2
	exit 77
}
missing=`"$PYTHON" -c 'import importlib.util as u
print(" ".join(m for m in ("fastapi", "uvicorn", "yaml") if u.find_spec(m) is None))'`
if [ -n "$missing" ]; then
	echo "xymonapi: missing Python modules: $missing (see requirements.txt)" >&2
	exit 77
fi

if [ -z "$XYMSRV" ]; then
	echo "xymonapi: XYMSRV is not set; start it from xymonlaunch with ENVFILE, or through xymoncmd" >&2
	exit 1
fi

# HOST:PORT, or [ADDRESS]:PORT for IPv6. The default stays on this machine.
listen=${XYMONAPI_LISTEN:-127.0.0.1:1986}
port=${listen##*:}
host=`echo "${listen%:*}" | sed -e 's/^\[//' -e 's/\]$//'`

cd "`dirname "$0"`" || exit 1
exec "$PYTHON" -m uvicorn --host "$host" --port "$port" --no-access-log app:app
