# SPDX-License-Identifier: GPL-2.0-or-later
"""The /client operation: a setup script for a laptop, written by the API
that laptop will use, so that the URL, the user and the names are right
without anyone typing them. The script is meant to be read, then run; it
never carries the password, and asks for it once, into a file of the user's.

    curl -u me https://xymon.example.ch/xymon/api/v1/client > xymon-setup.sh
    sh xymon-setup.sh

?format=env gives the two settings alone, for a hand-made setup.
"""
from __future__ import annotations

import os
import re
import shlex
import time

REPO = os.environ.get("XYMONAPI_REPO", "https://github.com/bonomani/xymon-api")
PUBLIC_URL = os.environ.get("XYMONAPI_PUBLIC_URL", "").rstrip("/")
# The commit this API was installed from, written beside this file by make
# install when it ran in a git checkout: the laptop then gets the same code,
# not whatever is newest. Absent (a tarball), the script takes the newest.
_COMMIT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "COMMIT")
_HEX = re.compile(r"[0-9a-f]{7,64}")
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")

SCRIPT = """#!/bin/sh
# Set up this machine as a client of the Xymon API at {url}:
# written by that API on {date} for the user {user_or_none}.
# The address is {url_from}.
# Read it, then run it. It installs under PREFIX (~/.local by default),
# asks for your password once to get this machine a token of its own --
# the password is not kept -- checks the API answers, and registers the MCP
# server with Claude Code under the name {name} when claude is here.
#
#   sh {script} [PREFIX]
#
set -eu
URL={url_q}
USER={user_q}
NAME={name_q}
REF={ref_q}
PREFIX=${{1:-${{PREFIX:-$HOME/.local}}}}
SRC=${{XYMONAPI_SRC:-$HOME/src/xymon-api}}
TOKENFILE=${{XDG_CONFIG_HOME:-$HOME/.config}}/xymon-api/$NAME.token
# A password an earlier version of this script kept: removed, the token
# replaces it.
OLDPASS=${{XDG_CONFIG_HOME:-$HOME/.config}}/xymon-api/$NAME.password
# This machine's name, for its token: the short hostname, in the characters
# a token's name may hold. It names the machine; it proves nothing.
CLIENT=$(hostname 2>/dev/null || uname -n)
CLIENT=$(printf '%s' "${{CLIENT%%.*}}" | tr -c 'A-Za-z0-9_.-' '-' | sed -e 's/^[^A-Za-z0-9]*//' | cut -c1-64)
[ -n "$CLIENT" ] || CLIENT=client
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
	git -C "$SRC" fetch -q --tags origin
else
	git clone -q {repo_q} "$SRC"
fi
# The commit the API was installed from, so both sides run the same code;
# without one, or one the repository no longer has, the newest. Detached, so
# a branch checked out there is left as it is.
if [ -n "$REF" ] && git -C "$SRC" rev-parse -q --verify "$REF^{{commit}}" >/dev/null; then
	git -C "$SRC" checkout -q --detach "$REF"
else
	[ -n "$REF" ] && echo "{repo} has no commit $REF, the one the API was installed from; taking its newest code"
	git -C "$SRC" remote set-head origin -a >/dev/null
	git -C "$SRC" checkout -q --detach origin/HEAD
fi

say "the client, under $PREFIX"
make -s -C "$SRC" install-client PREFIX="$PREFIX"

# A virtualenv of its own for the mcp module: a system Python takes no
# pip installs (PEP 668), and the launcher runs whatever XYMONAPI_PYTHON names.
# One that a run before left half made -- a python3 without mcp, as when
# the venv module is missing -- is made again.
VENV=$PREFIX/libexec/xymonapi/venv
if ! "$VENV/bin/python3" -c 'import mcp' >/dev/null 2>&1; then
	say "the Python module mcp, in $VENV"
	rm -rf "$VENV"
	"$PYTHON" -m venv "$VENV"
	"$VENV/bin/pip" -q install -r "$SRC/mcp-server/requirements.txt"
fi

# The options that depend on what is here are built as the positional
# parameters: sh has no arrays, and a path with a space stays one word.
ca=""
set --
[ -s "$CAFILE" ] && ca=1 && set -- --cacert "$CAFILE"

# curl's config escapes: a backslash and a double quote, inside "...".
esc() {{ printf '%s' "$1" | sed -e 's/\\\\/\\\\\\\\/g' -e 's/"/\\\\"/g'; }}

# A token for this machine, asked for with the password, which goes to curl
# in a config on its stdin -- not on its command line, which ps shows to
# everyone -- and is kept nowhere.
new_token() {{
	say "a token for $CLIENT, for $USER at $URL: your password, once"
	printf 'password: '
	# Echo comes back however the read ends. A Ctrl-C also ends the script:
	# bash, except in POSIX mode, runs the trap and goes back to the read, which
	# would then show the password as it is typed.
	stty -echo 2>/dev/null && trap 'stty echo 2>/dev/null' EXIT &&
		trap 'stty echo 2>/dev/null; exit 130' INT TERM
	read -r pw
	stty echo 2>/dev/null || true
	trap - EXIT INT TERM
	printf '\\n'
	answer=$(printf 'user = "%s:%s"\\n' "$(esc "$USER")" "$(esc "$pw")" |
		curl -sS -K - --max-time 15 "$@" -X POST -H 'Content-Type: application/json' \\
			-d "{{\\"client\\":\\"$CLIENT\\"}}" "$URL/xymon/api/v1/tokens") ||
		die "no answer from $URL for a token: $answer"
	pw=""
	token=$(printf '%s' "$answer" | sed -n 's/.*"token": *"\\(xat_[A-Za-z0-9_-]*\\)".*/\\1/p')
	case $answer in *unauthorized*) die "the API refused the password for $USER" ;; esac
	[ -n "$token" ] || die "the API gave no token: $answer"
	mkdir -p "$(dirname "$TOKENFILE")"
	( umask 077 && printf '%s\\n' "$token" > "$TOKENFILE" )
	echo "kept in $TOKENFILE (mode 600); the API's /tokens lists and revokes it"
}}

# health -- what /health answers with this machine's token, or with none.
health() {{
	if [ -s "$TOKENFILE" ]; then
		printf 'header = "Authorization: Bearer %s"\\n' "$(head -n 1 "$TOKENFILE")"
	else
		printf '\\n'
	fi | curl -sS -K - --max-time 15 "$@" "$URL/xymon/api/v1/health" 2>"$HOME/.xymon-setup.err" || {{
		grep -qi 'certificate' "$HOME/.xymon-setup.err" && die "$URL has a certificate this machine does not trust: copy the server's certificate, or the CA that signed it, to $CAFILE and run this again"
		die "no answer from $URL: $(cat "$HOME/.xymon-setup.err")"
	}}
	rm -f "$HOME/.xymon-setup.err"
}}

# The API reached, its certificate trusted, before a password is asked: a
# certificate this machine does not know is said here, with what to do.
health "$@" >/dev/null

if [ -n "$USER" ]; then
	# A token from an earlier run is kept while it works; a revoked or
	# replaced one is replaced.
	if [ -s "$TOKENFILE" ]; then
		case $(health "$@") in *unauthorized*) new_token "$@" ;; esac
	else
		new_token "$@"
	fi
	if [ -e "$OLDPASS" ]; then
		rm -f "$OLDPASS"
		echo "removed $OLDPASS: the token replaces the password, which is no longer kept"
	fi
fi

say "does the API answer?"
answer=$(health "$@")
case $answer in
	*'"alive":true'*) echo "yes: $answer" ;;
	*'"alive":false'*) echo "the API answers, but its xymond does not: $answer" ;;
	*unauthorized*) die "the API refused the token in $TOKENFILE: remove it and run this again" ;;
	*) die "an unexpected answer from $URL: $answer" ;;
esac

if command -v claude >/dev/null 2>&1; then
	say "registering the MCP server with Claude Code as $NAME"
	claude mcp remove --scope user "$NAME" >/dev/null 2>&1 || true
	set -- --scope user "$NAME" -e XYMONAPI_URL="$URL"
	[ -n "$USER" ] && set -- "$@" -e XYMONAPI_TOKEN_FILE="$TOKENFILE"
	[ -n "$ca" ] && set -- "$@" -e XYMONAPI_CA="$CAFILE"
	claude mcp add "$@" -e XYMONAPI_PYTHON="$VENV/bin/python3" -- "$PREFIX/bin/xymonapi-mcp"
else
	say "Claude Code is not here; to register the MCP server later:"
	echo "  claude mcp add --scope user $NAME -e XYMONAPI_URL=$URL \\\\"
	[ -n "$USER" ] && echo "    -e XYMONAPI_TOKEN_FILE=$TOKENFILE \\\\"
	[ -n "$ca" ] && echo "    -e XYMONAPI_CA=$CAFILE \\\\"
	echo "    -e XYMONAPI_PYTHON=$VENV/bin/python3 -- $PREFIX/bin/xymonapi-mcp"
fi

say "done"
cat <<EOF
From a shell, with these in the environment:
  export XYMONAPI_URL=$URL${{USER:+ XYMONAPI_TOKEN_FILE=$TOKENFILE}}${{ca:+ XYMONAPI_CA=$CAFILE}}
  $PREFIX/bin/xymonapi-rag search "what does purple mean"
In Claude Code, just ask: "which hosts are red?"
EOF
"""

