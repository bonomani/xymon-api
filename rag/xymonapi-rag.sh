#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Run the search over Xymon's manual pages and history, xymonapi-rag(1):
# xymonapi-rag.sh index | search QUESTION | ask QUESTION.
#
# As xymonapi.sh does, exit 77 when it cannot run here -- no Python 3.10, or
# a module of rag/requirements.txt missing -- and say why. The modules are
# checked by xymonrag.py itself, when a command needs them: a search through
# the API's index, or ask with it, needs none.

PYTHON=${XYMONAPI_PYTHON:-python3}
here=`dirname "$0"`

command -v "$PYTHON" >/dev/null 2>&1 || {
	echo "xymonapi-rag: $PYTHON not found; it needs Python 3.10 or later" >&2
	exit 77
}
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || {
	echo "xymonapi-rag: `$PYTHON -V 2>&1` is too old; it needs Python 3.10 or later" >&2
	exit 77
}
exec "$PYTHON" "$here/xymonrag.py" "$@"
