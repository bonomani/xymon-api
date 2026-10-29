"""HTTP server for the Xymon API.

Only the operations implemented here are registered; any other path answers
404. The OpenAPI document served at /openapi.json is openapi.yaml, beside
this file, so what a client reads is what the server does.

Started by xymonapi.sh, which checks Python and the modules first.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

import yaml
from fastapi import FastAPI
from starlette.responses import JSONResponse, Response

import xymon

SPEC_PATH = Path(__file__).resolve().parent / "openapi.yaml"


def _upstream(exc: Exception) -> JSONResponse:
    return JSONResponse({"error": "upstream", "detail": str(exc)}, status_code=502)


def _refused(exc: Exception) -> JSONResponse:
    """The answer for an exception: 400, 404 or 502."""
    if isinstance(exc, xymon.BadRequest):
        return JSONResponse({"error": "bad_request", "detail": str(exc)}, status_code=400)
    if isinstance(exc, FileNotFoundError):
        return JSONResponse({"error": "not_found", "detail": str(exc)}, status_code=404)
    return _upstream(exc)


async def _health(request):
    try:
        version = xymon.ping()
    except Exception:                               # noqa: BLE001
        return JSONResponse({"alive": False})
    return JSONResponse({"alive": True, "server_version": version})


async def _states(request):
    q = request.query_params
    try:
        items = xymon.states(q.get("entity"), q.get("test"), q.get("verdict"))
    except Exception as exc:                        # noqa: BLE001
        return _upstream(exc)
    return JSONResponse({"items": items})


async def _alarms(request):
    try:
        items = xymon.alarms()
    except Exception as exc:                        # noqa: BLE001
        return _upstream(exc)
    return JSONResponse({"items": items})


async def _entities(request):
    try:
        items = xymon.entities()
    except Exception as exc:                        # noqa: BLE001
        return _upstream(exc)
    return JSONResponse({"items": items})


async def _series(request):
    q = request.query_params
    try:
        s = xymon.series(q.get("entity"), q.get("test"), q.get("metric"),
                         q.get("from", "-24h"), q.get("to", "now"))
    except Exception as exc:                        # noqa: BLE001
        return _refused(exc)
    return JSONResponse({"series": [s]})


async def _graphs(request):
    q = request.query_params
    try:
        png = xymon.graph(q.get("entity"), q.get("test"),
                          q.get("from", "-24h"), q.get("to", "now"))
    except Exception as exc:                        # noqa: BLE001
        return _refused(exc)
    return Response(content=png, media_type="image/png")


# The handlers call xymon, rrdtool and htpasswd and wait for them, so the
# server answers one request at a time. That is enough for a read-only API on
# the Xymon server itself; run them with starlette's run_in_threadpool if it
# is ever not.
ROUTES = {
    "/health": _health,
    "/states": _states,
    "/alarms": _alarms,
    "/entities": _entities,
    "/series": _series,
    "/graphs": _graphs,
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

        @app.middleware("http")
        async def _basic_auth(request, call_next):
            if request.url.path.startswith(base + "/"):
                creds = xymon.parse_basic(request.headers.get("authorization"))
                if not creds or not xymon.verify_basic(*creds):
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
