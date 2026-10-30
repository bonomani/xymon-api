#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
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

printf 'page test Test\n127.0.0.1 red.example.com # conn\n127.0.0.1 green.example.com # conn\n127.0.0.1 disk.example.com # disk\n127.0.0.1 dis.example.com # conn\n127.0.0.1 disk2.example.com # disk\n127.0.0.1 enc.example.com # conn\n127.0.0.1 lt.example.com # conn\n' > "$work/hosts.cfg"

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
send "status disk,example,com.disk yellow Filesystems NOT ok
/var at 91% - 2.1G of 24G free
/boot ok"
# An acknowledgement names the status by the cookie xymond gave it.
sleep 0.4
cookie=$("$XYMONCLIENT" "127.0.0.1:$PORT" "xymondboard host=disk.example.com test=disk fields=cookie")
[ -n "$cookie" ] || fail "xymond gave the yellow status no cookie"
send "xymondack $cookie 60 cleaning old kernels, back in an hour"
send "status dis,example,com.conn red down"
send "disable dis,example,com.conn 7200 maintenance window"
# A host whose name begins with another's, with a status of its own.
send "status disk2,example,com.disk green Filesystems all ok"
# Characters xymondboard encodes on its way out: | tab \ and a literal \n.
send "status enc,example,com.conn green C:\\temp | cpu	load \\n not a newline"
# A lifetime with a unit and a group, both legal on the command line.
send "status+5h/group:ops lt,example,com.conn green up for 5h"
# An acknowledgement that has already run out: 0 minutes.
cookie=$("$XYMONCLIENT" "127.0.0.1:$PORT" "xymondboard host=red.example.com test=conn fields=cookie")
[ -n "$cookie" ] || fail "xymond gave the red status no cookie"
send "xymondack $cookie 0 already over"
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

# /status: the text behind a colour, with what was done about it.
st=$(api_get '/status?entity=disk.example.com&test=disk')
assert_contains '"verdict":"warning"' "$st" "/status gives the verdict"
assert_contains '"text":"Filesystems NOT ok' "$st" "and the status text, without the command line that set it"
assert_contains '/var at 91%' "$st" "newlines unescaped"
assert_contains '2.1G of 24G free\n/boot ok' "$st" "line by line"
assert_contains '"acknowledged":{' "$st" "an acknowledged status says so"
assert_contains 'cleaning old kernels' "$st" "with the acknowledgement's words"
assert_not_contains '"disabled"' "$st" "and is not disabled"
dis=$(api_get '/status?entity=dis.example.com&test=conn')
assert_contains '"disabled":{' "$dis" "a disabled test says so"
assert_contains 'maintenance window' "$dis" "with the reason given"
assert_contains '"verdict":"disabled"' "$dis" "and its verdict is disabled, as the board shows it blue"
assert_equal "404" "$(api_code '/status?entity=green.example.com&test=disk')" "/status of a test the host has not"
# xymondboard matches host= and test= as unanchored regular expressions;
# the API must not pass on another host's status as this one's.
assert_contains '"text":"Filesystems NOT ok' "$(api_get '/status?entity=disk.example.com&test=disk')" "disk.example.com gets its own text, not disk2's"
assert_contains '"text":"Filesystems all ok"' "$(api_get '/status?entity=disk2.example.com&test=disk')" "and disk2.example.com its own"
assert_equal "404" "$(api_code '/status?entity=disk.example&test=disk')" "a host name that is the start of a real one"
assert_equal "404" "$(api_code '/status?entity=disk.example.com&test=dis')" "a test name that is the start of a real one"
assert_equal "404" "$(api_code '/status?entity=d.sk.example.com&test=disk')" "a dot is a dot, not any character"
enc=$(api_get '/status?entity=enc.example.com&test=conn')
assert_contains '"text":"C:\\temp | cpu\tload \\n not a newline"' "$enc" "a pipe, a tab, a backslash and a literal \\n are decoded as xymondboard encoded them"
assert_contains '"text":"up for 5h"' "$(api_get '/status?entity=lt.example.com&test=conn')" "the command line is left out when it has a lifetime with a unit and a group"
assert_not_contains '"acknowledged"' "$(api_get '/status?entity=red.example.com&test=conn')" "an acknowledgement that ran out is not reported, though xymond still carries it"
assert_equal "400" "$(api_code '/status?entity=../etc&test=disk')" "/status with a host name that is a path"

assert_equal "404" "$(api_code /views)" "an operation the API does not implement"

pass "the API reports xymond's board: states, verdicts, alarms, one status with its text and acknowledgement, and health"
