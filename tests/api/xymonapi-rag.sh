#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/api/xymonapi-rag.sh
#
# xymonapi-rag indexes Xymon's own manual pages and the history of colour
# changes with the status text saved at each -- from xymond's files where
# XYMONHISTDIR names them, as the task on the server has it, with no API, user
# or token, and through the API elsewhere -- and finds the passage a question
# is about: how long a problem must last before an alert
# is sent is in alerts.cfg(5) under RULES, a full disk is in analysis.cfg(5),
# and an HTTP 500 on the login page is the red http change of web.example.com.
# Only Xymon's pages are indexed, and .TP items are read whether the item is a
# text line or a macro line. The status text is indexed, marked as sent by a
# monitored host. A failing /histlog fails the indexing; an index searched
# with another model than its own is refused.
# The API serves the same search at /search from the same index, reloading
# it when the file changes, and /health says what the index holds; the MCP
# server's search_history tool asks the API, and so does a search run where
# there is no index. index keeps the vectors it has and embeds only what is
# new. eval scores the search against a file of questions. ask gives the
# nearest passages and the question to a language model that speaks the
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
web.example.com http 1699400000 1699300000 100000 re gr 0
db.example.com conn 1699400300 1699000000 400000 ye gr 0
EOF
printf 'red Tue Nov  7 23:33:20 2023 HTTP 500 Internal Server Error from https://web.example.com/login\n' \
	> "$work/histlogs/web_example_com/http/Tue_Nov_7_23:33:20_2023"

unset XYMONAPI_RAG_LLM_KEY XYMONAPI_RAG_MODEL
# The API reads the same index file as the indexer writes: both see
# XYMONAPI_RAG_INDEX, as both do from xymonserver.d/ on a server.
export TZ=UTC XYMON="$XYMONCLIENT" XYMSRV="127.0.0.1:1" \
	XYMONHISTDIR="$work/hist" XYMONHISTLOGS="$work/histlogs" \
	XYMONAPI_RAG_DOCS="$work/docs" XYMONAPI_RAG_INDEX="$work/index.npz" XYMONAPI_RAG_SINCE=1699000000
start_api
export XYMONAPI_URL="http://127.0.0.1:$API_PORT"
rag() { "$ROOT/rag/xymonapi-rag.sh" "$@" 2> "$work/rag.err"; }

# Before there is an index: the API says so, and /health says there is none.
assert_equal "404" "$(api_code '/search?q=anything')" "/search with no index"
assert_contains 'search is not set up on this server: no index' "$(api_get '/search?q=anything')" "and says so"
assert_contains '"search":null' "$(api_get /health)" "/health reports no index"

rc=0
rag index > "$work/index.out" || rc=$?
[ "$rc" -eq 77 ] && skip "$(cat "$work/rag.err")"
[ "$rc" -eq 0 ] || fail "xymonapi-rag index exited with $rc: $(tail -n 5 "$work/rag.err")"
assert_match "indexed [0-9]+ passages \([0-9]+ new\)" "$(cat "$work/index.out")" "index says what it did"
first=$(sed -E 's/indexed ([0-9]+) passages \(([0-9]+) new\).*/\1 \2/' "$work/index.out")
assert_equal "${first% *}" "${first#* }" "the first indexing embeds every passage"
# Again, with nothing changed: every vector is kept, none embedded.
rag index > "$work/index.out" || fail "a second index failed: $(tail -n 5 "$work/rag.err")"
assert_contains "(0 new)" "$(cat "$work/index.out")" "a second indexing with nothing new embeds nothing"
# The model is in fastembed's cache now: offline, nothing is downloaded,
# and the search works as before.
XYMONAPI_RAG_OFFLINE=1 rag search -k 1 'anything' > /dev/null \
	|| fail "a search with XYMONAPI_RAG_OFFLINE=1 failed with the model cached: $(tail -n 3 "$work/rag.err")"

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

