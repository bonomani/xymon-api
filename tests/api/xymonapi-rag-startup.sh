#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-rag-startup.sh
#
# As an xymonlaunch task, xymonapi-rag index can start seconds before the
# API listens: at boot, both are started together. An API that gives no
# answer at all is tried again for about a minute, so the index is built
# once it is up. An API that answers -- here a 401, for a password it was
# not given -- is not retried: that failure is reported at once.
#
# The pages are one small real one from the Xymon tree in XYMON_SRC, so the
# embedding is quick; the history is written here in xymond_history's
# format. Skips where the API or the search cannot run; the 401 part also
# needs Apache's htpasswd. Needs curl.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)

require_bin XYMONCLIENT "$XYMON_SRC/common/xymon"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"

work=$(mktempdir)
register_cleanup 'stop_process "$API_PID"'

mkdir -p "$work/docs" "$work/hist" "$work/histlogs/web_example_com/http"
cp "$XYMON_SRC/common/hosts.cfg.5" "$work/docs/" || fail "no common/hosts.cfg.5 in XYMON_SRC"
printf 'web.example.com http 1699400000 1699300000 100000 red green 0\n' > "$work/hist/allevents"
printf 'red Tue Nov  7 23:33:20 2023 HTTP 500 from https://web.example.com/login\n' \
	> "$work/histlogs/web_example_com/http/Tue_Nov_7_23:33:20_2023"

export TZ=UTC XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:1" \
	XYMONHISTDIR="$work/hist" XYMONHISTLOGS="$work/histlogs"
unset XYMONAPI_RAG_MODEL
export XYMONAPI_RAG_DOCS="$work/docs" XYMONAPI_RAG_INDEX="$work/index.npz" \
	XYMONAPI_RAG_SINCE=1699000000

# The search's own requirements first, with the API not yet started, so a
# missing module skips here rather than fails below.
rc=0
"$ROOT/rag/xymonapi-rag.sh" search 'anything' > /dev/null 2> "$work/rag.err" || rc=$?
[ "$rc" -eq 77 ] && skip "$(cat "$work/rag.err")"

# 1. Nothing listens on the API's port when index starts; the API comes up
#    some seconds later, as at boot. index must wait and then succeed.
API_PORT=$(free_port) || fail "no free port for the API"
export XYMONAPI_URL="http://127.0.0.1:$API_PORT"
"$ROOT/rag/xymonapi-rag.sh" index > "$work/index.out" 2> "$work/rag.err" &
RAG_PID=$!
sleep 12
kill -0 "$RAG_PID" 2>/dev/null || fail "index gave up within 12 seconds of an API that was not up yet: $(tail -n 3 "$work/rag.err")"
XYMONAPI_LISTEN="127.0.0.1:$API_PORT" "$ROOT/xymonapi.sh" > "$work/api.log" 2>&1 &
API_PID=$!
deadline=$(( $(date +%s) + 60 ))
until curl -s --max-time 5 -o /dev/null "$XYMONAPI_URL/xymon/api/v1/health"; do
	kill -0 "$API_PID" 2>/dev/null || { rc=0; wait "$API_PID" || rc=$?; API_PID=""
		[ "$rc" -eq 77 ] && skip "$(cat "$work/api.log")"
		fail "the API exited with $rc: $(tail -n 5 "$work/api.log")"; }
	[ "$(date +%s)" -lt "$deadline" ] || fail "the API did not answer within 60 seconds"
	sleep 0.2
done
rc=0
wait "$RAG_PID" || rc=$?
[ "$rc" -eq 0 ] || fail "index exited with $rc once the API was up: $(tail -n 5 "$work/rag.err")"
assert_contains "indexed" "$(cat "$work/index.out")" "index built the index after waiting for the API"
assert_contains 'web.example.com http' \
	"$("$ROOT/rag/xymonapi-rag.sh" search -k 1 --kind history 'HTTP 500 on the login page' 2>/dev/null)" \
	"and the history read through the late API is in it"

# 2. An API that answers, with a 401, is not waited for.
command -v htpasswd >/dev/null 2>&1 || { pass_partial "index waits for an API that is not up yet (the 401 part needs htpasswd)"; }
htpasswd -cbB "$work/passwd" alice secret > /dev/null 2>&1 || fail "htpasswd could not write $work/passwd"
stop_process "$API_PID"; API_PID=""
XYMONAPI_PASSWD="$work/passwd" start_api
export XYMONAPI_URL="http://127.0.0.1:$API_PORT"
unset XYMONAPI_USER XYMONAPI_PASSWORD
began=$(date +%s)
rc=0
XYMONAPI_RAG_INDEX="$work/index2.npz" "$ROOT/rag/xymonapi-rag.sh" index > /dev/null 2> "$work/rag.err" || rc=$?
took=$(( $(date +%s) - began ))
[ "$rc" -ne 0 ] || fail "index succeeded against an API that answered 401"
assert_contains 'answered 401' "$(cat "$work/rag.err")" "a 401 is reported"
[ "$took" -lt 10 ] || fail "and should be reported at once, not after $took seconds of retries"
[ -e "$work/index2.npz" ] && fail "a failed indexing left an index behind"

pass "xymonapi-rag index waits for an API that is not up yet, as at boot, and does not wait for one that refuses it"
