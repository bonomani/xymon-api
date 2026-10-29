#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# tests/api/xymonapi-board.sh
#
# The API reports the board a running xymond holds: a status sent to xymond
# comes back from /states with its colour turned into a verdict, a red one is
# listed in /alarms and a green one is not, and /health names the xymond it
# asked. An operation the API does not implement answers 404 rather than
# sample data.
#
# Skips where the API cannot run (tests/lib/xymonapi.sh). Needs a built Xymon
# server tree in XYMON_SRC, and curl.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)

require_bin XYMOND "$XYMON_SRC/xymond/xymond"
require_bin XYMONCLIENT "$XYMON_SRC/common/xymon"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"

work=$(mktempdir)

# shellcheck disable=SC2034 # read by xymond-daemon.sh and the cleanup
XYMOND_PID=""
register_cleanup 'stop_process "$API_PID" "$XYMOND_PID"'

printf 'page test Test\n127.0.0.1 red.example.com # conn\n127.0.0.1 green.example.com # conn\n' > "$work/hosts.cfg"

mkdir -p "$work/home/etc" "$work/home/tmp" "$work/home/www"
require_cfg XYMONSERVER_CFG "$XYMON_SRC/xymond/etcfiles/xymonserver.cfg"
sed -e 's|^XYMONHOME=.*|XYMONHOME="'"$work"'/home"|' \
    -e 's|^XYMONTMP=.*|XYMONTMP="'"$work"'/home/tmp"|' \
	"$XYMONSERVER_CFG" > "$work/xymonserver.cfg"

xymond_launch() {
	local port=$1; shift
	"$XYMOND" --no-daemon --listen="127.0.0.1:$port" \
		--hosts="$work/hosts.cfg" --env="$work/xymonserver.cfg" \
		--pidfile="$work/xymond.pid" --checkpoint-file="$work/chk.out" \
		"$@" \
		> "$work/xymond.log" 2>&1 &
	# shellcheck disable=SC2034 # read by xymond-daemon.sh and the cleanup
	XYMOND_PID=$!
}

start_xymond

send() { "$XYMONCLIENT" "127.0.0.1:$PORT" "$1" || fail "xymond rejected: $1"; }
send "status red,example,com.conn red down"
send "status green,example,com.conn green up"
sleep 0.4

export XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:$PORT"
start_api

health=$(api_get /health)
assert_contains '"alive":true' "$health" "/health while xymond runs"
assert_contains '"server_version":"xymond' "$health" "/health names the xymond it asked"

red=$(api_get '/states?entity=red.example.com&test=conn')
assert_contains '"id":"red.example.com:conn"' "$red" "/states for the red host"
assert_contains '"verdict":"critical"' "$red" "a red status is a critical verdict"

green=$(api_get '/states?entity=green.example.com&test=conn')
assert_contains '"verdict":"ok"' "$green" "a green status is an ok verdict"

alarms=$(api_get /alarms)
assert_contains '"id":"red.example.com:conn"' "$alarms" "a red status is an alarm"
assert_not_contains 'green.example.com' "$alarms" "a green status is not an alarm"

assert_equal "404" "$(api_code /views)" "an operation the API does not implement"

pass "the API reports xymond's board: states, verdicts, alarms and health"