# The same search, served by the API from the same file.
assert_contains 'alerts.cfg.5 -- RULES' "$(api_get '/search?q=how+long+must+a+problem+last+before+an+alert+is+sent&kind=docs&k=1')" "/search finds the manual-page passage"
assert_contains 'web.example.com http' "$(api_get '/search?q=HTTP+500+error+on+the+login+page&kind=history&k=1')" "/search finds the change"
assert_contains '"score":' "$(api_get '/search?q=HTTP+500+error&k=1')" "with a score"
assert_equal "400" "$(api_code '/search?kind=docs')" "/search without a question"
assert_equal "400" "$(api_code '/search?q=x&kind=zebra')" "/search with a kind that is neither"
assert_equal "400" "$(api_code '/search?q=x&k=0')" "/search with k=0"
assert_equal "400" "$(api_code '/search?q=x&k=21')" "/search with k=21"
health=$(api_get /health)
assert_contains '"search":{' "$health" "/health describes the index"
assert_contains '"docs":' "$health" "how many manual-page passages"
assert_contains '"history":2' "$health" "how many changes"
assert_match '"built":"20[0-9][0-9]-' "$health" "and when it was built"

# A search where there is no index asks the API instead: a laptop needs
# neither fastembed nor the manual pages.
assert_contains 'alerts.cfg.5 -- RULES' "$(XYMONAPI_RAG_INDEX="$work/none.npz" rag search -k 1 --kind docs 'how long must a problem last before an alert is sent' | grep '"title"' | head -n 1)" "search with no index here uses the API's"
rc=0
XYMONAPI_RAG_INDEX="$work/none.npz" XYMONAPI_URL="http://127.0.0.1:1" rag search 'x' > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "a search with no index and no API succeeded"
assert_contains 'no index at' "$(cat "$work/rag.err")" "and with no API either it says so"
assert_contains 'could not search either' "$(cat "$work/rag.err")" "naming both"

# An index here but no numpy to read it -- a laptop with a cache from
# before -- asks the API too. A numpy that will not import stands in.
mkdir -p "$work/nonumpy/numpy"
printf 'raise ImportError("no numpy here", name="numpy")\n' > "$work/nonumpy/numpy/__init__.py"
assert_contains 'alerts.cfg.5 -- RULES' "$(PYTHONPATH="$work/nonumpy" rag search -k 1 --kind docs 'how long must a problem last before an alert is sent' | grep '"title"' | head -n 1)" "search with an index but no numpy uses the API's"
rc=0
PYTHONPATH="$work/nonumpy" rag index > /dev/null || rc=$?
assert_equal "77" "$rc" "index without numpy exits 77"
assert_contains 'missing Python module: numpy' "$(cat "$work/rag.err")" "and names it"

# eval: a file of questions with the title each should find, and a score.
printf '[{"question":"how long must a problem last before an alert is sent","kind":"docs","expect":"alerts.cfg.5 -- RULES"},\n{"question":"HTTP 500 error on the login page","kind":"history","expect":"web.example.com http"},\n{"question":"zebra crossing stripes","kind":"docs","expect":"zebra.1"}]\n' > "$work/eval.json"
rc=0
rag eval --min 3 "$work/eval.json" > "$work/eval.out" || rc=$?
assert_equal "1" "$rc" "eval exits 1 below --min"
assert_contains 'score: 2/3' "$(cat "$work/eval.out")" "and prints the score"
assert_contains 'MISS zebra' "$(cat "$work/eval.out")" "naming the miss"
rag eval --min 2 "$work/eval.json" > /dev/null || fail "eval failed at --min 2: $(cat "$work/rag.err")"

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

# A model the server has not got: Ollama answers 404. The message names the
# model and how to get it.
rc=0
XYMONAPI_RAG_LLM_MODEL=no-such-model rag ask 'a full disk' > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "ask with a model the server has not got succeeded"
assert_contains 'answered 404: it has no model named no-such-model' "$(cat "$work/rag.err")" "a 404 from the model server names the model"
assert_contains 'ollama pull no-such-model' "$(cat "$work/rag.err")" "and says how to pull it"
assert_contains '"max_tokens": 2048' "$(cat "$work/llm.req")" "the model is given a token budget"

