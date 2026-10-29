# xymon-api

A read-only HTTP and JSON interface to a [Xymon](https://github.com/xymon-monitoring/xymon)
server: the status board, its alarms and hosts, the values in its RRD files,
and the graphs drawn from them. It changes nothing in Xymon; it only reads.

It is an add-on. It installs into an existing Xymon server, runs as one of its
`xymonlaunch` tasks, and uses Xymon's own settings from `xymonserver.cfg`.
Xymon itself is unchanged and needs none of it.

The manual page, [`xymonapi.8`](xymonapi.8), is the specification: every
operation, every setting, and how to enable it. The OpenAPI description is
[`openapi.yaml`](openapi.yaml), also served by the API at `/openapi.json`.

## Requirements

- A Xymon server.
- Python 3.10 or later, with the modules in [`requirements.txt`](requirements.txt).
- `rrdtool`, for `/series`.
- Apache's `htpasswd`, only if a password file is used.

## Installing

```sh
make install XYMONHOME=/usr/lib/xymon/server
```

| variable | meaning | default |
|---|---|---|
| `XYMONHOME` | the Xymon server directory, as `xymonserver.cfg` names it | none: required |
| `MANDIR` | where manual pages go | `/usr/share/man` |
| `DESTDIR` | a staging directory put in front of every path, for a package | empty |

| installed file | from |
|---|---|
| `$XYMONHOME/ext/xymonapi/app.py`, `xymon.py`, `openapi.yaml`, `requirements.txt` | the files of the same name |
| `$XYMONHOME/ext/xymonapi/xymonapi.sh`, the launcher | `xymonapi.sh` |
| `$XYMONHOME/etc/tasks.d/xymonapi`, the task, written `DISABLED` | `xymonapi.tasks.DIST`, with `@XYMONHOME@` replaced |
| `$MANDIR/man8/xymonapi.8` | `xymonapi.8` |

Xymon's own install links `$XYMONHOME/ext` and `$XYMONHOME/etc` to wherever
those directories really are, `/etc/xymon` for instance, so the files land
there. The task file is written only when there is none: a later install keeps
the one you enabled. The Python modules are not installed; `pip install -r
requirements.txt` does that, in a virtualenv if the system Python refuses.

The API is installed disabled: how to enable it, where it listens, and how to
require a password are in [`xymonapi.8`](xymonapi.8).

## Tests

The tests start a real `xymond`, so they run against a built Xymon source
tree, and use its test helpers:

```sh
XYMON_SRC=/path/to/built/xymon tests/run.sh
```

A test skips (exit 77) when something it needs is missing, and says what. CI
builds Xymon's `main` and runs them with nothing missing:
[`.github/workflows/test.yml`](.github/workflows/test.yml).

## Licence

GNU General Public License version 2 or, at your option, any later version
(`GPL-2.0-or-later`); the text of version 2 is in [`LICENSE`](LICENSE).
