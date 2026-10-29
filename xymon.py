"""Read a live Xymon server and map it onto the API's schemas.

The data comes from ``xymondboard``'s structured fields, split on ``|``, with
the colour mapped to a verdict. Status-message bodies are not parsed.

Everything about the server comes from Xymon's own settings, which the
launcher gets from xymonserver.cfg: ``XYMON`` is the xymon client program and
``XYMSRV`` the server to ask.
"""
from __future__ import annotations

import os
import subprocess
from datetime import datetime, timezone

XYMON = os.environ.get("XYMON", "xymon")
XYMSRV = os.environ.get("XYMSRV", "")
BOARD_FIELDS = ["hostname", "testname", "color", "lastchange"]

# A verdict, never a colour: the colour is how the web pages show it.
COLOUR_STATUS = {"green": "ok", "yellow": "warning", "red": "critical",
                 "blue": "disabled", "clear": "nodata", "purple": "unknown"}
COLOUR_SEVERITY = {"red": "major", "purple": "critical", "yellow": "minor"}


def query(request: str) -> str:
    """Send one request to xymond and return its answer."""
    out = subprocess.run([XYMON, XYMSRV, request],
                         capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"xymon {XYMSRV} failed")
    return out.stdout


def ping() -> str:
    """xymond's answer to a ping: its name and version."""
    return query("ping").strip()


def _rows() -> list[dict]:
    board = query(f"xymondboard fields={','.join(BOARD_FIELDS)}")
    return [dict(zip(BOARD_FIELDS, line.split("|")))
            for line in board.splitlines() if line.strip()]


def _iso(epoch: str) -> str | None:
    try:
        return datetime.fromtimestamp(int(epoch), timezone.utc) \
            .isoformat().replace("+00:00", "Z")
    except (ValueError, TypeError, OSError, OverflowError):
        return None


def states(entity: str | None = None, test: str | None = None,
           verdict: str | None = None) -> list[dict]:
    """One State per host and test on the board."""
    out: list[dict] = []
    for d in _rows():
        host, tst = d.get("hostname", "?"), d.get("testname", "?")
        st = {"id": f"{host}:{tst}", "entity": host, "test": tst,
              "verdict": COLOUR_STATUS.get(d.get("color", "clear"), "unknown")}
        t = _iso(d.get("lastchange", ""))
        if t:
            st["time"] = t
        out.append(st)
    if entity:
        out = [s for s in out if s["entity"] == entity]
    if test:
        out = [s for s in out if s["test"] == test]
    if verdict:
        out = [s for s in out if s["verdict"] == verdict]
    return out


def alarms() -> list[dict]:
    """Every state that is not ok, as an Alarm."""
    res: list[dict] = []
    for d in _rows():
        colour = d.get("color", "clear")
        if COLOUR_STATUS.get(colour, "unknown") == "ok":
            continue
        host, tst = d.get("hostname", "?"), d.get("testname", "?")
        a = {"id": f"{host}:{tst}", "entity": host, "test": tst,
             "severity": COLOUR_SEVERITY.get(colour, "minor"), "status": "firing"}
        t = _iso(d.get("lastchange", ""))
        if t:
            a["since"] = t
        res.append(a)
    return res


def entities() -> list[dict]:
    """Each host on the board, once."""
    seen: dict[str, dict] = {}
    for d in _rows():
        host = d.get("hostname", "?")
        seen.setdefault(host, {"id": host, "composition": "measured",
                               "labels": {"role": "host"}})
    return list(seen.values())
