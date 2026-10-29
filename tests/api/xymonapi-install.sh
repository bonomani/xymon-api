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
# XYMONHOME it installs nothing and says so.
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

pass "make install puts the API in ext/xymonapi/ with a disabled task, and a reinstall keeps an enabled one"
