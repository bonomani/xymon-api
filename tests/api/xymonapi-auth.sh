#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-auth.sh
#
# With XYMONAPI_PASSWD naming an htpasswd file, the API answers only a user
# and password that file holds, and 401 with a WWW-Authenticate challenge to
# anything else. Both formats Apache's htpasswd writes are accepted: $apr1$,
# its default and what Xymon's useradm and chpasswd create, and bcrypt. Every
# path is covered, /openapi.json and FastAPI's /docs included. A user
# name that looks like an option is refused, not passed to htpasswd as one.
# A password file the API cannot read stops it from starting. /client
# writes a setup script for the user who asked, at the address asked; run
# as a laptop runs it, that script gets a password holding a space, a
# quote, a backslash and a glob character to the API as it is, keeps the
# token it gets for this machine's short hostname instead of the password,
# and registers the MCP server with that token file.
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
export XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:1" XYMONAPI_PASSWD="$work/htpasswd" \
	XYMONAPI_TOKENS="$work/tokens/tokens"
start_api

url="http://127.0.0.1:$API_PORT/xymon/api/v1/health"
code() { curl -s -o /dev/null -w '%{http_code}' "$@" "$url"; }

rc=0
assert_equal "401" "$(code)" "no user and password"
# Header names are case-insensitive, and uvicorn sends them in lower case.
assert_contains 'www-authenticate: basic realm="xymon"' "$(curl -s -D - -o /dev/null "$url" | tr -d '\r' | tr 'A-Z' 'a-z')" "the 401 asks for Basic authentication"
assert_equal "200" "$(code -u alice:secret)" "alice, \$apr1\$, right password"
assert_equal "200" "$(code -H "Authorization: basic $(printf 'alice:secret' | base64)")" "the scheme spelt basic, in lower case"
assert_equal "401" "$(code -u alice:wrong)" "alice, wrong password"
assert_equal "200" "$(code -u bob:s3cret)" "bob, bcrypt, right password"
assert_equal "401" "$(code -u carol:secret)" "a user the file does not hold"
assert_equal "401" "$(code -u -b:secret)" "a user name that looks like an option"

# FastAPI serves these beside the API's own paths; a password covers them too.
for path in /openapi.json /docs; do
	assert_equal "401" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$API_PORT$path")" "$path without a user"
	assert_equal "200" "$(curl -s -o /dev/null -w '%{http_code}' -u alice:secret "http://127.0.0.1:$API_PORT$path")" "$path with a user"
done

