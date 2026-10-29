#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-mcp.sh
#
# The MCP server answers an MCP client with what the API answers: a red status
# sent to a real xymond comes back from the states tool as critical, through
# the API. It lists the seven tools, all read-only; it reports an API it cannot
# reach as a tool error the client can read, not as a crash; and it writes
# nothing but protocol messages on stdout.
#
# The client here is this script: MCP over stdio is JSON-RPC, one message per
# line, so it writes the requests and reads the answers. Skips where the API
# or the MCP server cannot run (tests/lib/xymonapi.sh). Needs a server build
# of Xymon in XYMON_SRC, and curl.

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

printf 'page test Test\n127.0.0.1 red.example.com # conn\n' > "$work/hosts.cfg"
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
"$XYMONCLIENT" "127.0.0.1:$PORT" "status red,example,com.conn red down" || fail "xymond rejected the status"
sleep 0.4

export XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:$PORT"
start_api

rc=0
mcp "http://127.0.0.1:$API_PORT" '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' || rc=$?
[ "$rc" -eq 77 ] && skip "$(cat "$work/mcp.err")"
[ "$rc" -eq 0 ] || fail "the MCP server exited with $rc: $(tail -n 5 "$work/mcp.err")"
list=$(grep '"id":3' "$work/mcp.out") || fail "no answer to tools/list: $(tail -n 5 "$work/mcp.err")"
for tool in health states alarms entities series search_docs search_history; do
	assert_contains "\"name\":\"$tool\"" "$list" "tools/list names $tool"
done
assert_equal "7" "$(printf '%s' "$list" | grep -o '"readOnlyHint":true' | wc -l | tr -d ' ')" "every tool is marked read-only"

mcp "http://127.0.0.1:$API_PORT" \
	'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"states","arguments":{"entity":"red.example.com","test":"conn"}}}' \
	|| fail "the MCP server exited with an error: $(tail -n 5 "$work/mcp.err")"
answer=$(grep '"id":3' "$work/mcp.out") || fail "no answer to the states call"
assert_contains 'red.example.com:conn' "$answer" "the states tool returns the red status"
assert_contains 'critical' "$answer" "as a critical verdict"
assert_not_contains '"isError":true' "$answer" "and not as an error"
while IFS= read -r line; do
	case $line in '{"jsonrpc":"2.0"'*) ;; *) fail "stdout carried something other than a protocol message: $line" ;; esac
done < "$work/mcp.out"

# An API that is not there: a port nothing listens on.
mcp "http://127.0.0.1:1" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health","arguments":{}}}' \
	|| fail "the MCP server exited with an error: $(tail -n 5 "$work/mcp.err")"
answer=$(grep '"id":3' "$work/mcp.out") || fail "no answer to the health call"
assert_contains '"isError":true' "$answer" "an unreachable API is a tool error"
assert_contains 'cannot reach xymonapi' "$answer" "whose text says what went wrong"
grep -q Traceback "$work/mcp.err" && fail "an unreachable API was logged as a crash: $(cat "$work/mcp.err")"

pass "the MCP server answers with the API's board, its tools are read-only, and an unreachable API is a readable tool error"