# A reasoning model that used its budget on thinking: no answer, only
# reasoning_content. And a model that does not answer in time: a message,
# not a traceback.
rc=0
XYMONAPI_RAG_LLM_MODEL=thinking-model rag ask 'a full disk' > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "ask with an empty answer succeeded"
assert_contains 'thinking-model gave no answer, only reasoning' "$(cat "$work/rag.err")" "an empty answer is explained"
rc=0
XYMONAPI_RAG_LLM_MODEL=slow-model XYMONAPI_RAG_LLM_TIMEOUT=1 rag ask 'a full disk' > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "ask with a model slower than the timeout succeeded"
assert_contains 'gave no answer in 1 seconds (XYMONAPI_RAG_LLM_TIMEOUT)' "$(cat "$work/rag.err")" "a timeout is a message"
assert_not_contains 'Traceback' "$(cat "$work/rag.err")" "and not a traceback"

# A model that redirects: the bearer key must not follow to the host named.
# TARGET records whatever reaches it; REDIRECT answers 302 to TARGET.
"${XYMONAPI_PYTHON:-python3}" "$ROOT/tests/lib/fake-llm.py" "$work/target.port" "$work/target.req" &
TARGET_PID=$!
for _ in $(seq 1 50); do [ -s "$work/target.port" ] && break; sleep 0.1; done
"${XYMONAPI_PYTHON:-python3}" "$ROOT/tests/lib/fake-llm.py" "$work/redirect.port" "$work/redirect.req" \
	"http://127.0.0.1:$(cat "$work/target.port")/v1/chat/completions" &
REDIRECT_PID=$!
register_cleanup 'stop_process "$TARGET_PID" "$REDIRECT_PID"'
for _ in $(seq 1 50); do [ -s "$work/redirect.port" ] && break; sleep 0.1; done
[ -s "$work/redirect.port" ] || fail "the redirecting language model did not start"
rc=0
XYMONAPI_RAG_LLM_URL="http://127.0.0.1:$(cat "$work/redirect.port")/v1" XYMONAPI_RAG_LLM_KEY=secret-key \
	rag ask 'a full disk' > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "ask succeeded against a model that redirected"
assert_contains 'Authorization: Bearer secret-key' "$(cat "$work/redirect.req")" "the model's own address got the key"
assert_contains 'redirect, which is not followed' "$(cat "$work/rag.err")" "a redirect is an error that says so"
[ -e "$work/target.req" ] && fail "the redirect was followed, with: $(head -n 1 "$work/target.req")"

rc=0
XYMONAPI_RAG_LLM_URL="file:///etc/passwd" rag ask 'a full disk' > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "ask with a file:// model URL succeeded"
assert_contains 'must be an http' "$(cat "$work/rag.err")" "a file:// model URL is refused"

# More changes than one /events answers: 1100 more, newer than the two
# above and appended after them as xymond_history would, read in two pages,
# so the oldest change of all is in the index too -- unless
# XYMONAPI_RAG_MAX_HISTORY caps them, which keeps the newest. Indexed into
# the file the API reads: only the 1100 are new, and the API sees them
# without a restart.
awk 'BEGIN { for (i = 1; i <= 1100; i++) printf "many%d.example.com conn %d %d 60 re gr 0\n", i, 1699500000 + i * 10, 1699500000 + i * 10 - 60 }' >> "$work/hist/allevents"
rag index > "$work/index3.out" || fail "indexing 1102 changes failed: $(tail -n 5 "$work/rag.err")"
assert_contains '(1100 new)' "$(cat "$work/index3.out")" "only the new changes are embedded"
assert_contains 'web.example.com http' "$(rag search -k 1 --kind history 'HTTP 500 error on the login page')" "the oldest of 1102 changes is indexed: /events was read page by page"
assert_contains '"history":1102' "$(api_get /health)" "the API reloaded the index the task rewrote"
assert_match 'many[0-9]+\.example\.com conn' "$(api_get '/search?q=many1100.example.com+conn+red&kind=history&k=1')" "and searches it"
XYMONAPI_RAG_INDEX="$work/index4.npz" XYMONAPI_RAG_MAX_HISTORY=50 rag index > /dev/null || fail "indexing with a cap failed: $(tail -n 5 "$work/rag.err")"
assert_not_contains 'web.example.com' "$(XYMONAPI_RAG_INDEX="$work/index4.npz" rag search -k 3 --kind history 'HTTP 500 error on the login page')" "with XYMONAPI_RAG_MAX_HISTORY=50 the oldest is left out"
# Names a digit apart embed much the same, so any of the newest fifty will do.
assert_match 'many1(0[5-9][0-9]|100)\.example\.com conn' "$(XYMONAPI_RAG_INDEX="$work/index4.npz" rag search -k 1 --kind history 'many1100.example.com conn red')" "and the newest kept"

