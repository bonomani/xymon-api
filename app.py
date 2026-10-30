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

import xymon

# To stderr, which the task's LOGFILE collects: $XYMONSERVERLOGS/xymonapi.log.
logging.basicConfig(stream=sys.stderr, level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("xymonapi")

SPEC_PATH = Path(__file__).resolve().parent / "openapi.yaml"


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
    try:
        version = xymon.ping()
    except Exception as exc:                        # noqa: BLE001
        log.warning("ping: %s: %s", type(exc).__name__, exc)
        return JSONResponse({"alive": False})
    return JSONResponse({"alive": True, "server_version": version})


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
        items = xymon.events(q.get("entity"), q.get("test"), q.get("since"), q.get("limit"))
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


ROUTES = {
    "/health": _health,
    "/states": _states,
    "/alarms": _alarms,
    "/entities": _entities,
    "/series": _series,
    "/graphs": _graphs,
    "/events": _events,
    "/histlog": _histlog,
}


def build_app() -> FastAPI:
    if not xymon.XYMSRV:
        sys.exit("xymonapi: XYMSRV is not set; start it from xymonlaunch with "
                 "ENVFILE, or through xymoncmd")
    spec = yaml.safe_load(SPEC_PATH.read_text())
    base = spec["servers"][0]["url"].rstrip("/")
    app = FastAPI(title=spec["info"]["title"], version=spec["info"]["version"])

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
        @app.middleware("http")
        async def _basic_auth(request, call_next):
            creds = xymon.parse_basic(request.headers.get("authorization"))
            # htpasswd checks a bcrypt hash in tens of milliseconds: off the loop.
            if not creds or not await run_in_threadpool(xymon.verify_basic, *creds):
                return JSONResponse(
                    {"error": "unauthorized", "detail": "a user and password are needed"},
                    status_code=401,
                    headers={"WWW-Authenticate": 'Basic realm="xymon"'})
            return await call_next(request)

    for path, handler in ROUTES.items():
        app.add_route(base + path, handler, methods=["GET"])
    app.openapi = lambda: spec                      # type: ignore[assignment]
    return app


app = build_app()
