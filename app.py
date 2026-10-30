# SPDX-License-Identifier: GPL-2.0-or-later
"""HTTP server for the Xymon API.

Only the operations implemented here are registered; any other path answers
404. The OpenAPI document served at /openapi.json is openapi.yaml, beside
this file, so what a client reads is what the server does.

Started by xymonapi.sh, which checks Python and the modules first.
"""
from __future__ import annotations

import logging
import os
import shutil
import sys
from pathlib import Path

import yaml
from fastapi import FastAPI
from starlette.concurrency import run_in_threadpool
from starlette.responses import JSONResponse, Response

import clientsetup
import tokens
import xymon

# To stderr, which the task's LOGFILE collects: $XYMONSERVERLOGS/xymonapi.log.
logging.basicConfig(stream=sys.stderr, level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("xymonapi")

SPEC_PATH = Path(__file__).resolve().parent / "openapi.yaml"
RAG_DIR = Path(__file__).resolve().parent / "rag"


def _rag():
    """rag/xymonrag.py, imported when first needed: /search and the search
    part of /health use it, the other operations do not, and its modules
    (fastembed, numpy) are not required unless the search is used."""
    if str(RAG_DIR) not in sys.path:
        sys.path.insert(0, str(RAG_DIR))
    import xymonrag
    return xymonrag


def _upstream(exc: Exception) -> JSONResponse:
    """502. xymon.Upstream carries a text of this program's own; anything
    else -- a program's stderr, a traceback -- names paths and settings a
    stranger need not see, so it goes to the log and the answer says where."""
    if isinstance(exc, xymon.Upstream):
        return JSONResponse({"error": "upstream", "detail": str(exc)}, status_code=502)
    log.error("%s: %s", type(exc).__name__, exc)
    return JSONResponse({"error": "upstream",
                         "detail": "the server could not answer; the reason is in xymonapi.log"},
                        status_code=502)


def _refused(exc: Exception) -> JSONResponse:
    """The answer for an exception: 400, 404 or 502."""
    if isinstance(exc, xymon.BadRequest):
        return JSONResponse({"error": "bad_request", "detail": str(exc)}, status_code=400)
    if isinstance(exc, xymon.NotFound):
        return JSONResponse({"error": "not_found", "detail": str(exc)}, status_code=404)
    return _upstream(exc)


# The handlers are plain functions, not coroutines: Starlette runs them in
# its thread pool, so a slow xymond, rrdtool or showgraph holds up that one
# request and not the event loop -- /health keeps answering meanwhile.
def _health(request):
    out: dict = {"alive": False, "search": _search_info()}
    try:
        version = xymon.ping()
    except Exception as exc:                        # noqa: BLE001
        log.warning("ping: %s: %s", type(exc).__name__, exc)
        return JSONResponse(out)
    out.update(alive=True, server_version=version)
    return JSONResponse(out)


def _search_info():
    """The index /search reads, for /health: its size and age, or null when
    there is none -- or no numpy to read it with, which the log says."""
    try:
        return _rag().index_info()
    except Exception as exc:                        # noqa: BLE001
        log.warning("search index: %s: %s", type(exc).__name__, exc)
        return None


def _search(request):
    q = request.query_params
    question, kind, k = (q.get("q") or "").strip(), q.get("kind"), q.get("k", "5")
    if not question:
        return JSONResponse({"error": "bad_request", "detail": "q, the question, is needed"},
                            status_code=400)
    if kind is not None and kind not in ("docs", "history"):
        return JSONResponse({"error": "bad_request", "detail": "kind must be docs or history"},
                            status_code=400)
    if not k.isdigit() or not 1 <= int(k) <= 20:
        return JSONResponse({"error": "bad_request", "detail": "k must be 1 to 20"},
                            status_code=400)
    try:
        rag = _rag()
    except ImportError as exc:
        return JSONResponse({"error": "not_found", "detail": "search is not set up on this "
                             "server: the Python modules in rag/requirements.txt are missing "
                             f"({exc.name})"}, status_code=404)
    try:
        # remote=False: this is the server; with no index it says so rather
        # than asking itself.
        items = rag.search(question[:2000], kind, int(k), remote=False)
    except rag.IndexProblem as exc:
        return JSONResponse({"error": "not_found", "detail": f"search is not set up on this "
                             f"server: {exc}; enable the xymonapi-rag task"}, status_code=404)
    except Exception as exc:                        # noqa: BLE001
        return _upstream(exc)
    return JSONResponse({"items": items})


def _states(request):
    q = request.query_params
    try:
        items = xymon.states(q.get("entity"), q.get("test"), q.get("verdict"))
    except Exception as exc:                        # noqa: BLE001
        return _upstream(exc)
    return JSONResponse({"items": items})


def _alarms(request):
    try:
        items = xymon.alarms()
    except Exception as exc:                        # noqa: BLE001
        return _upstream(exc)
    return JSONResponse({"items": items})


def _entities(request):
    try:
        items = xymon.entities()
    except Exception as exc:                        # noqa: BLE001
        return _upstream(exc)
    return JSONResponse({"items": items})


def _status(request):
    q = request.query_params
    try:
        s = xymon.status(q.get("entity"), q.get("test"))
    except Exception as exc:                        # noqa: BLE001
        return _refused(exc)
    return JSONResponse(s)


def _series(request):
    q = request.query_params
    try:
        s = xymon.series(q.get("entity"), q.get("test"), q.get("metric"),
                         q.get("from", "-24h"), q.get("to", "now"))
    except Exception as exc:                        # noqa: BLE001
        return _refused(exc)
    return JSONResponse({"series": [s]})


def _graphs(request):
    q = request.query_params
    try:
        png = xymon.graph(q.get("entity"), q.get("test"),
                          q.get("from", "-24h"), q.get("to", "now"))
    except Exception as exc:                        # noqa: BLE001
        return _refused(exc)
    return Response(content=png, media_type="image/png")


def _events(request):
    q = request.query_params
    try:
        items = xymon.events(q.get("entity"), q.get("test"), q.get("since"), q.get("limit"),
                             q.get("before"))
    except Exception as exc:                        # noqa: BLE001
        return _refused(exc)
    return JSONResponse({"items": items})


def _histlog(request):
    q = request.query_params
    try:
        log = xymon.histlog(q.get("entity"), q.get("test"), q.get("time"))
    except Exception as exc:                        # noqa: BLE001
        return _refused(exc)
    return JSONResponse(log)


def _client(request):
    """A setup script for the machine that asked: the API's own address and
    the user who asked, so a laptop is set up with no name retyped."""
    q = request.query_params
    fmt = q.get("format", "sh")
    if fmt not in ("sh", "env"):
        return JSONResponse({"error": "bad_request", "detail": "format must be sh or env"},
                            status_code=400)
    try:
        name = clientsetup.valid_name(q.get("name"))
    except ValueError as exc:
        return JSONResponse({"error": "bad_request", "detail": str(exc)}, status_code=400)
    user = getattr(request.state, "user", "")
    url = clientsetup.public_url(request.headers, str(request.url))
    text = clientsetup.render(url, user, name, fmt)
    media = "text/x-shellscript" if fmt == "sh" else "text/plain"
    return Response(content=text, media_type=f"{media}; charset=utf-8",
                    headers={"Content-Disposition": f'inline; filename="{name}-setup.{fmt}"'})


def _no_users() -> JSONResponse | None:
    if xymon.XYMONAPI_PASSWD:
        return None
    return JSONResponse({"error": "bad_request", "detail": "tokens are for the users of "
                         "XYMONAPI_PASSWD, and this API asks for no password"}, status_code=400)


async def _tokens(request):
    """GET: the caller's tokens. POST {"client": NAME}: a new token for the
    caller on that machine, replacing any it had, shown this once."""
    refused = _no_users()
    if refused:
        return refused
    user = request.state.user
    if request.method == "GET":
        return JSONResponse({"items": await run_in_threadpool(tokens.listing, user)})
    try:
        body = await request.json()
        client = tokens.valid_client(body.get("client") if isinstance(body, dict) else None)
    except ValueError as exc:
        return JSONResponse({"error": "bad_request", "detail": str(exc)}, status_code=400)
    try:
        token = await run_in_threadpool(tokens.issue, user, client)
    except OSError as exc:
        return _upstream(RuntimeError(f"cannot write {tokens.TOKENS_FILE}: {exc.strerror}"))
    log.info("token issued to %s@%s", user, client)
    return JSONResponse({"user": user, "client": client, "token": token}, status_code=201)


async def _token(request):
    """DELETE: revoke the caller's token on one machine."""
    refused = _no_users()
    if refused:
        return refused
    user, client = request.state.user, request.path_params["client"]
    try:
        gone = await run_in_threadpool(tokens.revoke, user, client)
    except ValueError as exc:
        return JSONResponse({"error": "bad_request", "detail": str(exc)}, status_code=400)
    except OSError as exc:
        return _upstream(RuntimeError(f"cannot write {tokens.TOKENS_FILE}: {exc.strerror}"))
    if not gone:
        return JSONResponse({"error": "not_found", "detail": f"{user} has no token on {client}"},
                            status_code=404)
    log.info("token of %s@%s revoked", user, client)
    return Response(status_code=204)


ROUTES = {
    "/health": _health,
    "/states": _states,
    "/alarms": _alarms,
    "/entities": _entities,
    "/status": _status,
    "/series": _series,
    "/graphs": _graphs,
    "/events": _events,
    "/histlog": _histlog,
    "/search": _search,
    "/client": _client,
}


def build_app() -> FastAPI:
    if not xymon.XYMSRV:
        sys.exit("xymonapi: XYMSRV is not set; start it from xymonlaunch with "
                 "ENVFILE, or through xymoncmd")
    spec = yaml.safe_load(SPEC_PATH.read_text())
    base = spec["servers"][0]["url"].rstrip("/")
    app = FastAPI(title=spec["info"]["title"], version=spec["info"]["version"])

    try:
        n = xymon.load_hide()
    except OSError as exc:
        sys.exit(f"xymonapi: cannot read XYMONAPI_HIDE={xymon.HIDE_FILE}: {exc.strerror}")
    except ValueError as exc:
        sys.exit(f"xymonapi: XYMONAPI_HIDE: {exc} is not a regular expression")
    if n:
        log.info("hiding what %d expression(s) of %s match", n, xymon.HIDE_FILE)

    if xymon.XYMONAPI_PASSWD:
        # Refuse to start rather than answer 401 to everyone, which looks
        # like a wrong password when it is a wrong setting.
        if not os.access(xymon.XYMONAPI_PASSWD, os.R_OK):
            sys.exit(f"xymonapi: cannot read XYMONAPI_PASSWD={xymon.XYMONAPI_PASSWD}")
        if shutil.which("htpasswd") is None:
            sys.exit("xymonapi: XYMONAPI_PASSWD is set, and checking it needs "
                     "Apache's htpasswd, which is not on PATH")

        # Every path, not only the API's: FastAPI also serves /openapi.json
        # and its /docs pages, and with a password set nothing is answered
        # to a stranger.
        def refuse(detail: str) -> JSONResponse:
            return JSONResponse({"error": "unauthorized", "detail": detail}, status_code=401,
                                headers={"WWW-Authenticate": 'Basic realm="xymon"'})

        @app.middleware("http")
        async def _auth(request, call_next):
            header = request.headers.get("authorization") or ""
            if header.startswith("Bearer "):
                # A token opens every path but the token operations: it may
                # not make or list tokens, or a stolen one would renew itself.
                if request.url.path.startswith(base + "/tokens"):
                    return refuse("tokens are managed with the user's password, not a token")
                who = await run_in_threadpool(tokens.check, header[7:].strip())
                if not who:
                    return refuse("this token is not valid, or was revoked")
                request.state.user, request.state.client = who
                log.info("%s@%s %s %s", who[0], who[1], request.method, request.url.path)
                return await call_next(request)
            creds = xymon.parse_basic(header)
            # htpasswd checks a bcrypt hash in tens of milliseconds: off the loop.
            if not creds or not await run_in_threadpool(xymon.verify_basic, *creds):
                return refuse("a user and password, or a client token, are needed")
            request.state.user, request.state.client = creds[0], None
            return await call_next(request)

    for path, handler in ROUTES.items():
        app.add_route(base + path, handler, methods=["GET"])
    app.add_route(base + "/tokens", _tokens, methods=["GET", "POST"])
    app.add_route(base + "/tokens/{client}", _token, methods=["DELETE"])
    app.openapi = lambda: spec                      # type: ignore[assignment]
    return app


app = build_app()