# /client: a setup script for the laptop that asked, naming the user who
# asked and the address the request came through -- the proxy's, when its
# headers say so -- and never the password.
script=$(curl -s -u alice:secret "http://127.0.0.1:$API_PORT/xymon/api/v1/client")
assert_contains "URL=http://127.0.0.1:$API_PORT" "$script" "/client writes the address the request came to"
assert_contains "USER=alice" "$script" "and the user who asked"
assert_contains "NAME=xymon" "$script" "and the default name"
assert_not_contains "secret" "$script" "and never the password"
printf '%s\n' "$script" > "$work/setup.sh"
sh -n "$work/setup.sh" || fail "/client's script does not parse: $(sh -n "$work/setup.sh" 2>&1)"
assert_contains 'text/x-shellscript' "$(curl -s -D - -o /dev/null -u alice:secret "http://127.0.0.1:$API_PORT/xymon/api/v1/client" | tr 'A-Z' 'a-z')" "served as a shell script"
proxied=$(curl -s -u alice:secret -H 'X-Forwarded-Host: xymon.example.ch' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$API_PORT/xymon/api/v1/client?name=xymon-lab")
assert_contains "URL=https://xymon.example.ch" "$proxied" "behind a proxy, the proxy's address and scheme"
assert_contains "NAME=xymon-lab" "$proxied" "and the name asked for"
assert_contains 'xymon-api/$NAME.password' "$proxied" "which names the password file too"
assert_equal "400" "$(curl -s -o /dev/null -w '%{http_code}' -u alice:secret "http://127.0.0.1:$API_PORT/xymon/api/v1/client?name=bad%20name")" "a name with a space"
assert_equal "400" "$(curl -s -o /dev/null -w '%{http_code}' -u alice:secret "http://127.0.0.1:$API_PORT/xymon/api/v1/client?format=exe")" "a format that is neither"
env=$(curl -s -u bob:s3cret "http://127.0.0.1:$API_PORT/xymon/api/v1/client?format=env")
assert_contains "for the user bob" "$env" "format=env gives the settings, for the user who asked"
assert_contains 'XYMONAPI_TOKEN_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/xymon-api/xymon.token' "$env" "with the token file where the script keeps it"
assert_not_contains "git clone" "$env" "and no script"

# The script's own password path: the password goes to curl in a config on
# its stdin, with " and \ escaped as curl wants, so one holding a space, a
# quote, a backslash and a glob character reaches the API as it is, and is
# on no command line. The script is run as a laptop would, up to its health
# check and registration: git, make and claude are stubs on PATH (claude
# records its arguments), the virtualenv is already there, and the password
# file is written, so nothing is fetched, built, or asked.
hard='pa ss"wo\rd*'
htpasswd -bB "$work/htpasswd" carol "$hard" 2>/dev/null || fail "htpasswd could not add carol"
curl -s -u "carol:$hard" "http://127.0.0.1:$API_PORT/xymon/api/v1/client" > "$work/carol.sh"
grep -q '^USER=carol$' "$work/carol.sh" || fail "/client did not write carol: $(head -n 20 "$work/carol.sh")"
lap=$work/lap
mkdir -p "$work/stub" "$lap/src/.git" "$lap/prefix/libexec/xymonapi/venv/bin" "$lap/cfg/xymon-api"
printf '#!/bin/sh\nexit 0\n' > "$work/stub/git"
cp "$work/stub/git" "$work/stub/make"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/claude.args"\n' "$lap" > "$work/stub/claude"
: > "$lap/prefix/libexec/xymonapi/venv/bin/python3"
chmod 755 "$work/stub/git" "$work/stub/make" "$work/stub/claude" "$lap/prefix/libexec/xymonapi/venv/bin/python3"
# A password file an earlier version of the script kept: it must go.
printf '%s\n' "$hard" > "$lap/cfg/xymon-api/xymon.password"
rc=0
# The password on stdin, as a person typing it gives it to read.
out=$(cd "$lap" && printf '%s\n' "$hard" | HOME="$lap" XDG_CONFIG_HOME="$lap/cfg" XYMONAPI_SRC="$lap/src" PATH="$work/stub:$PATH" \
	sh "$work/carol.sh" "$lap/prefix" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "the setup script failed with $rc: $out"
assert_not_contains 'refused the password' "$out" "the API took carol's password from the script's curl"
assert_contains 'the API answers' "$out" "and the script read the answer (no xymond here, so alive is false)"
tok=$lap/cfg/xymon-api/xymon.token
assert_file_exists "$tok"
assert_match '^xat_' "$(cat "$tok")" "the script kept a token"
assert_equal "-rw-------" "$(ls -l "$tok" | cut -c1-10)" "readable by this user alone"
[ -e "$lap/cfg/xymon-api/xymon.password" ] && fail "the old password file was left on the laptop"
assert_not_contains "$hard" "$(cat "$tok")" "the token is not the password"
assert_contains "XYMONAPI_TOKEN_FILE=$tok" "$(cat "$lap/claude.args")" "the MCP registration names the token file"
assert_not_contains 'PASSWORD' "$(cat "$lap/claude.args")" "and no password setting"
# Named by the short hostname, as the API lists it.
h=$(hostname 2>/dev/null || uname -n)
assert_contains "\"client\":\"${h%%.*}\"" "$(curl -s -u "carol:$hard" "http://127.0.0.1:$API_PORT/xymon/api/v1/tokens")" "the token is for this machine's short name"

# A Ctrl-C at the password prompt ends the script, with echo back on and
# nothing asked, in bash too: bash, out of POSIX mode, runs a trap and goes
# back to the read, which then shows the password as it is typed. On a
# terminal, which tests/lib/ctrl-c.py gives it; a new config directory, so
# the script asks; the token kept above shows that none was issued for this
# machine, since one would have replaced it.
mkdir -p "$lap/cfg2"
rc=0
out=$(cd "$lap" && HOME="$lap" XDG_CONFIG_HOME="$lap/cfg2" XYMONAPI_SRC="$lap/src" PATH="$work/stub:$PATH" \
	"${XYMONAPI_PYTHON:-python3}" "$ROOT/tests/lib/ctrl-c.py" 'password: ' bash "$work/carol.sh" "$lap/prefix" 2>&1) || rc=$?
assert_equal "130" "$rc" "Ctrl-C at the password prompt ends the script under bash ($out)"
assert_contains "echo on" "$out" "with echo back on"
[ -e "$lap/cfg2/xymon-api/xymon.token" ] && fail "a token was kept after Ctrl-C"
assert_equal "200" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$tok")" "http://127.0.0.1:$API_PORT/xymon/api/v1/health")" "and none issued: the earlier token still works"

# Xymon's own password file is the default: with XYMONHOME set and
# etc/xymonpasswd there, nothing else need be set, and the API asks for
# what the web pages ask for. The empty string turns it off.
stop_process "$API_PID"
API_PID=""
mkdir -p "$work/home/etc"; cp "$work/htpasswd" "$work/home/etc/xymonpasswd"
unset XYMONAPI_PASSWD
XYMONHOME="$work/home" start_api
url="http://127.0.0.1:$API_PORT/xymon/api/v1/health"
assert_equal "401" "$(code)" "with XYMONHOME's etc/xymonpasswd and no setting, a password is asked"
assert_equal "200" "$(code -u alice:secret)" "the web pages' user is let in"
stop_process "$API_PID"
API_PID=""
XYMONHOME="$work/home" XYMONAPI_PASSWD="" start_api
url="http://127.0.0.1:$API_PORT/xymon/api/v1/health"
assert_equal "200" "$(code)" "XYMONAPI_PASSWD set empty: no password asked"
stop_process "$API_PID"
API_PID=""
rc=0
XYMONAPI_PASSWD="$work/no-such-file" "$ROOT/xymonapi.sh" > "$work/nofile.log" 2>&1 || rc=$?
assert_equal "1" "$rc" "the API with a password file it cannot read"
assert_contains "cannot read XYMONAPI_PASSWD" "$(cat "$work/nofile.log")" "and it says why"

# The MCP server's client sends the user and password too, the password from
# a file when XYMONAPI_PASSWORD_FILE names one: an environment every Xymon
# program reads need then hold only the file's name.
printf 'secret\n' > "$work/password"
start_api
XYMONAPI_USER=alice XYMONAPI_PASSWORD_FILE="$work/password" \
	mcp "http://127.0.0.1:$API_PORT" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health","arguments":{}}}' || rc=$?
answer=$(grep '"id":3' "$work/mcp.out") || fail "no answer to the health call: $(tail -n 5 "$work/mcp.err")"
assert_contains 'alive' "$answer" "the MCP client is let in with the password from XYMONAPI_PASSWORD_FILE"
assert_not_contains '"isError":true' "$answer" "and not refused"
XYMONAPI_USER=alice XYMONAPI_PASSWORD_FILE="$work/no-such-file" \
	mcp "http://127.0.0.1:$API_PORT" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health","arguments":{}}}' || true
assert_contains 'cannot read XYMONAPI_PASSWORD_FILE' "$(grep '"id":3' "$work/mcp.out")" "a password file that is not there is a readable error"

pass "XYMONAPI_PASSWD lets in only the users and passwords of its htpasswd file, in either format"
