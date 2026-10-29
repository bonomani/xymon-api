"""HTTP server for the Xymon API.

Only the operations implemented here are registered; any other path answers
404. The OpenAPI document served at /openapi.json is openapi.yaml, beside
this file, so what a client reads is what the server does.

Started by xymonapi.sh, which checks Python and the modules first.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml
from fastapi import FastAPI
from starlette.responses import JSONResponse

import xymon

SPEC_PATH = Path(__file__).resolve().parent / "openapi.yaml"


def _upstream(exc: Exception) -> JSONResponse:
    return JSONResponse({"error": "upstream", "detail": str(exc)}, status_code=502)


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


ROUTES = {
    "/health": _health,
    "/states": _states,
    "/alarms": _alarms,
    "/entities": _entities,
}


def build_app() -> FastAPI:
    if not xymon.XYMSRV:
        sys.exit("xymonapi: XYMSRV is not set; start it from xymonlaunch with "
                 "ENVFILE, or through xymoncmd")
    spec = yaml.safe_load(SPEC_PATH.read_text())
    base = spec["servers"][0]["url"].rstrip("/")
    app = FastAPI(title=spec["info"]["title"], version=spec["info"]["version"])
    for path, handler in ROUTES.items():
        app.add_route(base + path, handler, methods=["GET"])
    app.openapi = lambda: spec                      # type: ignore[assignment]
    return app


app = build_app()
