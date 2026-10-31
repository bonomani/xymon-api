#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/lib/xymonapi.sh
#
# Starting the API (xymonapi(8)) for the tests that ask it something.
#
# The tests run against a built Xymon source tree, named by XYMON_SRC, and use
# its test helpers: assert.sh for fail, skip and the rest, and xymond-daemon.sh
# to start a xymond and to find a free port. They are sourced here, so a test
# sources this file alone. The caller sets $ROOT and $work, skips unless curl is
# installed, and exports what the API reads -- XYMON, XYMSRV and whatever else
# the test needs -- before calling start_api. start_api sets API_PORT and
# API_PID; the caller stops API_PID in its cleanup.
#
# The API is started through xymonapi.sh, the launcher xymonlaunch runs:
# the checkout's, or an installed one's when API_ROOT names its directory.
# It exits 77 when this machine lacks what the API needs (Python 3.10 and its
# modules), and start_api then skips the test.

if [ -z "${XYMON_SRC:-}" ] || [ ! -f "$XYMON_SRC/tests/lib/assert.sh" ]; then
	echo "XYMON_SRC must name a built Xymon source tree (it is '${XYMON_SRC:-}')" >&2
	exit 1
fi
# shellcheck source=/dev/null
. "$XYMON_SRC/tests/lib/assert.sh"
# shellcheck source=/dev/null
. "$XYMON_SRC/tests/lib/xymond-daemon.sh"

API_PORT=""
API_PID=""
# With XYMONAPI_TLS_CERT in the environment the API speaks HTTPS, and curl
# must trust that certificate: a self-signed one is its own CA.
API_SCHEME="http"
API_CURL="curl -s"

# start_api -- start the API on a port of its own and wait until it answers.
# A port that turned out to be taken is a retry.
start_api() {
	local deadline rc
	if [ -n "${XYMONAPI_TLS_CERT:-}" ]; then
		API_SCHEME="https"; API_CURL="curl -s --cacert $XYMONAPI_TLS_CERT"
	else
		API_SCHEME="http"; API_CURL="curl -s"
	fi
	for _ in 1 2 3; do
		API_PORT=$(free_port) || fail "no free port for the API"
		# The index /search reads: the test's own, never the one in this
		# user's cache, which a developer's machine may well have.
		XYMONAPI_LISTEN="127.0.0.1:$API_PORT" XYMONAPI_RAG_INDEX="${XYMONAPI_RAG_INDEX:-$work/no-index.npz}" \
			"${API_ROOT:-$ROOT}/xymonapi.sh" > "$work/api.log" 2>&1 &
		API_PID=$!
		deadline=$(( $(date +%s) + 60 ))
		while [ "$(date +%s)" -lt "$deadline" ]; do
			if ! kill -0 "$API_PID" 2>/dev/null; then
				rc=0; wait "$API_PID" || rc=$?
				API_PID=""
				[ "$rc" -eq 77 ] && skip "$(cat "$work/api.log")"
				grep -q 'address already in use' "$work/api.log" && continue 2
				fail "the API exited with $rc: $(tail -n 5 "$work/api.log")"
			fi
			# shellcheck disable=SC2086 # API_CURL is a command with options
			$API_CURL --max-time 5 -o /dev/null "$API_SCHEME://127.0.0.1:$API_PORT/xymon/api/v1/health" && return 0
			sleep 0.2
		done
		fail "the API did not answer within 60 seconds: $(tail -n 5 "$work/api.log")"
	done
	fail "no free port for the API after three attempts"
}

# api_get PATH -- the body the API answers for PATH, under /xymon/api/v1.
api_get() {
	# shellcheck disable=SC2086
	$API_CURL --max-time 30 "$API_SCHEME://127.0.0.1:$API_PORT/xymon/api/v1$1"
}

# api_code PATH -- the HTTP status the API answers for PATH.
api_code() {
	# shellcheck disable=SC2086
	$API_CURL --max-time 30 -o /dev/null -w '%{http_code}' "$API_SCHEME://127.0.0.1:$API_PORT/xymon/api/v1$1"
}

# mcp URL REQUEST... -- run the MCP server for the API at URL, send it the
# initialize handshake and then each REQUEST (one JSON-RPC message, id 3 on the
# last), keep its stdin open until the answer to id 3 is in, and leave its
# stdout in $work/mcp.out. Returns the server's exit status.
mcp() {
	local url=$1 rc=0 deadline; shift
	: > "$work/mcp.out"
	deadline=$(( $(date +%s) + 120 ))
	{
		printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"xymonapi-test","version":"0"}}}' \
			'{"jsonrpc":"2.0","method":"notifications/initialized"}' "$@"
		while ! grep -q '"id":3' "$work/mcp.out" && [ "$(date +%s)" -lt "$deadline" ]; do
			sleep 0.1
		done
	} | XYMONAPI_URL="$url" "$ROOT/mcp-server/xymonapi-mcp.sh" > "$work/mcp.out" 2> "$work/mcp.err" || rc=$?
	return "$rc"
}
