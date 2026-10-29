#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Run the search over Xymon's manual pages and history, xymonapi-rag(1):
# xymonapi-rag.sh index | search QUESTION | ask QUESTION.
#
# As xymonapi.sh does, exit 77 when it cannot run here -- no Python 3.10, or
# a module of rag/requirements.txt missing -- and say why.

PYTHON=${XYMONAPI_PYTHON:-python3}

command -v "$PYTHON" >/dev/null 2>&1 || {
	echo "xymonapi-rag: $PYTHON not found; it needs Python 3.10 or later" >&2
	exit 77
}
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || {
	echo "xymonapi-rag: `$PYTHON -V 2>&1` is too old; it needs Python 3.10 or later" >&2
	exit 77
}
missing=`"$PYTHON" -c 'import importlib.util as u
print(" ".join(m for m in ("fastembed", "numpy") if u.find_spec(m) is None))'`
if [ -n "$missing" ]; then
	echo "xymonapi-rag: missing Python modules: $missing (see rag/requirements.txt)" >&2
	exit 77
fi

exec "$PYTHON" "`dirname "$0"`/xymonrag.py" "$@"
