#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# tests/api/xymonapi-series.sh
#
# /series reads one dataset of HOST/TEST.rrd under XYMONRRDS and returns its
# values over the time range asked for, and the API refuses a host, test or
# metric name that could leave that directory or reach rrdtool as syntax:
# "../" in a host, ":" in a test. A time it cannot read is refused too, and an
# RRD file that does not exist is a 404. /graphs refuses the same names.
#
# The RRD is made here, with three known values at fixed times, so the answer
# is known in advance. Skips where the API cannot run (tests/lib/xymonapi.sh).
# Needs the xymon client of the Xymon tree in XYMON_SRC (for a free port),
# rrdtool and curl.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)

require_bin XYMONCLIENT "$XYMON_SRC/common/xymon"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"
command -v rrdtool >/dev/null 2>&1 || skip "rrdtool is not installed"

work=$(mktempdir)
register_cleanup 'stop_process "$API_PID"'

# Three five-minute steps, from a time that is a multiple of the step, so
# each update lands on a step of its own and is stored as given.
t0=1699999800
mkdir -p "$work/rrd/host.example.com"
rrd="$work/rrd/host.example.com/la.rrd"
rrdtool create "$rrd" --start "$t0" --step 300 DS:la:GAUGE:600:U:U RRA:AVERAGE:0.5:1:100
rrdtool update "$rrd" "$((t0 + 300)):1" "$((t0 + 600)):2" "$((t0 + 900)):3"

# /series needs no xymond, but the launcher refuses to start without XYMSRV.
export XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:1" XYMONRRDS="$work/rrd"
start_api

body=$(api_get "/series?entity=host.example.com&test=la&metric=la&from=$t0&to=$((t0 + 900))")
for v in 1.0 2.0 3.0; do
	assert_contains "\"v\":$v" "$body" "/series returns the value $v stored in the RRD"
done
assert_contains '"metric":"la"' "$body" "/series names the dataset it read"

assert_equal "400" "$(api_code '/series?entity=../host.example.com&test=la&metric=la')" "a host name with ../"
assert_equal "400" "$(api_code '/series?entity=host.example.com&test=la:x&metric=la')" "a test name with a colon"
assert_equal "400" "$(api_code '/series?entity=host.example.com&test=la&metric=l:a')" "a metric name with a colon"
assert_equal "400" "$(api_code '/series?entity=host.example.com&test=la&metric=la&from=yesterday')" "a time that is not now, a number or like -24h"
assert_equal "404" "$(api_code '/series?entity=host.example.com&test=disk&metric=la')" "an RRD file that does not exist"

# /graphs checks the same names before it asks showgraph, so this needs no
# web server. What showgraph then draws is not tested here.
assert_equal "400" "$(api_code '/graphs?entity=../host.example.com&test=la')" "/graphs, a host name with ../"

pass "/series reads the RRD values asked for, and /series and /graphs refuse names that leave XYMONRRDS"
