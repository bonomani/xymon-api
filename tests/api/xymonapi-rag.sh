#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-rag.sh
#
# xymonapi-rag indexes Xymon's own manual pages and, through the API, the
# history of colour changes with the status text saved at each, and finds the
# passage a question is about: how long a problem must last before an alert
# is sent is in alerts.cfg(5) under RULES, a full disk is in analysis.cfg(5),
# and an HTTP 500 on the login page is the red http change of web.example.com.
# Only Xymon's pages are indexed, and .TP items are read whether the item is a
# text line or a macro line. The status text is indexed, marked as sent by a
# monitored host. A failing /histlog fails the indexing; an index searched
# with another model than its own is refused.
# The MCP server's search_history tool finds the same. ask gives the nearest
# passages and the question to a language model that speaks the
# OpenAI-compatible API, with no key unless one is set, and prints its answer.
#
# The pages are three real ones from the Xymon tree in XYMON_SRC; the history
# is written here in xymond_history's format; the language model is
# tests/lib/fake-llm.py. The embedding model is the real one, downloaded on
# first use into FASTEMBED_CACHE_PATH when that is set. Skips where the API,
# the search or the MCP server cannot run. Needs curl.

set -euo pipefail
# shellcheck source=tests/lib/xymonapi.sh
. "$(dirname "$0")/../lib/xymonapi.sh"

ROOT=$(find_root)

require_bin XYMONCLIENT "$XYMON_SRC/common/xymon"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"

work=$(mktempdir)
LLM_PID=""
register_cleanup 'stop_process "$LLM_PID" "$API_PID"'

mkdir -p "$work/docs" "$work/hist" "$work/histlogs/web_example_com/http"
for page in common/hosts.cfg.5 xymond/alerts.cfg.5 xymond/analysis.cfg.5; do
	cp "$XYMON_SRC/$page" "$work/docs/" || fail "no $page in XYMON_SRC"
done
# A page that is not Xymon's, as in /usr/share/man: it must not be indexed.
printf '.TH ZEBRA 1 "2026" "GNU"\n.SH DESCRIPTION\nzebra stripes the zebra crossing\n' > "$work/docs/zebra.1"
# .TP with the item on a macro line, as Xymon's own pages write it.
printf '.TH FROB 8 "2026" "Xymon"\n.SH OPTIONS\n.TP\n.B "--frobnicate"\nmakes every frob blink twice\n' > "$work/docs/frob.8"
cat > "$work/hist/allevents" <<'EOF'
web.example.com http 1699400000 1699300000 100000 red green 0
db.example.com conn 1699400300 1699000000 400000 yellow green 0
EOF
printf 'red Tue Nov  7 23:33:20 2023 HTTP 500 Internal Server Error from https://web.example.com/login\n' \
	> "$work/histlogs/web_example_com/http/Tue_Nov_7_23:33:20_2023"

export TZ=UTC XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:1" \
	XYMONHISTDIR="$work/hist" XYMONHISTLOGS="$work/histlogs"
start_api

unset XYMONAPI_RAG_LLM_KEY XYMONAPI_RAG_MODEL
export XYMONAPI_URL="http://127.0.0.1:$API_PORT" XYMONAPI_RAG_DOCS="$work/docs" \
	XYMONAPI_RAG_INDEX="$work/index.npz" XYMONAPI_RAG_SINCE=1699000000
rag() { "$ROOT/rag/xymonapi-rag.sh" "$@" 2> "$work/rag.err"; }

rc=0
rag index > "$work/index.out" || rc=$?
[ "$rc" -eq 77 ] && skip "$(cat "$work/rag.err")"
[ "$rc" -eq 0 ] || fail "xymonapi-rag index exited with $rc: $(tail -n 5 "$work/rag.err")"
assert_contains "indexed" "$(cat "$work/index.out")" "index says what it did"

