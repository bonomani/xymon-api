#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-install.sh
#
# make install puts the API in $XYMONHOME/ext/xymonapi/, its manual page in
# man8/, and its task in $XYMONHOME/etc/tasks.d/xymonapi -- disabled, with
# ENVFILE naming that server's xymonserver.cfg. An install over one where the
# admin enabled the task leaves that file alone: putting DISABLED back would
# stop the API at the next upgrade, with nothing to say why. Without
# XYMONHOME it installs nothing and says so. The Apache snippet goes to
# $XYMONHOME/etc, kept too once there. make install-client puts the MCP
# server and the search commands under PREFIX, with two commands in bin
# that run them from there.
#
# Installed into a scratch directory. No Python is needed: the API is copied,
# not run. Uses the test helpers of the Xymon tree in XYMON_SRC.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)
work=$(mktempdir)
home=$work/server
make=${MAKE:-make}

rc=0
"$make" -C "$ROOT" install MANDIR="$work/man" >"$work/nohome.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "make install without XYMONHOME succeeded"
assert_contains "XYMONHOME" "$(cat "$work/nohome.log")" "and it says what is missing"
[ -e "$work/man" ] && fail "make install without XYMONHOME installed something"

# Under a umask that would leave a new file readable by its owner alone: the
# task file must still be 644, like the others, whoever xymonlaunch runs as.
( umask 077 && "$make" -C "$ROOT" install XYMONHOME="$home" MANDIR="$work/man" ) >"$work/install.log" 2>&1 \
	|| fail "make install failed: $(tail -n 5 "$work/install.log")"

for f in app.py xymon.py openapi.yaml requirements.txt xymonapi.sh; do
	assert_file_exists "$home/ext/xymonapi/$f"
done
[ -x "$home/ext/xymonapi/xymonapi.sh" ] || fail "the launcher is not executable"
assert_file_exists "$work/man/man8/xymonapi.8"

task=$home/etc/tasks.d/xymonapi
assert_file_exists "$task"
grep -q '^[[:space:]]*DISABLED$' "$task" || fail "the task is not shipped DISABLED: $(cat "$task")"
grep -q "^[[:space:]]*ENVFILE $home/etc/xymonserver.cfg\$" "$task" \
	|| fail "ENVFILE does not name this server's xymonserver.cfg: $(grep ENVFILE "$task")"
grep -q '@XYMONHOME@' "$task" && fail "@XYMONHOME@ was left unreplaced in $task"
mode=$(ls -l "$task" | cut -c1-10)
assert_equal "-rw-r--r--" "$mode" "the task file's mode under umask 077"

# The admin enables the API, and the next install must not undo it.
grep -v '^[[:space:]]*DISABLED$' "$task" > "$work/enabled"
cp "$work/enabled" "$task"
"$make" -C "$ROOT" install XYMONHOME="$home" MANDIR="$work/man" >"$work/reinstall.log" 2>&1 \
	|| fail "installing a second time failed: $(tail -n 5 "$work/reinstall.log")"
cmp -s "$work/enabled" "$task" \
	|| fail "a second install changed the task file the admin had enabled: $(cat "$task")"

# A server directory with a space, an & and a | in its name: the paths are
# quoted, and the replacement sed makes in the task files is escaped.
odd="$work/x y&z|w"
"$make" -C "$ROOT" install XYMONHOME="$odd" MANDIR="$work/man 2" >"$work/odd.log" 2>&1 \
	|| fail "make install into a directory with a space, & and | failed: $(tail -n 5 "$work/odd.log")"
assert_file_exists "$odd/ext/xymonapi/xymonapi.sh"
assert_file_exists "$work/man 2/man8/xymonapi.8"
grep -qF "ENVFILE $odd/etc/xymonserver.cfg" "$odd/etc/tasks.d/xymonapi" \
	|| fail "the task file does not name that directory as it is: $(grep ENVFILE "$odd/etc/tasks.d/xymonapi")"
grep -qF "ENVFILE $odd/etc/xymonserver.cfg" "$odd/etc/tasks.d/xymonapi-rag" \
	|| fail "the index task file does not name that directory as it is: $(grep ENVFILE "$odd/etc/tasks.d/xymonapi-rag")"

assert_file_exists "$home/etc/xymonapi-apache.conf"
grep -q 'ProxyPass ' "$home/etc/xymonapi-apache.conf" || fail "the Apache snippet has no ProxyPass"
echo "# mine" > "$home/etc/xymonapi-apache.conf"
"$make" -C "$ROOT" install XYMONHOME="$home" MANDIR="$work/man" >/dev/null 2>&1 || fail "a third install failed"
assert_equal "# mine" "$(cat "$home/etc/xymonapi-apache.conf")" "an edited Apache snippet is kept"

# The client side: no Xymon here, PREFIX with a space in its name.
prefix="$work/client prefix"
"$make" -C "$ROOT" install-client PREFIX="$prefix" >"$work/client.log" 2>&1 \
	|| fail "make install-client failed: $(tail -n 5 "$work/client.log")"
for f in mcp-server/server.py mcp-server/client.py mcp-server/xymonapi-mcp.sh mcp-server/requirements.txt \
         rag/xymonrag.py rag/xymonapi-rag.sh rag/requirements.txt; do
	assert_file_exists "$prefix/libexec/xymonapi/$f"
done
assert_file_exists "$prefix/share/man/man1/xymonapi-mcp.1"
assert_file_exists "$prefix/share/man/man1/xymonapi-rag.1"
[ -x "$prefix/bin/xymonapi-mcp" ] || fail "bin/xymonapi-mcp is not executable"
[ -x "$prefix/bin/xymonapi-rag" ] || fail "bin/xymonapi-rag is not executable"
grep -qF "\"$prefix/libexec/xymonapi/rag/xymonapi-rag.sh\"" "$prefix/bin/xymonapi-rag" \
	|| fail "bin/xymonapi-rag does not run the installed launcher, quoted: $(cat "$prefix/bin/xymonapi-rag")"
[ -e "$prefix/libexec/xymonapi/app.py" ] && fail "install-client installed the API"
# The installed xymonapi-rag runs: --help needs Python alone, and finds
# client.py beside rag/ as in the repository.
if command -v "${XYMONAPI_PYTHON:-python3}" >/dev/null 2>&1; then
	XYMONAPI_PYTHON="${XYMONAPI_PYTHON:-python3}" "$prefix/bin/xymonapi-rag" --help > "$work/help.out" 2>&1 \
		|| fail "the installed xymonapi-rag --help failed: $(cat "$work/help.out")"
	assert_contains 'search' "$(cat "$work/help.out")" "and names its commands"
fi

pass "make install puts the API in ext/xymonapi/ with disabled tasks and the Apache snippet, keeps what the admin edited, takes odd directory names, and install-client lays out the client side"
