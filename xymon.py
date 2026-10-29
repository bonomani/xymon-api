"""Read a live Xymon server and map it onto the API's schemas.

The data comes from ``xymondboard``'s structured fields, split on ``|``, with
the colour mapped to a verdict. Status-message bodies are not parsed.

Everything about the server comes from Xymon's own settings, which the
launcher gets from xymonserver.cfg: ``XYMON`` is the xymon client program,
``XYMSRV`` the server to ask, ``XYMONRRDS`` where the RRD files are and
``XYMONSERVERCGIURL`` where showgraph is.
"""
from __future__ import annotations

import base64
import binascii
import json
import os
import re
import subprocess
import time
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urlencode

XYMON = os.environ.get("XYMON", "xymon")
XYMSRV = os.environ.get("XYMSRV", "")
XYMONRRDS = os.environ.get("XYMONRRDS", "")
XYMONSERVERCGIURL = os.environ.get("XYMONSERVERCGIURL", "").rstrip("/")
BOARD_FIELDS = ["hostname", "testname", "color", "lastchange"]

# A name from the request becomes part of a file path and of an rrdtool
# argument, so it may not hold "/" (a path outside XYMONRRDS) or ":" (rrdtool's
# own separator). Host and test names in Xymon never do.
_NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.,-]*")
_DSNAME = re.compile(r"[A-Za-z0-9_]{1,19}")
_RELATIVE = re.compile(r"-([0-9]+)([smhdw])")
_UNIT = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


class BadRequest(ValueError):
    """A request parameter the API will not pass on."""

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


def _name(value: str | None, what: str) -> str:
    if not value or not _NAME.fullmatch(value) or ".." in value:
        raise BadRequest(f"{what} must be a Xymon host or test name")
    return value


def epoch(value: str, now: int | None = None) -> int:
    """'now', seconds since the epoch, or a relative time such as -24h."""
    now = int(time.time()) if now is None else now
    if value == "now":
        return now
    if value.isdigit():
        return int(value)
    m = _RELATIVE.fullmatch(value)
    if m:
        return now - int(m.group(1)) * _UNIT[m.group(2)]
    raise BadRequest(f"time '{value}' must be now, seconds since the epoch, or like -24h")


def series(entity: str | None, test: str | None, metric: str | None,
           frm: str, to: str) -> dict:
    """The values of one dataset of HOST/TEST.rrd over a time range."""
    host, tst = _name(entity, "entity"), _name(test, "test")
    ds = metric or "lambda"
    if not _DSNAME.fullmatch(ds):
        raise BadRequest("metric must be an RRD dataset name")
    start, end = epoch(frm), epoch(to)
    if not XYMONRRDS:
        raise RuntimeError("XYMONRRDS is not set")
    rrd = os.path.join(XYMONRRDS, host, f"{tst}.rrd")
    if not os.path.isfile(rrd):
        raise FileNotFoundError(f"no RRD file for {host} {tst}")
    out = subprocess.run(["rrdtool", "xport", "--json", "--start", str(start),
                          "--end", str(end), f"DEF:v={rrd}:{ds}:AVERAGE",
                          "XPORT:v:v"],
                         capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "rrdtool xport failed")
    doc = json.loads(out.stdout)
    meta = doc.get("meta", {})
    first, step = int(meta.get("start", 0)), int(meta.get("step", 1) or 1)
    points = [{"t": _iso(str(first + i * step)), "v": row[0] if row else None}
              for i, row in enumerate(doc.get("data", []))]
    return {"labels": {"entity": host, "test": tst}, "metric": ds,
            "points": points}


def graph(entity: str | None, test: str | None, frm: str, to: str) -> bytes:
    """The PNG graph showgraph draws for HOST and TEST over a time range."""
    q = urlencode({"host": _name(entity, "entity"), "service": _name(test, "test"),
                   "graph_start": epoch(frm), "graph_end": epoch(to),
                   "action": "view"})
    if not XYMONSERVERCGIURL:
        raise RuntimeError("XYMONSERVERCGIURL is not set")
    with urllib.request.urlopen(f"{XYMONSERVERCGIURL}/showgraph.sh?{q}",
                                timeout=30) as r:
        return r.read()


# --- HTTP Basic authentication -----------------------------------------------
# The users are the web pages' own: the htpasswd file useradm and chpasswd
# keep with Apache's htpasswd. That program checks the password too, so every
# format it writes is understood here without a hashing library: $apr1$ by
# default, bcrypt, SHA. The password goes on its stdin, never its command line.
XYMONAPI_PASSWD = os.environ.get("XYMONAPI_PASSWD", "")
_USER = re.compile(r"[^\s:-][^\s:]*")


def parse_basic(header: str | None) -> tuple[str, str] | None:
    """(user, password) from an Authorization: Basic header, or None."""
    if not header or not header.startswith("Basic "):
        return None
    try:
        user, _, password = base64.b64decode(header[6:], validate=True) \
            .decode("utf-8").partition(":")
    except (binascii.Error, UnicodeDecodeError):
        return None
    return user, password


def verify_basic(user: str, password: str) -> bool:
    """Whether XYMONAPI_PASSWD holds this user with this password."""
    # A user name is an argument to htpasswd, so it may not look like an
    # option; a newline would end the password htpasswd reads.
    if not _USER.fullmatch(user) or "\n" in password or "\r" in password:
        return False
    try:
        out = subprocess.run(["htpasswd", "-v", "-i", XYMONAPI_PASSWD, user],
                             input=password, capture_output=True, text=True,
                             timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return out.returncode == 0