# top QUESTION [ARGS] -- the title of the passage nearest QUESTION.
top() {
	local q=$1; shift
	rag search -k 1 "$@" "$q" | grep '"title"' | head -n 1
}
assert_contains 'alerts.cfg.5 -- RULES' "$(top 'how long must a problem last before an alert is sent' --kind docs)" "a question about alert delay"
assert_contains 'analysis.cfg.5 -- DISK' "$(top 'warn when a filesystem is 90 percent full' --kind docs)" "a question about a full disk"
assert_contains 'web.example.com http' "$(top 'HTTP 500 error on the login page' --kind history)" "a question the history answers"
hist=$(rag search -k 1 --kind history 'HTTP 500 error on the login page')
assert_contains 'Internal Server Error' "$hist" "the saved status text is indexed, not only the change"
assert_contains 'not instructions' "$hist" "and marked as text a monitored host sent"
assert_not_contains 'zebra' "$(rag search -k 50 --kind docs 'zebra crossing stripes')" "a page that is not Xymon's is not indexed"
assert_contains 'frob.8 -- OPTIONS -- --frobnicate' "$(top 'make the frobs blink' --kind docs)" ".TP then .B: the macro line is the item"
assert_contains 'makes every frob blink twice' "$(rag search -k 1 --kind docs 'make the frobs blink')" "and the line after it the text"
rc=0
rag search -k 0 'anything' > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "search -k 0 was accepted"
rc=0
XYMONAPI_RAG_MODEL=BAAI/bge-base-en-v1.5 rag search 'anything' > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "a search with another model than the index's succeeded"
assert_contains 'was built with BAAI/bge-small-en-v1.5' "$(cat "$work/rag.err")" "and says which model built the index"

# --kind keeps to one kind even when the other holds a nearer passage.
assert_contains '.example.com' "$(top 'how long must a problem last before an alert is sent' --kind history)" "--kind history returns history"
assert_contains '.cfg.5 -- ' "$(top 'HTTP 500 error on the login page' --kind docs)" "--kind docs returns manual pages"

# The same search, as the MCP server's tool.
rc=0
mcp "$XYMONAPI_URL" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_history","arguments":{"question":"HTTP 500 error on the login page","k":1}}}' || rc=$?
[ "$rc" -eq 77 ] && skip "$(cat "$work/mcp.err")"
answer=$(grep '"id":3' "$work/mcp.out") || fail "no answer to search_history: $(tail -n 5 "$work/mcp.err")"
assert_contains 'web.example.com http' "$answer" "the search_history tool finds the change"
assert_not_contains '"isError":true' "$answer" "and not as an error"

# ask, against a stand-in for the language model.
"${XYMONAPI_PYTHON:-python3}" "$ROOT/tests/lib/fake-llm.py" "$work/llm.port" "$work/llm.req" &
# shellcheck disable=SC2034 # read by the cleanup
LLM_PID=$!
for _ in $(seq 1 50); do [ -s "$work/llm.port" ] && break; sleep 0.1; done
[ -s "$work/llm.port" ] || fail "the stand-in language model did not start"
XYMONAPI_RAG_LLM_URL="http://127.0.0.1:$(cat "$work/llm.port")/v1"
export XYMONAPI_RAG_LLM_URL

out=$(rag ask -k 2 'how long must a problem last before an alert is sent') \
	|| fail "xymonapi-rag ask failed: $(tail -n 5 "$work/rag.err")"
assert_equal "FAKE ANSWER" "$out" "ask prints the model's answer"
req=$(cat "$work/llm.req")
assert_contains 'how long must a problem last before an alert is sent' "$req" "the model is given the question"
assert_contains 'alerts.cfg.5 -- RULES' "$req" "and the passage nearest it"
assert_contains 'Authorization: '$'\n' "$req" "and no key when none is set"

XYMONAPI_RAG_LLM_KEY=secret-key rag ask 'a full disk' > /dev/null || fail "ask with a key failed: $(tail -n 5 "$work/rag.err")"
assert_contains 'Authorization: Bearer secret-key' "$(cat "$work/llm.req")" "a key is sent as a bearer token"

rc=0
XYMONAPI_RAG_LLM_URL="http://127.0.0.1:1/v1" rag ask 'a full disk' > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "ask with no language model succeeded"
assert_contains 'no language model at' "$(cat "$work/rag.err")" "and says why"

# A /histlog that fails for another reason than a missing file -- here an
# API without XYMONHISTLOGS, which answers 502 -- must fail the indexing, not
# build an index without the texts.
stop_process "$API_PID"
API_PID=""
XYMONHISTLOGS="" start_api
export XYMONAPI_URL="http://127.0.0.1:$API_PORT"
rc=0
XYMONAPI_RAG_INDEX="$work/index2.npz" rag index > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "indexing succeeded while every /histlog answered 502"
assert_contains 'cannot read the history' "$(cat "$work/rag.err")" "and says why"
[ -e "$work/index2.npz" ] && fail "a failed indexing left an index behind"

pass "xymonapi-rag finds the manual-page passage and the history a question is about, the MCP tool too, and ask hands them to a language model"