ENV = """# The Xymon API at {url}, for the user {user_or_none}: written by that API on {date}.
# Two settings, as a shell reads them: source this file, or paste the lines
# after export. The token file is the setup script's, the same path; without
# the script, POST {{"client": NAME}} to /xymon/api/v1/tokens with your
# password, and write the token it answers there, mode 600.
XYMONAPI_URL={url_q}
XYMONAPI_TOKEN_FILE={tokenfile}
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


def installed_commit() -> str:
    """The commit in the COMMIT file beside this module, or ""."""
    try:
        with open(_COMMIT, encoding="ascii") as fd:
            ref = fd.readline().strip()
    except (OSError, UnicodeDecodeError):
        return ""
    return ref if _HEX.fullmatch(ref) else ""


def render(url: str, user: str, name: str, fmt: str) -> str:
    # The script's own expression for the place, which a shell sourcing the
    # env format expands the same way.
    tokenfile = f"${{XDG_CONFIG_HOME:-$HOME/.config}}/xymon-api/{name}.token"
    ref = installed_commit()
    # Where the address came from, said in the script: a Host header is the
    # requester's word, and XYMONAPI_PUBLIC_URL is the fix when it is wrong.
    url_from = ("XYMONAPI_PUBLIC_URL, set on the server" if PUBLIC_URL and url == PUBLIC_URL
                else "the one this request came through (its Host header); if it is "
                     "wrong, set XYMONAPI_PUBLIC_URL on the server")
    vars_ = dict(url=url, url_q=shlex.quote(url), user=user, user_q=shlex.quote(user),
                 url_from=url_from,
                 ref=ref, ref_q=shlex.quote(ref),
                 user_or_none=user or "(none: the API asks for no password)",
                 name=name, name_q=shlex.quote(name), repo=REPO, repo_q=shlex.quote(REPO),
                 tokenfile=tokenfile, script=f"{name}-setup.sh",
                 date=time.strftime("%Y-%m-%d", time.gmtime()))
    return (ENV if fmt == "env" else SCRIPT).format(**vars_)
