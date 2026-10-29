#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# tests/api/xymonapi-auth.sh
#
# With XYMONAPI_PASSWD naming an htpasswd file, the API answers only a user
# and password that file holds, and 401 with a WWW-Authenticate challenge to
# anything else. Both formats Apache's htpasswd writes are accepted: $apr1$,
# its default and what Xymon's useradm and chpasswd create, and bcrypt. A user
# name that looks like an option is refused, not passed to htpasswd as one.
# A password file the API cannot read stops it from starting.
#
# Skips where the API cannot run (tests/lib/xymonapi.sh). Needs the xymon
# client of the Xymon tree in XYMON_SRC (for a free port), Apache's htpasswd
# and curl.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)

require_bin XYMONCLIENT "$XYMON_SRC/common/xymon"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"
command -v htpasswd >/dev/null 2>&1 || skip "Apache's htpasswd is not installed"

work=$(mktempdir)
register_cleanup 'stop_process "$API_PID"'

htpasswd -cb "$work/htpasswd" alice secret 2>/dev/null
htpasswd -bB "$work/htpasswd" bob s3cret 2>/dev/null
grep -q '^alice:\$apr1\$' "$work/htpasswd" || fail "htpasswd did not write alice in its \$apr1\$ format"
grep -q '^bob:\$2y\$' "$work/htpasswd" || fail "htpasswd did not write bob as bcrypt"

# The answers checked here need no xymond: /health says alive:false without
# one, and the password is checked first, on every path.
export XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:1" XYMONAPI_PASSWD="$work/htpasswd"
start_api

url="http://127.0.0.1:$API_PORT/xymon/api/v1/health"
code() { curl -s -o /dev/null -w '%{http_code}' "$@" "$url"; }

assert_equal "401" "$(code)" "no user and password"
# Header names are case-insensitive, and uvicorn sends them in lower case.
assert_contains 'www-authenticate: basic realm="xymon"' "$(curl -s -D - -o /dev/null "$url" | tr -d '\r' | tr 'A-Z' 'a-z')" "the 401 asks for Basic authentication"
assert_equal "200" "$(code -u alice:secret)" "alice, \$apr1\$, right password"
assert_equal "401" "$(code -u alice:wrong)" "alice, wrong password"
assert_equal "200" "$(code -u bob:s3cret)" "bob, bcrypt, right password"
assert_equal "401" "$(code -u carol:secret)" "a user the file does not hold"
assert_equal "401" "$(code -u -b:secret)" "a user name that looks like an option"

stop_process "$API_PID"
API_PID=""
rc=0
XYMONAPI_PASSWD="$work/no-such-file" "$ROOT/xymonapi.sh" > "$work/nofile.log" 2>&1 || rc=$?
assert_equal "1" "$rc" "the API with a password file it cannot read"
assert_contains "cannot read XYMONAPI_PASSWD" "$(cat "$work/nofile.log")" "and it says why"

pass "XYMONAPI_PASSWD lets in only the users and passwords of its htpasswd file, in either format"
