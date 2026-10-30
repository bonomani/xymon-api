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
here=`dirname "$0"`

command -v "$PYTHON" >/dev/null 2>&1 || {
	echo "xymonapi: $PYTHON not found; the API needs Python 3.10 or later" >&2
	exit 77
}
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || {
	echo "xymonapi: `$PYTHON -V 2>&1` is too old; the API needs Python 3.10 or later" >&2
	exit 77
}
# The module checks run from this script's directory: from the caller's, a
# directory there named like a module would pass for it.
missing=`cd "$here" && "$PYTHON" -c 'import importlib.util as u
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

# TLS, with xymond's own certificate and key (xymon-tls(7)) unless others
# are named: when both files are there the API speaks HTTPS, when neither is
# it speaks HTTP, and one without the other is a mistake to report. A key
# that others can read is refused, as xymond refuses it.
cert=${XYMONAPI_TLS_CERT:-${XYMONHOME:-/nonexistent}/etc/tls/xymond.pem}
key=${XYMONAPI_TLS_KEY:-${XYMONHOME:-/nonexistent}/etc/tls/xymond.key}
tls=""
if [ -n "$XYMONAPI_TLS_CERT$XYMONAPI_TLS_KEY" ] || [ -e "$cert" ] || [ -e "$key" ]; then
	[ -r "$cert" ] || { echo "xymonapi: cannot read the TLS certificate $cert (XYMONAPI_TLS_CERT)" >&2; exit 1; }
	[ -r "$key" ] || { echo "xymonapi: cannot read the TLS key $key (XYMONAPI_TLS_KEY)" >&2; exit 1; }
	case `ls -ld "$key" | cut -c5-10` in
		------) ;;
		*) echo "xymonapi: the TLS key $key is readable by others; make it mode 600" >&2; exit 1 ;;
	esac
	tls="--ssl-certfile $cert --ssl-keyfile $key"
	export XYMONAPI_TLS=1
fi

cd "$here" || exit 1
# shellcheck disable=SC2086 # tls is two options and their files, or nothing
exec "$PYTHON" -m uvicorn --host "$host" --port "$port" --no-access-log $tls app:app
