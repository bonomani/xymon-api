# SPDX-License-Identifier: GPL-2.0-or-later
"""A client for xymonapi(8), with nothing but the standard library: the MCP
server and the search in rag/ both read the API through it.

XYMONAPI_URL is where the API is, http://127.0.0.1:1986 by default.
XYMONAPI_USER and XYMONAPI_PASSWORD are sent when the API asks for a user.
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


class APIError(RuntimeError):
    """The API could not be reached, or refused the request; the text says which."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # urllib follows a redirect with every header but the content ones, so the
    # Authorization header would go to whatever host a redirect names. The
    # API never redirects; a redirect is answered as the error it is.
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def api(path: str, **params: str | None) -> dict:
    """GET PATH under /xymon/api/v1 and return the JSON it answers."""
    # http and https only: urllib also reads file:// and ftp:// URLs.
    if urlsplit(URL).scheme not in ("http", "https"):
        raise APIError(f"XYMONAPI_URL must be an http:// or https:// URL, not {URL!r}")
    query = urlencode({k: v for k, v in params.items() if v})
    try:
        req = urllib.request.Request(f"{URL}/xymon/api/v1{path}" + (f"?{query}" if query else ""))
        if USER:
            token = base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
            req.add_header("Authorization", f"Basic {token}")
        with _opener.open(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        # The API's own explanation, not a bare status.
        raise APIError(f"xymonapi answered {e.code}: {e.read().decode(errors='replace')}") from e
    except urllib.error.URLError as e:
        raise APIError(f"cannot reach xymonapi at {URL}: {e.reason}") from e
    except ValueError as e:              # a URL urllib cannot use, or an answer that is not JSON
        raise APIError(f"xymonapi at {URL}: {e}") from e
    except OSError as e:                 # the connection broke, or timed out, while reading
        raise APIError(f"xymonapi at {URL}: {e}") from e
