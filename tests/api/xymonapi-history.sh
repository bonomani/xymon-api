#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-history.sh
#
# /events returns the colour changes in $XYMONHISTDIR/allevents, the newest
# first, filtered by host, test and time and cut to a limit; with no allevents
# yet, none. /histlog returns the status text saved under $XYMONHISTLOGS for
# one of those changes, found by the name xymond_history gives it: the host
# with its dots as underscores, then the test, then the local time as
# Tue_Nov_7_23:33:20_2023 -- no leading zero on the day, which the time here
# is chosen to show. Names that could leave those directories, and a time or
# limit the API cannot read, are 400.
#
# The files are written here, in xymond_history's format, and the API runs in
# UTC so the saved file's name is known. Skips where the API cannot run
# (tests/lib/xymonapi.sh). Needs the xymon client of the Xymon tree in
# XYMON_SRC (for a free port), and curl.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)

require_bin XYMONCLIENT "$XYMON_SRC/common/xymon"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"

work=$(mktempdir)
register_cleanup 'stop_process "$API_PID"'

# host test time prevtime prevduration newcolour oldcolour trend
mkdir -p "$work/hist" "$work/histlogs/web_example_com/http" "$work/empty"
cat > "$work/hist/allevents" <<'EOF'
web.example.com http 1699400000 1699300000 100000 red green 0
db.example.com conn 1699400300 1699000000 400000 yellow green 0
web.example.com http 1699400600 1699400000 600 green red 0
EOF
printf 'red Tue Nov  7 23:33:20 2023 HTTP 500 from /login\n' \
	> "$work/histlogs/web_example_com/http/Tue_Nov_7_23:33:20_2023"

export TZ=UTC XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:1" \
	XYMONHISTDIR="$work/hist" XYMONHISTLOGS="$work/histlogs"
start_api

all=$(api_get /events)
first=${all%%\},*}
assert_contains '"epoch":1699400600' "$first" "the newest change comes first"
assert_contains '"verdict":"ok","previous":"critical","previous_duration":600' "$first" "with its verdicts and how long the previous one lasted"
assert_equal "3" "$(printf '%s' "$all" | grep -o '"epoch":' | wc -l | tr -d ' ')" "/events returns every change"

one=$(api_get '/events?entity=web.example.com&test=http&limit=1')
assert_equal "1" "$(printf '%s' "$one" | grep -o '"epoch":' | wc -l | tr -d ' ')" "limit=1"
assert_contains '"epoch":1699400600' "$one" "keeps the newest"

since=$(api_get '/events?since=1699400300')
assert_not_contains '"epoch":1699400000' "$since" "since leaves out an older change"
assert_contains '"epoch":1699400300' "$since" "and keeps one at that very time"

log=$(api_get '/histlog?entity=web.example.com&test=http&time=1699400000')
assert_contains 'HTTP 500 from /login' "$log" "/histlog returns the saved status text"

assert_equal "404" "$(api_code '/histlog?entity=web.example.com&test=http&time=1699400001')" "a time with no saved status"
assert_equal "400" "$(api_code '/histlog?entity=../web.example.com&test=http&time=1699400000')" "a host name with ../"
assert_equal "400" "$(api_code '/histlog?entity=web.example.com&test=http&time=yesterday')" "a time that is not a number"
assert_equal "400" "$(api_code '/events?entity=..&test=http')" "/events, a host name of .."
assert_equal "400" "$(api_code '/events?limit=0')" "/events, limit 0"
assert_equal "400" "$(api_code '/events?limit=1001')" "/events, a limit above 1000"

# A server where nothing has changed colour yet has no allevents.
stop_process "$API_PID"
API_PID=""
XYMONHISTDIR="$work/empty" start_api
assert_equal '{"items":[]}' "$(api_get /events)" "no allevents: no events, not an error"

pass "/events reads allevents newest first and filtered, /histlog finds the saved status by xymond_history's name, and bad names are refused"
