#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-graphs.sh
#
# /graphs fetches the PNG showgraph.cgi draws, through its wrapper
# showgraph.sh at XYMONSERVERCGIURL. xymonserver.cfg ships that as a path,
# /xymon-cgi, which the web pages use relative to themselves; the API then
# needs XYMONWEBHOST for the host, as Xymon's own pages do. An absolute
# XYMONSERVERCGIURL needs no XYMONWEBHOST; a path without one is a 502 that
# names the missing setting, not a stack trace.
#
# The web server is tests/lib/fake-showgraph.py, which records the request
# and answers a PNG. Skips where the API cannot run (tests/lib/xymonapi.sh).
# Needs the xymon client of the Xymon tree in XYMON_SRC (for a free port)
# and curl.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)

require_bin XYMONCLIENT "$XYMON_SRC/common/xymon"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"

work=$(mktempdir)
WEB_PID=""
register_cleanup 'stop_process "$WEB_PID" "$API_PID"'

"${XYMONAPI_PYTHON:-python3}" "$ROOT/tests/lib/fake-showgraph.py" "$work/web.port" "$work/web.req" &
# shellcheck disable=SC2034 # read by the cleanup
WEB_PID=$!
for _ in $(seq 1 50); do [ -s "$work/web.port" ] && break; sleep 0.1; done
[ -s "$work/web.port" ] || fail "the stand-in web server did not start"
WEB="http://127.0.0.1:$(cat "$work/web.port")"

# graph QUERY -- fetch /graphs?QUERY into $work/graph, print the status code.
graph() {
	curl -s --max-time 30 -o "$work/graph" -w '%{http_code}' \
		"http://127.0.0.1:$API_PORT/xymon/api/v1/graphs?$1"
}

# The launcher refuses to start without XYMSRV; /graphs needs no xymond.
export XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:1"

# 1. As xymonserver.cfg ships it: a path, and XYMONWEBHOST for the host.
export XYMONSERVERCGIURL="/xymon-cgi" XYMONWEBHOST="$WEB"
start_api
assert_equal "200" "$(graph 'entity=web.example.com&test=conn&from=1699999800&to=1700000700')" "/graphs with a path and XYMONWEBHOST"
assert_equal "89504e470d0a1a0a" "$(head -c 8 "$work/graph" | od -An -tx1 | tr -d ' \n')" "and the answer is the PNG showgraph sent"
req=$(cat "$work/web.req")
assert_match '^/xymon-cgi/showgraph\.sh\?' "$req" "showgraph.sh is asked under XYMONSERVERCGIURL"
assert_contains 'host=web.example.com' "$req" "for the host"
assert_contains 'service=conn' "$req" "and the test"
assert_contains 'graph_start=1699999800' "$req" "from the time asked"
assert_contains 'graph_end=1700000700' "$req" "to the time asked"
assert_contains 'action=view' "$req" "as a view"
stop_process "$API_PID"; API_PID=""

# 2. An absolute XYMONSERVERCGIURL stands alone.
export XYMONSERVERCGIURL="$WEB/xymon-cgi"
unset XYMONWEBHOST
start_api
assert_equal "200" "$(graph 'entity=web.example.com&test=conn')" "/graphs with an absolute XYMONSERVERCGIURL and no XYMONWEBHOST"
assert_match '^/xymon-cgi/showgraph\.sh\?' "$(cat "$work/web.req")" "asks the same showgraph.sh"
stop_process "$API_PID"; API_PID=""

# 3. A path with nothing to put in front of it is refused, and says what is missing.
export XYMONSERVERCGIURL="/xymon-cgi"
start_api
assert_equal "502" "$(graph 'entity=web.example.com&test=conn')" "/graphs with a path and no XYMONWEBHOST"
assert_contains 'XYMONWEBHOST' "$(cat "$work/graph")" "and the answer names the missing setting"

pass "/graphs reaches showgraph.sh through XYMONWEBHOST when XYMONSERVERCGIURL is a path, as xymonserver.cfg ships it"
