# SPDX-License-Identifier: GPL-2.0-or-later
"""Client tokens: one per user and machine, instead of a password on every
laptop. xymonapi(8), TOKENS.

A user who gives the password asks for a token for a machine, named by its
short hostname; the token is shown once, and only its SHA-256 is kept, in
$XYMONAPI_TOKENS ($XYMONVAR/xymonapi/tokens by default), one JSON line per
token. A second token for the same user and machine replaces the first, so
each machine holds one credential, revoked on its own. Deleting a line
revokes that token: that is how an admin revokes anyone's. The first token
seen whose user is no longer in XYMONAPI_PASSWD has all that user's lines
deleted (revoke_user), so removing the user is enough, and a person given
the same name later starts with no machines.
"""
from __future__ import annotations

import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import tempfile
import time

_DEFAULT = os.path.join(os.environ.get("XYMONVAR", "/nonexistent"), "xymonapi", "tokens")
TOKENS_FILE = os.environ.get("XYMONAPI_TOKENS", _DEFAULT)
PREFIX = "xat_"
_CLIENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")
_TOKEN = re.compile(PREFIX + r"[A-Za-z0-9_-]{43}")

# The file is read again only when it changes: a request does not pay for it.
_cache: tuple[float, int, list[dict]] | None = None


def valid_client(name: str | None) -> str:
    """A machine's name: letters, digits, . _ or -, 64 at most, as the setup
    script makes it from the short hostname."""
    if not name or not _CLIENT.fullmatch(name):
        raise ValueError("client must be letters, digits, . _ or -, 64 at most")
    return name


def _digest(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _read() -> list[dict]:
    global _cache
    try:
        st = os.stat(TOKENS_FILE)
    except FileNotFoundError:
        return []
    if _cache and _cache[:2] == (st.st_mtime, st.st_size):
        return _cache[2]
    entries = []
    with open(TOKENS_FILE, encoding="utf-8") as fd:
        for line in fd:
            try:
                e = json.loads(line)
            except ValueError:
                continue                 # an admin's half-edited line: not a token
            if isinstance(e, dict) and {"user", "client", "sha256"} <= e.keys():
                entries.append(e)
    _cache = (st.st_mtime, st.st_size, entries)
    return entries


def _write(entries: list[dict]) -> None:
    """Write the file anew, mode 600, renamed into place: a reader sees the
    old file or the new one, never half of either."""
    global _cache
    d = os.path.dirname(TOKENS_FILE)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tokens.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            for e in entries:
                f.write(json.dumps(e, sort_keys=True) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, TOKENS_FILE)
    except BaseException:
        os.unlink(tmp)
        raise
    _cache = None


class _Lock:
    """One writer at a time: two machines asking at once must not lose one."""

    def __enter__(self):
        os.makedirs(os.path.dirname(TOKENS_FILE), mode=0o700, exist_ok=True)
        self.fd = os.open(TOKENS_FILE + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def issue(user: str, client: str) -> str:
    """A new token for USER on CLIENT, replacing any it had; returned once."""
    client = valid_client(client)
    token = PREFIX + secrets.token_urlsafe(32)
    with _Lock():
        kept = [e for e in _read() if not (e["user"] == user and e["client"] == client)]
        kept.append({"user": user, "client": client, "sha256": _digest(token),
                     "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        _write(kept)
    return token


def check(token: str) -> tuple[str, str] | None:
    """(user, client) the token was issued to, or None."""
    if not _TOKEN.fullmatch(token):
        return None
    digest = _digest(token)
    found = None
    for e in _read():
        # Every line compared, in constant time each: how long a check takes
        # says nothing of which line, if any, matched.
        if hmac.compare_digest(e["sha256"], digest):
            found = (e["user"], e["client"])
    return found


def listing(user: str) -> list[dict]:
    """USER's tokens, without the digests: which machines, since when."""
    return [{"client": e["client"], "created": e.get("created")}
            for e in _read() if e["user"] == user]


def revoke_user(user: str) -> int:
    """Revoke every token of USER; how many there were."""
    with _Lock():
        entries = _read()
        kept = [e for e in entries if e["user"] != user]
        if len(kept) != len(entries):
            _write(kept)
    return len(entries) - len(kept)


def revoke(user: str, client: str) -> bool:
    """Revoke USER's token on CLIENT; False when there was none."""
    client = valid_client(client)
    with _Lock():
        entries = _read()
        kept = [e for e in entries if not (e["user"] == user and e["client"] == client)]
        if len(kept) == len(entries):
            return False
        _write(kept)
    return True
