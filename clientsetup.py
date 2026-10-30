# SPDX-License-Identifier: GPL-2.0-or-later
"""The /client operation: a setup script for a laptop, written by the API
that laptop will use, so that the URL, the user and the names are right
without anyone typing them. The script is meant to be read, then run; it
never carries the password, and asks for it once, into a file of the user's.

    curl -u me https://xymon.example.ch/xymon/api/v1/client > xymon-setup.sh
    sh xymon-setup.sh

?format=env gives the three settings alone, for a hand-made setup.
"""
from __future__ import annotations

import os
import re
import shlex
import time

REPO = os.environ.get("XYMONAPI_REPO", "https://github.com/bonomani/xymon-api")
PUBLIC_URL = os.environ.get("XYMONAPI_PUBLIC_URL", "").rstrip("/")
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")

SCRIPT = """#!/bin/sh
# Set up this machine as a client of the Xymon API at {url}:
# written by that API on {date} for the user {user_or_none}.
# Read it, then run it. It installs under PREFIX (~/.local by default),
# asks for your password once, checks the API answers, and registers the
# MCP server with Claude Code under the name {name} when claude is here.
#
#   sh {script} [PREFIX]
#
set -eu
URL={url_q}
USER={user_q}
NAME={name_q}
PREFIX=${{1:-${{PREFIX:-$HOME/.local}}}}
SRC=${{XYMONAPI_SRC:-$HOME/src/xymon-api}}
PASSFILE=${{XDG_CONFIG_HOME:-$HOME/.config}}/xymon-api/$NAME.password
# The server's certificate, or the CA that signed it, when it is not one
# this machine trusts already -- xymond's own, as xymon-tls(7) sets it up.
# Copy it here first, and it is used for the check below and registered.
CAFILE=${{XDG_CONFIG_HOME:-$HOME/.config}}/xymon-api/$NAME-ca.pem

say() {{ printf '\\n== %s\\n' "$*"; }}
die() {{ printf 'xymon-setup: %s\\n' "$*" >&2; exit 1; }}

command -v git >/dev/null 2>&1 || die "git is needed, to fetch {repo}"
command -v curl >/dev/null 2>&1 || die "curl is needed"
PYTHON=${{XYMONAPI_PYTHON:-python3}}
command -v "$PYTHON" >/dev/null 2>&1 || die "$PYTHON is needed: Python 3.10 or later"
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || die "$("$PYTHON" -V 2>&1) is too old; Python 3.10 or later is needed"

say "the code, in $SRC"
if [ -d "$SRC/.git" ]; then
	git -C "$SRC" pull -q --ff-only
else
	git clone -q {repo_q} "$SRC"
fi

say "the client, under $PREFIX"
make -s -C "$SRC" install-client PREFIX="$PREFIX"

# A virtualenv of its own for the mcp module: a system Python takes no
# pip installs (PEP 668), and the launcher runs whatever XYMONAPI_PYTHON names.
VENV=$PREFIX/libexec/xymonapi/venv
if [ ! -x "$VENV/bin/python3" ]; then
	say "the Python module mcp, in $VENV"
	"$PYTHON" -m venv "$VENV"
	"$VENV/bin/pip" -q install -r "$SRC/mcp-server/requirements.txt"
fi

if [ -n "$USER" ]; then
	if [ ! -s "$PASSFILE" ]; then
		say "your password for $USER at $URL, kept in $PASSFILE (mode 600)"
		mkdir -p "$(dirname "$PASSFILE")"
		printf 'password: '
		stty -echo 2>/dev/null || true
		read -r pw
		stty echo 2>/dev/null || true
		printf '\\n'
		( umask 077 && printf '%s\\n' "$pw" > "$PASSFILE" )
	fi
	auth="-u $USER:$(cat "$PASSFILE")"
else
	auth=""
fi

ca=""
[ -s "$CAFILE" ] && ca="--cacert $CAFILE"

say "does the API answer?"
# shellcheck disable=SC2086 # auth and ca are two words each, or none
health=$(curl -sS --max-time 15 $auth $ca "$URL/xymon/api/v1/health" 2>"$HOME/.xymon-setup.err") || {{
	grep -qi 'certificate' "$HOME/.xymon-setup.err" && die "$URL has a certificate this machine does not trust: copy the server's certificate, or the CA that signed it, to $CAFILE and run this again"
	die "no answer from $URL: $(cat "$HOME/.xymon-setup.err")"
}}
rm -f "$HOME/.xymon-setup.err"
case $health in
	*'"alive":true'*) echo "yes: $health" ;;
	*'"alive":false'*) echo "the API answers, but its xymond does not: $health" ;;
	*unauthorized*) die "the API refused the password in $PASSFILE: remove that file and run this again" ;;
	*) die "an unexpected answer from $URL: $health" ;;
esac

if command -v claude >/dev/null 2>&1; then
	say "registering the MCP server with Claude Code as $NAME"
	claude mcp remove --scope user "$NAME" >/dev/null 2>&1 || true
	# shellcheck disable=SC2046
	claude mcp add --scope user "$NAME" \\
		-e XYMONAPI_URL="$URL" \\
		$( [ -n "$USER" ] && printf -- '-e XYMONAPI_USER=%s -e XYMONAPI_PASSWORD_FILE=%s' "$USER" "$PASSFILE" ) \\
		$( [ -n "$ca" ] && printf -- '-e XYMONAPI_CA=%s' "$CAFILE" ) \\
		-e XYMONAPI_PYTHON="$VENV/bin/python3" \\
		-- "$PREFIX/bin/xymonapi-mcp"
else
	say "Claude Code is not here; to register the MCP server later:"
	echo "  claude mcp add --scope user $NAME -e XYMONAPI_URL=$URL \\\\"
	[ -n "$USER" ] && echo "    -e XYMONAPI_USER=$USER -e XYMONAPI_PASSWORD_FILE=$PASSFILE \\\\"
	[ -n "$ca" ] && echo "    -e XYMONAPI_CA=$CAFILE \\\\"
	echo "    -e XYMONAPI_PYTHON=$VENV/bin/python3 -- $PREFIX/bin/xymonapi-mcp"
fi

say "done"
cat <<EOF
From a shell, with these in the environment:
  export XYMONAPI_URL=$URL${{USER:+ XYMONAPI_USER=$USER XYMONAPI_PASSWORD_FILE=$PASSFILE}}${{ca:+ XYMONAPI_CA=$CAFILE}}
  $PREFIX/bin/xymonapi-rag search "what does purple mean"
In Claude Code, just ask: "which hosts are red?"
EOF
"""

