# SPDX-License-Identifier: GPL-2.0-or-later
"""A client for xymonapi(8), with nothing but the standard library: the MCP
server and the search in rag/ both read the API through it.

XYMONAPI_URL is where the API is, http://127.0.0.1:1986 by default.
XYMONAPI_USER and XYMONAPI_PASSWORD are sent when the API asks for a user;
XYMONAPI_PASSWORD_FILE names a file holding the password instead, for an
environment that other programs read too, as xymonserver.cfg's is.
XYMONAPI_TOKEN_FILE names a file holding a client token instead -- what the
setup script /client writes keeps -- and is used before a user and password:
the token is this machine's own, revoked on its own (xymonapi(8), TOKENS).
XYMONAPI_TOKEN is the token itself, for a test or a one-off.
XYMONAPI_CA names the certificate, or the CA, to trust for an https:// URL
when it is not one the system trusts already: xymond's own, from
xymon-tls(7), which the API uses too.
"""
from __future__ import annotations

import base64
import json
import os
import ssl
import urllib.error
import urllib.request
from urllib.parse import urlencode, urlsplit

URL = os.environ.get("XYMONAPI_URL", "http://127.0.0.1:1986").rstrip("/")
USER = os.environ.get("XYMONAPI_USER", "")
PASSWORD = os.environ.get("XYMONAPI_PASSWORD", "")
PASSWORD_FILE = os.environ.get("XYMONAPI_PASSWORD_FILE", "")
CA = os.environ.get("XYMONAPI_CA", "")
TOKEN = os.environ.get("XYMONAPI_TOKEN", "")
TOKEN_FILE = os.environ.get("XYMONAPI_TOKEN_FILE", "")


def _token() -> str:
    """XYMONAPI_TOKEN, or the first line of XYMONAPI_TOKEN_FILE, or ""."""
    if TOKEN or not TOKEN_FILE:
        return TOKEN
    try:
        with open(TOKEN_FILE, encoding="utf-8") as fd:
            return fd.readline().strip()
    except OSError as e:
        raise APIError(f"cannot read XYMONAPI_TOKEN_FILE={TOKEN_FILE}: {e.strerror}") from e


def _password() -> str:
    """XYMONAPI_PASSWORD, or the first line of XYMONAPI_PASSWORD_FILE."""
    if PASSWORD or not PASSWORD_FILE:
        return PASSWORD
    try:
        with open(PASSWORD_FILE, encoding="utf-8") as fd:
            return fd.readline().rstrip("\r\n")
    except OSError as e:
        raise APIError(f"cannot read XYMONAPI_PASSWORD_FILE={PASSWORD_FILE}: {e.strerror}") from e


class APIError(RuntimeError):
    """The API could not be reached, or refused the request; the text says which.
    status is the HTTP status of a refusal, None when there was no answer."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # urllib follows a redirect with every header but the content ones, so the
    # Authorization header would go to whatever host a redirect names. The
    # API never redirects; a redirect is answered as the error it is.
    def redirect_request(self, *args, **kwargs):
        return None


def _context() -> ssl.SSLContext:
    """Full verification, against XYMONAPI_CA when set, the system's store
    otherwise. Never less: the password rides on this connection."""
    ctx = ssl.create_default_context()
    if CA:
        try:
            ctx.load_verify_locations(CA)
        except (OSError, ssl.SSLError) as e:
            raise APIError(f"cannot use XYMONAPI_CA={CA}: {e}") from e
    return ctx


_opener: urllib.request.OpenerDirector | None = None


def open_url(req, timeout: float):
    """urlopen through the opener above: no redirect, full verification. The
    opener is built on the first call, not when the module is imported, so
    that a wrong XYMONAPI_CA is an APIError each tool and command reports,
    rather than a crash before the MCP server has answered anything."""
    global _opener
    if _opener is None:
        _opener = urllib.request.build_opener(
            _NoRedirect, urllib.request.HTTPSHandler(context=_context()))
    return _opener.open(req, timeout=timeout)
# An answer of the API is a board or a list of events: never near this.
MAX_BODY = 16 * 1024 * 1024


def api(path: str, **params: str | None) -> dict:
    """GET PATH under /xymon/api/v1 and return the JSON it answers."""
    # http and https only: urllib also reads file:// and ftp:// URLs.
    if urlsplit(URL).scheme not in ("http", "https"):
        raise APIError(f"XYMONAPI_URL must be an http:// or https:// URL, not {URL!r}")
    # Left out when not given; "0" is a value.
    query = urlencode({k: v for k, v in params.items() if v is not None and v != ""})
    try:
        req = urllib.request.Request(f"{URL}/xymon/api/v1{path}" + (f"?{query}" if query else ""))
        bearer = _token()
        if bearer:
            req.add_header("Authorization", f"Bearer {bearer}")
        elif USER:
            token = base64.b64encode(f"{USER}:{_password()}".encode()).decode()
            req.add_header("Authorization", f"Basic {token}")
        with open_url(req, 30) as r:
            body = r.read(MAX_BODY + 1)
        if len(body) > MAX_BODY:
            raise APIError(f"xymonapi at {URL} answered more than {MAX_BODY} bytes")
        return json.loads(body)
    except urllib.error.HTTPError as e:
        # The API's own explanation, not a bare status; and for the two
        # failures of a first setup, what to check.
        detail = e.read().decode(errors="replace")
        if e.code == 401:
            detail += (" -- the token in XYMONAPI_TOKEN_FILE was revoked or replaced: run the "
                       "setup script from /client again" if (TOKEN or TOKEN_FILE) else
                       " -- XYMONAPI_USER and XYMONAPI_PASSWORD_FILE (or XYMONAPI_PASSWORD) must "
                       "name a user of the API's htpasswd file" if USER else
                       " -- set XYMONAPI_TOKEN_FILE, or XYMONAPI_USER and XYMONAPI_PASSWORD_FILE")
        raise APIError(f"xymonapi answered {e.code}: {detail}", e.code) from e
    except urllib.error.URLError as e:
        if isinstance(e.reason, ssl.SSLCertVerificationError):
            raise APIError(f"xymonapi at {URL} has a certificate this machine does not trust: "
                           f"{e.reason.verify_message} -- name the server's certificate, or the "
                           "CA that signed it, in XYMONAPI_CA") from e
        raise APIError(f"cannot reach xymonapi at {URL}: {e.reason} -- is the API running, and "
                       "XYMONAPI_URL right? From another machine it is reached over HTTPS, "
                       "as xymonapi(8) says") from e
    except ValueError as e:              # a URL urllib cannot use, or an answer that is not JSON
        raise APIError(f"xymonapi at {URL}: {e}") from e
    except OSError as e:                 # the connection broke, or timed out, while reading
        raise APIError(f"xymonapi at {URL}: {e}") from e