# A saved status that fails to be read for another reason than a missing
# file -- here no XYMONHISTLOGS, which the API answers with 502 -- must fail
# the indexing, not build an index without the texts: from the files, and
# through the API.
rc=0
XYMONHISTLOGS="" XYMONAPI_RAG_INDEX="$work/index2.npz" rag index > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "indexing from the files succeeded with no XYMONHISTLOGS"
assert_contains 'cannot read the history' "$(cat "$work/rag.err")" "and says why"
stop_process "$API_PID"
API_PID=""
XYMONHISTLOGS="" start_api
export XYMONAPI_URL="http://127.0.0.1:$API_PORT"
rc=0
XYMONHISTDIR="" XYMONAPI_RAG_INDEX="$work/index2.npz" rag index > /dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "indexing succeeded while every /histlog answered 502"
assert_contains 'cannot read the history' "$(cat "$work/rag.err")" "and says why"
[ -e "$work/index2.npz" ] && fail "a failed indexing left an index behind"

# On the server the task needs no credential: with XYMONHISTDIR set, as
# xymonserver.cfg sets it, index reads xymond's files and never asks the API,
# which here takes a password nobody gives it. Off the server, without
# XYMONHISTDIR, the same run is the API's 401; with a user and password it
# reads the history through the API. XYMONAPI_HIDE applies to both.
if command -v htpasswd >/dev/null 2>&1; then
	htpasswd -cbB "$work/passwd" alice secret > /dev/null 2>&1 || fail "htpasswd could not write $work/passwd"
	echo 'Internal Server Error' > "$work/hide"
	stop_process "$API_PID"
	API_PID=""
	XYMONAPI_PASSWD="$work/passwd" XYMONAPI_HIDE="$work/hide" start_api
	export XYMONAPI_URL="http://127.0.0.1:$API_PORT"
	unset XYMONAPI_USER XYMONAPI_PASSWORD XYMONAPI_TOKEN XYMONAPI_TOKEN_FILE
	XYMONAPI_HIDE="$work/hide" XYMONAPI_RAG_INDEX="$work/index5.npz" rag index > "$work/index5.out" \
		|| fail "index on the server, with the API asking for a password, failed: $(tail -n 5 "$work/rag.err")"
	assert_match 'indexed [0-9]+ passages' "$(cat "$work/index5.out")" "on the server, index reads the files and needs no user or token"
	hist=$(XYMONAPI_RAG_INDEX="$work/index5.npz" rag search -k 1 --kind history 'HTTP 500 error on the login page')
	assert_contains 'web.example.com http' "$hist" "and the history is in the index"
	assert_contains '[hidden]' "$hist" "with XYMONAPI_HIDE applied as the API applies it"
	assert_not_contains 'Internal Server Error' "$hist" "so the hidden text is not indexed"
	rc=0
	XYMONHISTDIR="" XYMONAPI_RAG_INDEX="$work/index6.npz" rag index > /dev/null || rc=$?
	[ "$rc" -ne 0 ] || fail "off the server, index with no user succeeded against an API that asks for one"
	assert_contains 'answered 401' "$(cat "$work/rag.err")" "off the server, the history comes through the API, which refuses without a user"
	XYMONHISTDIR="" XYMONAPI_USER=alice XYMONAPI_PASSWORD=secret XYMONAPI_RAG_INDEX="$work/index6.npz" rag index > /dev/null \
		|| fail "index through the API with a user failed: $(tail -n 5 "$work/rag.err")"
	assert_contains 'web.example.com http' "$(XYMONAPI_RAG_INDEX="$work/index6.npz" rag search -k 1 --kind history 'HTTP 500 error on the login page')" "and with a user the API gives the history"
else
	echo "htpasswd is not installed: the index-without-credentials part did not run"
fi

pass "xymonapi-rag finds the manual-page passage and the history a question is about, on the server from xymond's files with no credential, the API and the MCP tool serve the same index, index keeps what it has, and ask hands the passages to a language model"