ENV = """# The Xymon API at {url}, for the user {user_or_none}: written by that API on {date}.
XYMONAPI_URL={url_q}
XYMONAPI_USER={user_q}
# The first line of this file is the password; create it with mode 600.
XYMONAPI_PASSWORD_FILE={passfile_q}
"""


def public_url(headers, request_url: str) -> str:
    """Where the client should reach this API: XYMONAPI_PUBLIC_URL when set,
    else what the request came through -- the proxy's X-Forwarded-Proto and
    X-Forwarded-Host when there is one, the Host header otherwise."""
    if PUBLIC_URL:
        return PUBLIC_URL
    host = headers.get("x-forwarded-host") or headers.get("host") or "127.0.0.1:1986"
    host = host.split(",")[0].strip()
    own = "https" if os.environ.get("XYMONAPI_TLS") else request_url.split(":", 1)[0]
    scheme = (headers.get("x-forwarded-proto") or own).split(",")[0].strip()
    if scheme not in ("http", "https"):
        scheme = "http"
    return f"{scheme}://{host}"


def valid_name(name: str | None) -> str:
    """The name the MCP server is registered under: xymon by default."""
    if name is None or name == "":
        return "xymon"
    if not _NAME.fullmatch(name):
        raise ValueError("name must be letters, digits, . _ or -, 64 at most")
    return name


def render(url: str, user: str, name: str, fmt: str) -> str:
    passfile = f"${{XDG_CONFIG_HOME:-$HOME/.config}}/xymon-api/{name}.password"
    vars_ = dict(url=url, url_q=shlex.quote(url), user=user, user_q=shlex.quote(user),
                 user_or_none=user or "(none: the API asks for no password)",
                 name=name, name_q=shlex.quote(name), repo=REPO, repo_q=shlex.quote(REPO),
                 passfile_q=passfile, script=f"{name}-setup.sh",
                 date=time.strftime("%Y-%m-%d", time.gmtime()))
    return (ENV if fmt == "env" else SCRIPT).format(**vars_)
