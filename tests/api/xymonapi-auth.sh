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
# A password file the API cannot read stops it from starting. /client alone
# is open: it writes a setup script with the address asked and no user or
# commit; /health gives the commit, to a user. Run as a laptop runs it, the
# script asks for the user and gets a password holding a space, a quote, a
# backslash and a glob character to the API as it is, keeps the token it
# gets for this machine's short hostname instead of the password, installs
# the commit /health gives, and registers the MCP server with that token
# file.
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

# The API as make install lays it out, with a commit recorded beside it, so
# that /health has one to give and the script one to install.
"${MAKE:-make}" -C "$ROOT" install XYMONHOME="$work/inst" MANDIR="$work/man" >"$work/install.log" 2>&1 \
	|| fail "make install failed: $(tail -n 5 "$work/install.log")"
commit=0123456789abcdef0123456789abcdef01234567
printf '%s\n' "$commit" > "$work/inst/ext/xymonapi/COMMIT"
API_ROOT=$work/inst/ext/xymonapi

# The answers checked here need no xymond: /health says alive:false without
# one, and the password is checked first, on every path but /client.
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

# /client: open, a password set or not, since its script holds nothing
# secret -- the address the request came through, the proxy's when its
# headers say so, and no user or commit. The commit is /health's, behind
# the password.
assert_equal "200" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$API_PORT/xymon/api/v1/client")" "/client without a user"
script=$(curl -s "http://127.0.0.1:$API_PORT/xymon/api/v1/client")
assert_contains "URL=http://127.0.0.1:$API_PORT" "$script" "/client writes the address the request came to"
assert_contains "NAME=xymon" "$script" "and the default name"
printf '%s\n' "$script" | grep -q '^USER=' && fail "/client wrote a USER= line"
assert_not_contains "$commit" "$script" "and not the commit"
assert_contains "\"commit\":\"$commit\"" "$(curl -s -u alice:secret "$url")" "/health gives the commit to a user"
assert_not_contains "$commit" "$(curl -s "$url")" "and not to a stranger"
printf '%s\n' "$script" > "$work/setup.sh"
sh -n "$work/setup.sh" || fail "/client's script does not parse: $(sh -n "$work/setup.sh" 2>&1)"
assert_contains 'text/x-shellscript' "$(curl -s -D - -o /dev/null "http://127.0.0.1:$API_PORT/xymon/api/v1/client" | tr 'A-Z' 'a-z')" "served as a shell script"
proxied=$(curl -s -H 'X-Forwarded-Host: xymon.example.ch' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$API_PORT/xymon/api/v1/client?name=xymon-lab")
assert_contains "URL=https://xymon.example.ch" "$proxied" "behind a proxy, the proxy's address and scheme"
assert_contains "NAME=xymon-lab" "$proxied" "and the name asked for"
assert_contains 'xymon-api/$NAME.password' "$proxied" "which names the password file too"
assert_equal "400" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$API_PORT/xymon/api/v1/client?name=bad%20name")" "a name with a space"
assert_equal "400" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$API_PORT/xymon/api/v1/client?format=exe")" "a format that is neither"
env=$(curl -s "http://127.0.0.1:$API_PORT/xymon/api/v1/client?format=env")
assert_contains "XYMONAPI_URL=http://127.0.0.1:$API_PORT" "$env" "format=env gives the settings"
assert_contains 'XYMONAPI_TOKEN_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/xymon-api/xymon.token' "$env" "with the token file where the script keeps it"
assert_not_contains "git clone" "$env" "and no script"

# The script's own password path: the user and password are read from the
# terminal -- here stdin -- and the password goes to curl in a config on its
# stdin, with " and \ escaped as curl wants, so one holding a space, a
# quote, a backslash and a glob character reaches the API as it is, and is
# on no command line. The script is run as a laptop would, up to its health
# check and registration: git, make, claude and codex are stubs on PATH
# (git, claude and codex record their arguments) and the virtualenv is
# already there, so nothing is fetched or built.
hard='pa ss"wo\rd*'
htpasswd -bB "$work/htpasswd" carol "$hard" 2>/dev/null || fail "htpasswd could not add carol"
curl -s "http://127.0.0.1:$API_PORT/xymon/api/v1/client" > "$work/carol.sh"
lap=$work/lap
mkdir -p "$work/stub" "$lap/src/.git" "$lap/prefix/libexec/xymonapi/venv/bin" "$lap/cfg/xymon-api"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/git.args"\n' "$lap" > "$work/stub/git"
printf '#!/bin/sh\nexit 0\n' > "$work/stub/make"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/claude.args"\n' "$lap" > "$work/stub/claude"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/codex.args"\n' "$lap" > "$work/stub/codex"
printf '#!/bin/sh\nexit 0\n' > "$lap/prefix/libexec/xymonapi/venv/bin/python3"
chmod 755 "$work/stub/git" "$work/stub/make" "$work/stub/claude" "$work/stub/codex" "$lap/prefix/libexec/xymonapi/venv/bin/python3"
# A password file an earlier version of the script kept: it must go.
printf '%s\n' "$hard" > "$lap/cfg/xymon-api/xymon.password"
rc=0
# The user and password on stdin, as a person typing them gives them to read.
out=$(cd "$lap" && printf 'carol\n%s\n' "$hard" | HOME="$lap" XDG_CONFIG_HOME="$lap/cfg" XYMONAPI_SRC="$lap/src" PATH="$work/stub:$PATH" \
	sh "$work/carol.sh" "$lap/prefix" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "the setup script failed with $rc: $out"
assert_not_contains 'refused the password' "$out" "the API took carol's password from the script's curl"
assert_contains "$(printf -- '--detach\n%s' "$commit")" "$(cat "$lap/git.args")" "the script installs the commit /health gave"
assert_contains 'the API answers' "$out" "and the script read the answer (no xymond here, so alive is false)"
tok=$lap/cfg/xymon-api/xymon.token
assert_file_exists "$tok"
assert_match '^xat_' "$(cat "$tok")" "the script kept a token"
assert_equal "-rw-------" "$(ls -l "$tok" | cut -c1-10)" "readable by this user alone"
[ -e "$lap/cfg/xymon-api/xymon.password" ] && fail "the old password file was left on the laptop"
assert_not_contains "$hard" "$(cat "$tok")" "the token is not the password"
assert_contains "XYMONAPI_TOKEN_FILE=$tok" "$(cat "$lap/claude.args")" "the MCP registration names the token file"
assert_not_contains 'PASSWORD' "$(cat "$lap/claude.args")" "and no password setting"
assert_contains "XYMONAPI_TOKEN_FILE=$tok" "$(cat "$lap/codex.args")" "Codex is registered too, with the token file"
assert_contains "$lap/prefix/bin/xymonapi-mcp" "$(cat "$lap/codex.args")" "and the MCP server"
assert_not_contains 'PASSWORD' "$(cat "$lap/codex.args")" "and no password setting"
# Named by the short hostname, as the API lists it.
h=$(hostname 2>/dev/null || uname -n)
assert_contains "\"client\":\"${h%%.*}\"" "$(curl -s -u "carol:$hard" "http://127.0.0.1:$API_PORT/xymon/api/v1/tokens")" "the token is for this machine's short name"

# A Ctrl-C at the password prompt ends the script, with echo back on and
# nothing asked, in bash too: bash, out of POSIX mode, runs a trap and goes
# back to the read, which then shows the password as it is typed. On a
# terminal, which tests/lib/ctrl-c.py gives it; a new config directory, so
# the script asks; the user given in XYMONAPI_USER, so the password is the
# first thing asked; the token kept above shows that none was issued for
# this machine, since one would have replaced it.
mkdir -p "$lap/cfg2"
rc=0
out=$(cd "$lap" && HOME="$lap" XDG_CONFIG_HOME="$lap/cfg2" XYMONAPI_SRC="$lap/src" PATH="$work/stub:$PATH" \
	XYMONAPI_USER=carol "${XYMONAPI_PYTHON:-python3}" "$ROOT/tests/lib/ctrl-c.py" 'password for carol: ' bash "$work/carol.sh" "$lap/prefix" 2>&1) || rc=$?
assert_equal "130" "$rc" "Ctrl-C at the password prompt ends the script under bash ($out)"
assert_contains "echo on" "$out" "with echo back on"
[ -e "$lap/cfg2/xymon-api/xymon.token" ] && fail "a token was kept after Ctrl-C"
assert_equal "200" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$tok")" "http://127.0.0.1:$API_PORT/xymon/api/v1/health")" "and none issued: the earlier token still works"

# Without make, the script says so before it starts, rather than failing
# half way with the shell's "not found": a PATH of git, curl and the tools
# the script's first lines use, and no make.
mkdir -p "$work/nomake"
cp "$work/stub/git" "$work/nomake/git"
for t in curl hostname tr sed cut; do
	p=$(command -v "$t") || continue
	ln -s "$p" "$work/nomake/$t"
done
rc=0
sh_bin=$(command -v sh)
out=$(cd "$lap" && HOME="$lap" XDG_CONFIG_HOME="$lap/cfg" XYMONAPI_SRC="$lap/src" PATH="$work/nomake" \
	"$sh_bin" "$work/carol.sh" "$lap/prefix" 2>&1 < /dev/null) || rc=$?
[ "$rc" -ne 0 ] || fail "the setup script went on without make: $out"
assert_contains "make is needed" "$out" "the setup script says make is missing"

# A virtualenv a run before left half made -- its python3 there, without
# mcp -- is made again, not taken as it is: the Python here makes a venv
# whose pip records that it ran.
printf '#!/bin/sh\nexit 1\n' > "$lap/prefix/libexec/xymonapi/venv/bin/python3"
cat > "$work/stub/python-venv" <<STUB
#!/bin/sh
if [ "\$1" = -m ]; then
	mkdir -p "\$3/bin"
	printf '#!/bin/sh\\nexit 0\\n' > "\$3/bin/python3"
	printf '#!/bin/sh\\necho pip >> "$lap/pip.log"\\n' > "\$3/bin/pip"
	chmod 755 "\$3/bin/python3" "\$3/bin/pip"
fi
exit 0
STUB
chmod 755 "$work/stub/python-venv"
rc=0
out=$(cd "$lap" && HOME="$lap" XDG_CONFIG_HOME="$lap/cfg" XYMONAPI_SRC="$lap/src" PATH="$work/stub:$PATH" \
	XYMONAPI_PYTHON="$work/stub/python-venv" sh "$work/carol.sh" "$lap/prefix" 2>&1 < /dev/null) || rc=$?
[ "$rc" -eq 0 ] || fail "the setup script failed with $rc over a half-made venv: $out"
assert_file_exists "$lap/pip.log"
assert_contains "pip" "$(cat "$lap/pip.log")" "a half-made venv is made again, and mcp installed in it"

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

# The MCP server's client sends a token and nothing else: a user and
# password left in its environment, as an older setup wrote them, are not
# sent, and the refusal says to get a token. (A token letting it in is
# xymonapi-tokens's.)
printf 'secret\n' > "$work/password"
XYMONAPI_PASSWD="$work/htpasswd" start_api
rc=0
XYMONAPI_USER=alice XYMONAPI_PASSWORD=secret XYMONAPI_PASSWORD_FILE="$work/password" \
	mcp "http://127.0.0.1:$API_PORT" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health","arguments":{}}}' || rc=$?
answer=$(grep '"id":3' "$work/mcp.out") || fail "no answer to the health call: $(tail -n 5 "$work/mcp.err")"
assert_contains 'answered 401' "$answer" "the MCP client sends no password, even one in its environment"
assert_contains 'XYMONAPI_TOKEN_FILE' "$answer" "and says to set the token file"

pass "XYMONAPI_PASSWD lets in only the users and passwords of its htpasswd file, in either format"
