#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-rag-eval.sh
#
# The search, scored: every manual page of the Xymon tree in XYMON_SRC is
# indexed, and the ten questions of tests/eval/docs.json are asked, each
# naming the page or section a Xymon admin would want. At least eight must
# find it among the first three passages. A change to the chunking, the
# model or the pages then shows as a number, not a feeling; a drop below
# eight fails here before it reaches anyone.
#
# Needs no xymond: the API is not asked (index --no-history). The embedding
# model is the real one. Skips where the search cannot run.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)
work=$(mktempdir)

export XYMONAPI_RAG_DOCS="$XYMON_SRC" XYMONAPI_RAG_INDEX="$work/docs.npz"
rag() { "$ROOT/rag/xymonapi-rag.sh" "$@" 2> "$work/rag.err"; }

rc=0
rag index --no-history > "$work/index.out" || rc=$?
[ "$rc" -eq 77 ] && skip "$(cat "$work/rag.err")"
[ "$rc" -eq 0 ] || fail "indexing the manual pages failed: $(tail -n 5 "$work/rag.err")"
n=$(sed -E 's/indexed ([0-9]+) passages.*/\1/' "$work/index.out")
[ "$n" -gt 1000 ] || fail "only $n passages from the whole tree's manual pages: $(cat "$work/index.out")"

rc=0
rag eval -k 3 --min 8 "$ROOT/tests/eval/docs.json" > "$work/eval.out" || rc=$?
cat "$work/eval.out"
[ "$rc" -eq 0 ] || fail "the search scored below 8/10 on tests/eval/docs.json"

pass "the search finds the right manual page for at least 8 of the 10 questions of tests/eval/docs.json: $(tail -n 1 "$work/eval.out")"
