#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-tls.sh
#
# With a certificate and key -- xymond's own, $XYMONHOME/etc/tls/xymond.pem
# and .key as xymon-tls(7) places them, or the files XYMONAPI_TLS_CERT and
# XYMONAPI_TLS_KEY name -- the API speaks HTTPS on its port, and plain HTTP
# gets no answer. /client then writes an https:// address, and its script
# says where to put a certificate it does not trust before asking for a
# password. A key that others
# can read, or a certificate without its key, stops the API from starting.
# The MCP client trusts the certificate XYMONAPI_CA names, and says what to
# do when it is given none for a certificate the system does not trust.
#
# Skips where the API cannot run (tests/lib/xymonapi.sh) or openssl is not
# installed. Needs the xymon client of the Xymon tree in XYMON_SRC and curl.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)

require_bin XYMONCLIENT "$XYMON_SRC/common/xymon"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"
command -v openssl >/dev/null 2>&1 || skip "openssl is not installed"

work=$(mktempdir)
register_cleanup 'stop_process "$API_PID"'

# A self-signed certificate for 127.0.0.1, as xymon-tls(7) would make one.
mkdir -p "$work/home/etc/tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=xymon-test" \
	-addext "subjectAltName=IP:127.0.0.1" \
	-keyout "$work/home/etc/tls/xymond.key" -out "$work/home/etc/tls/xymond.pem" > /dev/null 2>&1 \
	|| fail "openssl could not make a certificate"
chmod 600 "$work/home/etc/tls/xymond.key"

export XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:1"

# xymond's own files, found through XYMONHOME: nothing else set.
export XYMONHOME="$work/home" XYMONAPI_TLS_CERT="$work/home/etc/tls/xymond.pem"
start_api
assert_contains '"alive"' "$(api_get /health)" "the API answers over HTTPS with xymond's certificate"
assert_equal "000" "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$API_PORT/xymon/api/v1/health" || true)" "and not over plain HTTP"
assert_contains "URL=https://127.0.0.1:$API_PORT" "$(api_get /client)" "/client writes an https:// address"
assert_contains "CAFILE=" "$(api_get /client)" "and knows where a certificate to trust would go"

# The setup script, for a user, with no certificate to trust: it says what
# to do -- copy the certificate to CAFILE -- before asking for a password,
# which would go nowhere. git and make are stubs, and the virtualenv is
# there, so nothing is fetched or built; the user is written in, since
# this API asks for none.
lap=$work/lap
mkdir -p "$work/stub" "$lap/src/.git" "$lap/prefix/libexec/xymonapi/venv/bin" "$lap/cfg"
printf '#!/bin/sh\nexit 0\n' > "$work/stub/git"
cp "$work/stub/git" "$work/stub/make"
cp "$work/stub/git" "$lap/prefix/libexec/xymonapi/venv/bin/python3"
chmod 755 "$work/stub/git" "$work/stub/make" "$lap/prefix/libexec/xymonapi/venv/bin/python3"
api_get /client | sed "s/^USER=''$/USER=carol/" > "$work/setup.sh"
grep -q '^USER=carol$' "$work/setup.sh" || fail "no USER= line to fill in /client's script"
rc=0
out=$(cd "$lap" && printf 'secret\n' | HOME="$lap" XDG_CONFIG_HOME="$lap/cfg" XYMONAPI_SRC="$lap/src" PATH="$work/stub:$PATH" \
	sh "$work/setup.sh" "$lap/prefix" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "the setup script went on with a certificate it does not trust: $out"
assert_contains "copy the server's certificate" "$out" "the setup script says what to do with an unknown certificate"
assert_not_contains "your password" "$out" "before it asks for a password"

# The MCP client: refused without the CA, let in with it.
mcp "https://127.0.0.1:$API_PORT" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health","arguments":{}}}' || true
answer=$(grep '"id":3' "$work/mcp.out") || fail "no answer to the health call: $(tail -n 5 "$work/mcp.err")"
assert_contains 'certificate this machine does not trust' "$answer" "the MCP client refuses a certificate it does not know"
assert_contains 'XYMONAPI_CA' "$answer" "and names the setting"
XYMONAPI_CA="$work/home/etc/tls/xymond.pem" \
	mcp "https://127.0.0.1:$API_PORT" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health","arguments":{}}}' || true
answer=$(grep '"id":3' "$work/mcp.out")
assert_contains 'alive' "$answer" "with XYMONAPI_CA it is let in"
assert_not_contains '"isError":true' "$answer" "and not refused"
stop_process "$API_PID"; API_PID=""

# Files named explicitly, elsewhere.
cp "$work/home/etc/tls/xymond.pem" "$work/other.pem"; cp "$work/home/etc/tls/xymond.key" "$work/other.key"
unset XYMONHOME
XYMONAPI_TLS_CERT="$work/other.pem" XYMONAPI_TLS_KEY="$work/other.key" start_api
assert_contains '"alive"' "$(XYMONAPI_TLS_CERT="$work/other.pem" api_get /health)" "named certificate and key files"
stop_process "$API_PID"; API_PID=""

# Refusals, each with its reason.
unset XYMONAPI_TLS_CERT
chmod 644 "$work/other.key"
rc=0
XYMONAPI_TLS_CERT="$work/other.pem" XYMONAPI_TLS_KEY="$work/other.key" "$ROOT/xymonapi.sh" > "$work/open.log" 2>&1 || rc=$?
assert_equal "1" "$rc" "a key others can read"
assert_contains 'readable by others' "$(cat "$work/open.log")" "and it says so"
rc=0
XYMONAPI_TLS_CERT="$work/other.pem" XYMONAPI_TLS_KEY="$work/no-such.key" "$ROOT/xymonapi.sh" > "$work/nokey.log" 2>&1 || rc=$?
assert_equal "1" "$rc" "a certificate without its key"
assert_contains 'cannot read the TLS key' "$(cat "$work/nokey.log")" "and it says which"
rm "$work/home/etc/tls/xymond.key"
rc=0
XYMONHOME="$work/home" "$ROOT/xymonapi.sh" > "$work/half.log" 2>&1 || rc=$?
assert_equal "1" "$rc" "xymond's certificate present but not its key"
assert_contains 'xymond.key' "$(cat "$work/half.log")" "and it names the file"

pass "with xymond's certificate, or named files, the API speaks HTTPS, /client says so, the MCP client trusts XYMONAPI_CA, and a bad key refuses to start"
