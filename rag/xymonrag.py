# SPDX-License-Identifier: GPL-2.0-or-later
"""Search Xymon's manual pages and its history by meaning: xymonapi-rag(1).

index   reads the manual pages under XYMONAPI_RAG_DOCS and, through the API,
        the colour changes and the status text saved at each; cuts them into
        passages; and stores one vector per passage in XYMONAPI_RAG_INDEX.
search  returns the passages nearest a question.
ask     gives those passages to a language model that speaks the
        OpenAI-compatible API -- a local Ollama by default, so no key and no
        cost -- and prints its answer.

The vectors come from a small embedding model run locally by fastembed:
nothing leaves the machine to index or to search. The index is a numpy
file: a few thousand passages need no vector database.
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "mcp-server"))

MODEL = os.environ.get("XYMONAPI_RAG_MODEL", "BAAI/bge-small-en-v1.5")
INDEX = Path(os.environ.get("XYMONAPI_RAG_INDEX",
                            Path.home() / ".cache" / "xymonapi-rag" / "index.npz"))
DOCS = os.environ.get("XYMONAPI_RAG_DOCS", "")
SINCE = os.environ.get("XYMONAPI_RAG_SINCE", "-30d")
LLM_URL = os.environ.get("XYMONAPI_RAG_LLM_URL", "http://127.0.0.1:11434/v1").rstrip("/")
LLM_MODEL = os.environ.get("XYMONAPI_RAG_LLM_MODEL", "llama3.1")
LLM_KEY = os.environ.get("XYMONAPI_RAG_LLM_KEY", "")
PASSAGE = 1200          # characters: one manual-page item or one saved status
HISTLOG_TEXT = 2000     # characters of a saved status that are indexed

_embedder = None


def embed(texts: list[str]):
    """One unit vector per text, from the local embedding model."""
    global _embedder
    import numpy as np
    from fastembed import TextEmbedding
    if _embedder is None:
        _embedder = TextEmbedding(MODEL)
    return np.array(list(_embedder.embed(texts)), dtype="float32")


# --- Manual pages ----------------------------------------------------------------
_ESCAPES = [(re.compile(r"\\f[BIRP]"), ""), (re.compile(r"\\-"), "-"),
            (re.compile(r'\\\(.{2}'), ""), (re.compile(r"\\&"), ""),
            (re.compile(r"\\e"), lambda m: "\\")]


def _plain(line: str) -> str:
    for rx, to in _ESCAPES:
        line = rx.sub(to, line)
    return line.strip().strip('"')


def manpage_passages(path: Path) -> list[dict]:
    """A man(7) page as passages: one per section, and one per item (.IP, .TP)
    in it, each titled with the page, the section and the item."""
    raw = path.read_bytes()
    if path.suffix == ".gz":
        raw = gzip.decompress(raw)
    page = path.name.removesuffix(".gz")
    out: list[dict] = []
    section, item, body = "", "", []

    def flush():
        text = " ".join(t for t in body if t).strip()
        if text:
            title = " -- ".join(t for t in (page, section, item) if t)
            for i in range(0, len(text), PASSAGE):
                out.append({"kind": "docs", "title": title, "text": text[i:i + PASSAGE]})
        body.clear()

    tp = False
    for line in raw.decode("utf-8", errors="replace").splitlines():
        if line.startswith((".SH", ".SS")):
            flush(); section, item = _plain(line[3:]), ""
        elif line.startswith(".IP"):
            flush(); item = _plain(line[3:])
        elif line.startswith(".TP"):
            flush(); tp = True
        elif line.startswith(("." , "'")):
            m = re.match(r"\.(?:B|I|BR|BI|IB|IR|RB|RI)\s+(.*)", line)
            if m:
                body.append(_plain(m.group(1)))
        elif tp:
            item, tp = _plain(line), False
        else:
            body.append(_plain(line))
    flush()
    return out


def docs_passages(root: str) -> list[dict]:
    pages = sorted(p for p in Path(root).rglob("*")
                   if re.search(r"\.[1578](\.gz)?$", p.name) and p.is_file())
    return [psg for p in pages for psg in manpage_passages(p)]


# --- History, through the API -------------------------------------------------------
def history_passages(since: str) -> list[dict]:
    """One passage per colour change since SINCE, with the status text saved
    at it, read through xymonapi(8)."""
    import client                        # mcp-server/client.py
    out = []
    for ev in client.api("/events", since=since, limit="1000")["items"]:
        try:
            log = client.api("/histlog", entity=ev["entity"], test=ev["test"],
                             time=str(ev["epoch"]))["text"][:HISTLOG_TEXT]
        except client.APIError:          # no status was saved for this change
            log = ""
        head = (f'{ev["entity"]} {ev["test"]} at {ev["time"]}: '
                f'{ev["previous"]} to {ev["verdict"]}')
        out.append({"kind": "history", "title": head, "text": f"{head}. {log}".strip(),
                    "entity": ev["entity"], "test": ev["test"], "epoch": ev["epoch"]})
    return out


# --- The index ----------------------------------------------------------------------
def build(docs: str, since: str | None) -> int:
    import numpy as np
    passages = (docs_passages(docs) if docs else []) + \
               (history_passages(since) if since else [])
    if not passages:
        raise SystemExit("xymonapi-rag: nothing to index: set XYMONAPI_RAG_DOCS, "
                         "or let it read the history through the API")
    vectors = embed([f'{p["title"]}\n{p["text"]}' for p in passages])
    INDEX.parent.mkdir(parents=True, exist_ok=True)
    tmp = INDEX.with_name(INDEX.name + ".new.npz")
    np.savez(tmp, vectors=vectors, passages=np.array(json.dumps(passages)))
    os.replace(tmp, INDEX)               # a search never reads a half-written index
    return len(passages)


def search(question: str, kind: str | None = None, k: int = 5) -> list[dict]:
    """The K passages nearest QUESTION, of one KIND (docs, history) or both."""
    import numpy as np
    if not INDEX.is_file():
        raise FileNotFoundError(f"no index at {INDEX}: run xymonapi-rag index first")
    with np.load(INDEX) as z:
        vectors, passages = z["vectors"], json.loads(str(z["passages"]))
    keep = [i for i, p in enumerate(passages) if kind is None or p["kind"] == kind]
    if not keep:
        return []
    scores = vectors[keep] @ embed([question])[0]
    best = np.argsort(-scores)[:k]
    return [dict(passages[keep[i]], score=round(float(scores[i]), 3)) for i in best]


def ask(question: str, k: int = 5) -> str:
    """An answer to QUESTION from the language model, given the passages
    nearest it."""
    found = search(question, None, k)
    context = "\n\n".join(f'[{p["kind"]}: {p["title"]}]\n{p["text"]}' for p in found)
    body = json.dumps({"model": LLM_MODEL, "messages": [
        {"role": "system", "content":
         "You answer questions about a Xymon monitoring server, from the passages "
         "of its manual pages and its history given with the question. Say so when "
         "they do not hold the answer."},
        {"role": "user", "content": f"{context}\n\nQuestion: {question}"}]}).encode()
    req = urllib.request.Request(f"{LLM_URL}/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    if LLM_KEY:
        req.add_header("Authorization", f"Bearer {LLM_KEY}")
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return json.load(r)["choices"][0]["message"]["content"]
    except urllib.error.URLError as e:
        raise SystemExit(f"xymonapi-rag: no language model at {LLM_URL}: {e}") from e


def main() -> None:
    ap = argparse.ArgumentParser(prog="xymonapi-rag", description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    ix = sub.add_parser("index", help="rebuild the index")
    ix.add_argument("--no-history", action="store_true", help="index the manual pages only")
    se = sub.add_parser("search", help="print the passages nearest a question")
    se.add_argument("--kind", choices=["docs", "history"])
    se.add_argument("-k", type=int, default=5)
    se.add_argument("question")
    ak = sub.add_parser("ask", help="answer a question with a language model")
    ak.add_argument("-k", type=int, default=5)
    ak.add_argument("question")
    a = ap.parse_args()
    if a.cmd == "index":
        print(f"indexed {build(DOCS, None if a.no_history else SINCE)} passages in {INDEX}")
    elif a.cmd == "search":
        json.dump(search(a.question, a.kind, a.k), sys.stdout, indent=1)
        print()
    else:
        print(ask(a.question, a.k))


if __name__ == "__main__":
    main()
