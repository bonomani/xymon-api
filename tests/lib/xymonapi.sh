#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
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
# The API is started through xymonapi.sh, the launcher xymonlaunch runs.
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

# start_api -- start the API on a port of its own and wait until it answers.
# A port that turned out to be taken is a retry.
start_api() {
	local deadline rc
	for _ in 1 2 3; do
		API_PORT=$(free_port) || fail "no free port for the API"
		XYMONAPI_LISTEN="127.0.0.1:$API_PORT" \
			"$ROOT/xymonapi.sh" > "$work/api.log" 2>&1 &
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
			curl -s -o /dev/null "http://127.0.0.1:$API_PORT/xymon/api/v1/health" && return 0
			sleep 0.2
		done
		fail "the API did not answer within 60 seconds: $(tail -n 5 "$work/api.log")"
	done
	fail "no free port for the API after three attempts"
}

# api_get PATH -- the body the API answers for PATH, under /xymon/api/v1.
api_get() {
	curl -s "http://127.0.0.1:$API_PORT/xymon/api/v1$1"
}

# api_code PATH -- the HTTP status the API answers for PATH.
api_code() {
	curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$API_PORT/xymon/api/v1$1"
}
