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
# limit the API cannot read, are 400; an XYMONHISTDIR that is not a directory
# is 502, not an empty history. At most 1 MiB of a saved status is returned,
# counted in bytes.
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

# Filtered, then cut: the newest db.example.com change is not the newest one.
db=$(api_get '/events?entity=db.example.com&limit=1')
assert_contains '"entity":"db.example.com","test":"conn"' "$db" "entity= keeps that host's changes"
assert_contains '"epoch":1699400300' "$db" "and limit applies after the filter"
assert_equal '{"items":[]}' "$(api_get '/events?test=nosuchtest')" "test= with no change of that test"

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
assert_equal "400" "$(api_code '/events?before=soon')" "/events, before that is not a number"
assert_equal "400" "$(api_code '/events?limit=0')" "/events, limit 0"
assert_equal "400" "$(api_code '/events?limit=1001')" "/events, a limit above 1000"
# A digit int() refuses, and a time too large for the calendar.
assert_equal "400" "$(api_code '/events?since=%C2%B2')" "/events, since=² (a digit, not 0-9)"
assert_equal "400" "$(api_code '/histlog?entity=web.example.com&test=http&time=%C2%B2')" "/histlog, time=²"
assert_equal "400" "$(api_code '/histlog?entity=web.example.com&test=http&time=99999999999999999999')" "/histlog, a time out of range"

# The 1 MiB limit is on bytes: 600000 two-byte characters are 1.2 MB on disk,
# and what comes back must hold about 1 MiB of them, not all.
awk 'BEGIN { printf "red "; for (i = 0; i < 600000; i++) printf "\303\251" }' \
	> "$work/histlogs/web_example_com/http/Tue_Nov_7_23:43:20_2023"
curl -s --max-time 30 -o "$work/big.json" "http://127.0.0.1:$API_PORT/xymon/api/v1/histlog?entity=web.example.com&test=http&time=1699400600"
size=$(wc -c < "$work/big.json" | tr -d ' ')
[ "$size" -gt 1000000 ] && [ "$size" -lt 1100000 ] \
	|| fail "a saved status of 1.2 MB came back as $size bytes, not about 1 MiB"

# A history of thousands of changes is read from the end of the file: the
# newest 1000 come, before= gives the page after them, and the last line,
# written without a newline, is read like the others.
stop_process "$API_PID"; API_PID=""
mkdir -p "$work/long"
awk 'BEGIN { for (i = 1; i <= 2500; i++) printf "h%d.example.com conn %d %d 60 red green 0\n", i % 7, 1700000000 + i * 10, 1700000000 + i * 10 - 60 }' > "$work/long/allevents"
printf 'last.example.com conn 1700030000 1700029940 60 red green 0' >> "$work/long/allevents"
XYMONHISTDIR="$work/long" start_api
page=$(api_get '/events?limit=1000')
assert_equal "1000" "$(printf '%s' "$page" | grep -o '"epoch":' | wc -l | tr -d ' ')" "limit=1000 gives a thousand"
assert_contains '"entity":"last.example.com"' "$(printf '%s' "$page" | head -c 200)" "the newest first: the last line, which ends without a newline"
assert_contains '"epoch":1700015020' "$page" "down to the thousandth-newest"
assert_not_contains '"epoch":1700015010' "$page" "and not the one before it"
page2=$(api_get '/events?limit=1000&before=1700015020')
assert_contains '"epoch":1700015010' "$(printf '%s' "$page2" | head -c 200)" "before= continues where the page ended"
assert_not_contains '"epoch":1700015020' "$page2" "without repeating its last change"
third=$(api_get '/events?limit=1000&before=1700005020')
assert_equal "501" "$(printf '%s' "$third" | grep -o '"epoch":' | wc -l | tr -d ' ')" "the last page holds the rest"
assert_equal '{"items":[]}' "$(api_get '/events?before=1700000010')" "and nothing is older than the first"

# A server where nothing has changed colour yet has no allevents.
stop_process "$API_PID"
API_PID=""
XYMONHISTDIR="$work/empty" start_api
assert_equal '{"items":[]}' "$(api_get /events)" "no allevents: no events, not an error"

# But a directory that is not there is a wrong setting, not an empty history.
stop_process "$API_PID"
API_PID=""
XYMONHISTDIR="$work/no-such-dir" start_api
assert_equal "502" "$(api_code /events)" "XYMONHISTDIR naming no directory"

pass "/events reads allevents newest first and filtered, /histlog finds the saved status by xymond_history's name, and bad names are refused"
