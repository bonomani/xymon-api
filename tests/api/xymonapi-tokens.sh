#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-tokens.sh
#
# A user who gives the password gets a token for one machine, and that token
# opens the API on its own; the token file holds its SHA-256, never the
# token. A second token for the same user and machine replaces the first,
# which stops working at once; a revoked one stops working too. A user sees
# and revokes only their own tokens; a token cannot make, list or revoke
# tokens, so a stolen one cannot renew itself; a token that is not valid, or
# altered by one character, is refused. With no XYMONAPI_PASSWD there are no
# users and no tokens. The MCP client sends the token from
# XYMONAPI_TOKEN_FILE.
#
# Skips where the API cannot run (tests/lib/xymonapi.sh). Needs the xymon
# client of the Xymon tree in XYMON_SRC (for a free port), Apache's htpasswd
# and curl; the last check also needs the mcp module.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)

require_bin XYMONCLIENT "$XYMON_SRC/common/xymon"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"
command -v htpasswd >/dev/null 2>&1 || skip "Apache's htpasswd is not installed"

work=$(mktempdir)
register_cleanup 'stop_process "$API_PID"'

htpasswd -cbB "$work/htpasswd" alice secret 2>/dev/null
htpasswd -bB "$work/htpasswd" bob s3cret 2>/dev/null

export XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:1" XYMONAPI_PASSWD="$work/htpasswd" \
	XYMONAPI_TOKENS="$work/var/tokens"
start_api

api=http://127.0.0.1:$API_PORT/xymon/api/v1
# as WHO ARGS... -- curl with a user and password ("alice:secret") or a token.
as() {
	local who=$1; shift
	case $who in
		xat_*) curl -s --max-time 30 -H "Authorization: Bearer $who" "$@" ;;
		*)     curl -s --max-time 30 -u "$who" "$@" ;;
	esac
}
code() { local who=$1; shift; as "$who" -o /dev/null -w '%{http_code}' "$@"; }
issue() {
	as "$1" -X POST -H 'Content-Type: application/json' -d "{\"client\":\"$2\"}" "$api/tokens" \
		| sed -n 's/.*"token": *"\(xat_[A-Za-z0-9_-]*\)".*/\1/p'
}

t1=$(issue alice:secret laptop)
[ -n "$t1" ] || fail "POST /tokens gave alice no token"
assert_equal "200" "$(code "$t1" "$api/health")" "the token opens the API"
assert_equal "201" "$(code alice:secret -X POST -H 'Content-Type: application/json' -d '{"client":"desktop"}' "$api/tokens")" "a new token is 201"

assert_file_exists "$work/var/tokens"
grep -q "$t1" "$work/var/tokens" && fail "the token file holds the token itself"
assert_equal "-rw-------" "$(ls -l "$work/var/tokens" | cut -c1-10)" "the token file is the API's alone"

# One per user and machine: a second token for laptop stops the first.
t2=$(issue alice:secret laptop)
[ -n "$t2" ] && [ "$t2" != "$t1" ] || fail "a second token for laptop was not a new one"
assert_equal "401" "$(code "$t1" "$api/health")" "the replaced token is refused"
assert_equal "200" "$(code "$t2" "$api/health")" "its replacement works"

# A token cannot manage tokens.
assert_equal "401" "$(code "$t2" "$api/tokens")" "a token may not list tokens"
assert_equal "401" "$(code "$t2" -X POST -H 'Content-Type: application/json' -d '{"client":"other"}' "$api/tokens")" "nor make one"
assert_equal "401" "$(code "$t2" -X DELETE "$api/tokens/laptop")" "nor revoke one"

# Altered by one character, or not a token at all.
last=${t2: -1}; [ "$last" = A ] && other=B || other=A
assert_equal "401" "$(code "${t2%?}$other" "$api/health")" "a token altered by one character"
assert_equal "401" "$(code xat_nonsense "$api/health")" "something that is not a token"

# A user's own tokens, and only those.
list=$(as alice:secret "$api/tokens")
assert_contains '"client":"laptop"' "$list" "alice lists her laptop"
assert_contains '"client":"desktop"' "$list" "and her desktop"
assert_not_contains 'sha256' "$list" "without the digests"
t3=$(issue bob:s3cret laptop)
issue bob:s3cret bobbox > /dev/null
assert_not_contains 'bobbox' "$(as alice:secret "$api/tokens")" "alice does not see bob's tokens"
assert_equal "204" "$(code alice:secret -X DELETE "$api/tokens/laptop")" "alice revokes her laptop"
assert_equal "401" "$(code "$t2" "$api/health")" "and its token is refused"
assert_equal "200" "$(code "$t3" "$api/health")" "bob's laptop, of the same name, still works"
assert_equal "404" "$(code alice:secret -X DELETE "$api/tokens/laptop")" "revoking what is not there is 404"
assert_equal "400" "$(code alice:secret -X POST -H 'Content-Type: application/json' -d '{"client":"../x"}' "$api/tokens")" "a machine name that is not one"

# The MCP client, with the token in XYMONAPI_TOKEN_FILE.
printf '%s\n' "$t3" > "$work/bob.token"
rc=0
export XYMONAPI_TOKEN_FILE="$work/bob.token"
mcp "http://127.0.0.1:$API_PORT" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health","arguments":{}}}' || rc=$?
unset XYMONAPI_TOKEN_FILE
if [ "$rc" -eq 77 ]; then
	skip "$(cat "$work/mcp.err")"
fi
answer=$(grep '"id":3' "$work/mcp.out") || fail "no answer from the MCP server: $(tail -n 5 "$work/mcp.err")"
assert_not_contains '"isError":true' "$answer" "the MCP client is let in with the token file"

# No password, no users: no tokens either.
stop_process "$API_PID"
API_PID=""
XYMONAPI_PASSWD="" start_api
assert_equal "400" "$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"client":"laptop"}' "http://127.0.0.1:$API_PORT/xymon/api/v1/tokens")" "tokens without XYMONAPI_PASSWD"

pass "a token per user and machine opens the API, replaces the last, is revoked on its own, and cannot manage tokens"
