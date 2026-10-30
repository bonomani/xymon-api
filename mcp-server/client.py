# SPDX-License-Identifier: GPL-2.0-or-later
"""A client for xymonapi(8), with nothing but the standard library: the MCP
server and the search in rag/ both read the API through it.

XYMONAPI_URL is where the API is, http://127.0.0.1:1986 by default.
XYMONAPI_USER and XYMONAPI_PASSWORD are sent when the API asks for a user;
XYMONAPI_PASSWORD_FILE names a file holding the password instead, for an
environment that other programs read too, as xymonserver.cfg's is.
"""
from __future__ import annotations

import base64
import json
import os
import urllib.error
import urllib.request
from urllib.parse import urlencode, urlsplit

URL = os.environ.get("XYMONAPI_URL", "http://127.0.0.1:1986").rstrip("/")
USER = os.environ.get("XYMONAPI_USER", "")
PASSWORD = os.environ.get("XYMONAPI_PASSWORD", "")
PASSWORD_FILE = os.environ.get("XYMONAPI_PASSWORD_FILE", "")


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


_opener = urllib.request.build_opener(_NoRedirect)
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
        if USER:
            token = base64.b64encode(f"{USER}:{_password()}".encode()).decode()
            req.add_header("Authorization", f"Basic {token}")
        with _opener.open(req, timeout=30) as r:
            body = r.read(MAX_BODY + 1)
        if len(body) > MAX_BODY:
            raise APIError(f"xymonapi at {URL} answered more than {MAX_BODY} bytes")
        return json.loads(body)
    except urllib.error.HTTPError as e:
        # The API's own explanation, not a bare status.
        raise APIError(f"xymonapi answered {e.code}: {e.read().decode(errors='replace')}",
                       e.code) from e
    except urllib.error.URLError as e:
        raise APIError(f"cannot reach xymonapi at {URL}: {e.reason}") from e
    except ValueError as e:              # a URL urllib cannot use, or an answer that is not JSON
        raise APIError(f"xymonapi at {URL}: {e}") from e
    except OSError as e:                 # the connection broke, or timed out, while reading
        raise APIError(f"xymonapi at {URL}: {e}") from e
