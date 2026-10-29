# xymon-api

A read-only HTTP and JSON interface to a [Xymon](https://github.com/xymon-monitoring/xymon)
server: the status board, its alarms and hosts, the values in its RRD files,
the graphs drawn from them, and the history of colour changes with the status
text saved at each. It changes nothing in Xymon; it only reads.

It is an add-on. It installs into an existing Xymon server, runs as one of its
`xymonlaunch` tasks, and uses Xymon's own settings from `xymonserver.cfg`.
Xymon itself is unchanged and needs none of it.

The manual page, [`xymonapi.8`](xymonapi.8), is the specification: every
operation, every setting, and how to enable it. The OpenAPI description is
[`openapi.yaml`](openapi.yaml), also served by the API at `/openapi.json`.

## Requirements

- A Xymon server built from Xymon's current `main` branch. The API's settings
  go in `xymonserver.d/`, which no Xymon release reads yet: on 4.3.30 a file
  there is ignored, and with it the password the API should ask for.
- Python 3.10 or later, with the modules in [`requirements.txt`](requirements.txt).
- `rrdtool`, for `/series`.
- A web server running Xymon's CGI programs at `XYMONSERVERCGIURL`, for
  `/graphs`: it asks their `showgraph.sh`.
- Apache's `htpasswd`, only if a password file is used.

## Installing

```sh
make install XYMONHOME=/usr/lib/xymon/server
```

It writes into the Xymon server directory, so it is normally run as root.

| variable | meaning | default |
|---|---|---|
| `XYMONHOME` | the Xymon server directory, as `xymonserver.cfg` names it | no default: it must be given |
| `MANDIR` | where manual pages go | `/usr/share/man` |
| `DESTDIR` | a staging directory put in front of every path, for a package | empty |

| installed file | from |
|---|---|
| `$XYMONHOME/ext/xymonapi/app.py`, `xymon.py`, `openapi.yaml`, `requirements.txt` | the files of the same name |
| `$XYMONHOME/ext/xymonapi/xymonapi.sh`, the launcher | `xymonapi.sh` |
| `$XYMONHOME/etc/tasks.d/xymonapi`, the task, written `DISABLED` | `xymonapi.tasks.DIST`, with `@XYMONHOME@` replaced |
| `$XYMONHOME/ext/xymonapi/rag/`, the search and its launcher, and `mcp-server/client.py` it reads the API with | `rag/xymonrag.py`, `xymonapi-rag.sh`, `requirements.txt`, `mcp-server/client.py` |
| `$XYMONHOME/etc/tasks.d/xymonapi-rag`, the daily index task, written `DISABLED` | `rag/xymonapi-rag.tasks.DIST` |
| `$MANDIR/man8/xymonapi.8`, `$MANDIR/man1/xymonapi-rag.1` | the pages of the same name |

Xymon's own install links `$XYMONHOME/ext` and `$XYMONHOME/etc` to wherever
those directories really are -- `$XYMONHOME/etc` to `/etc/xymon` on many
installations -- so the files land there. The task file is written only when
there is none: a later install keeps the one you enabled.

With `DESTDIR`, the staged `$XYMONHOME/ext` and `$XYMONHOME/etc` are plain
directories, where the server has Xymon's links. A package built from that
stage should check how its tool installs a directory over a link, or put the
files in the directories the links lead to.

The Python modules are not installed. They must be importable by the user
Xymon runs as, not only by root: `pip install --user` run as root puts them
where that user does not look. Install them system-wide, from your
distribution's packages for instance, or in a virtualenv that user can read,
and then name its `python3` in `XYMONAPI_PYTHON`, as `xymonapi.8` says.

The API is installed disabled: how to enable it, where it listens, and how to
require a password are in [`xymonapi.8`](xymonapi.8). Once it runs, with the
default address, this checks it; what each answer means is under `/health` in
the manual page:

```sh
curl http://127.0.0.1:1986/xymon/api/v1/health
```

## Pitfalls seen in practice

From an install on a Homebrew Xymon (`xymon-server-preview`) on macOS, with
Apache on port 8080. Check each against your server:

- **Enabling**: delete the `DISABLED` line from `etc/tasks.d/xymonapi`.
  xymonlaunch picks up the change on its own.
- **Python and rrdtool**: `xymonserver.cfg` sets its own PATH. There, `python3`
  was the system's 3.9 and `rrdtool` was missing, so the task exited 77 and
  `/series` failed. Name a 3.10+ in `XYMONAPI_PYTHON` and append the right
  directory to PATH.
- **Graphs**: `XYMONSERVERCGIURL` is a path, so the API prefixes
  `XYMONWEBHOST`, that is `http://$XYMONSERVERWWWNAME`. Put the port in
  `XYMONSERVERWWWNAME` when the web server is not on 80: `localhost:8080`.
- **Password**: the htpasswd file `xymon-apache.conf` names may not exist
  yet. Create it with `htpasswd -cB FILE USER` and name it in
  `XYMONAPI_PASSWD`. It is read on every request: no restart after a change.
- **Tasks at start-up**: xymonlaunch starts every task within seconds of
  boot, and a task that then exits is not run again until its INTERVAL has
  passed. The index task hit a not-yet-listening API this way, so it `NEEDS
  xymonapi` and the indexer waits a minute for an API that gives no answer.
  Also, editing a file under `tasks.d/` does not make xymonlaunch reload:
  `touch tasks.cfg` does, and a task is restarted only when its definition
  changed, comments aside.
- **Homebrew**: `$XYMONHOME/ext` is inside the Cellar, so `brew upgrade`
  drops `ext/xymonapi`. Run `make install` again. The task file and settings
  under `/opt/homebrew/etc` survive.

The settings file that came out of it, `etc/xymonserver.d/xymonapi.cfg`:

```sh
XYMONAPI_PYTHON="/Users/me/.pyenv/versions/3.12.3/bin/python3"
XYMONAPI_LISTEN="127.0.0.1:1986"
XYMONAPI_PASSWD="/opt/homebrew/opt/xymon-server-preview/server/etc/xymonpasswd"
PATH="$PATH:/opt/homebrew/bin"
```

## MCP server

[`mcp-server/`](mcp-server) gives an AI client that speaks the Model Context
Protocol -- Claude Desktop, Claude Code -- read-only tools over the API:
`health`, `states`, `alarms`, `entities`, `series`, and the two searches of
the next section, `search_docs` and `search_history`. It runs where the client
runs, from this checkout, with the Python module in
[`mcp-server/requirements.txt`](mcp-server/requirements.txt). For Claude Code,
once, at user scope so every project has it:

```sh
claude mcp add --scope user xymon \
  -e XYMONAPI_URL=http://127.0.0.1:1986 \
  -e XYMONAPI_USER=me -e XYMONAPI_PASSWORD=... \
  -e XYMONAPI_PYTHON=/path/to/python3.12 \
  -e XYMONAPI_RAG_DOCS=/usr/share/man \
  -- /path/to/xymon-api/mcp-server/xymonapi-mcp.sh
```

Leave out the user and password when the API asks for none, and
`XYMONAPI_PYTHON` when the system `python3` has the modules. The two searches
answer a tool error until the index below is built.

For an API on another machine, use HTTPS through a web server in front of
it, as `xymonapi.8` says: over plain HTTP, a password crosses the network in
the clear.

Every tool and setting is in
[`mcp-server/xymonapi-mcp.1`](mcp-server/xymonapi-mcp.1).

## Search

[`rag/`](rag) searches Xymon's manual pages and its history by meaning. It
needs the modules in [`rag/requirements.txt`](rag/requirements.txt) and the
same `XYMONAPI_*` variables as above, plus `XYMONAPI_RAG_DOCS`, a directory
with Xymon's manual pages. Build the index, then try it:

```sh
rag/xymonapi-rag.sh index
rag/xymonapi-rag.sh search "what does purple mean"
```

The first run downloads a 65 MB embedding model; indexing takes about a
minute. The index holds the last 30 days of history, so `make install` also
writes a daily xymonlaunch task, `tasks.d/xymonapi-rag`, DISABLED: remove the
line, and put the variables above in a file under `xymonserver.d/`. `ask` hands the passages to a
language model speaking the OpenAI-compatible API, a local Ollama by default;
with Claude, the MCP tools are the simpler way. Every command and setting is
in [`rag/xymonapi-rag.1`](rag/xymonapi-rag.1).

## Tests

The tests run against a server build of Xymon's current `main`: two of them
start its `xymond`, and all of them use its test helpers, which no release
has. `XYMON_SRC` names that tree, and is required: without it every test fails
at once.

```sh
XYMON_SRC=/path/to/built/xymon tests/run.sh
```

They need `bash`, `curl`, and the Python modules of all three
`requirements.txt` -- the API's, `mcp-server/`'s and `rag/`'s -- for `python3`,
or the Python `XYMONAPI_PYTHON` names; some also need `rrdtool` or Apache's
`htpasswd`. The search test downloads the embedding model, about 65 MB, the
first time. A test skips (exit 77) when something it needs is missing, and says
what. CI builds Xymon's `main` and runs them with nothing missing:
[`.github/workflows/test.yml`](.github/workflows/test.yml).

## Licence

GNU General Public License version 2 or, at your option, any later version
(`GPL-2.0-or-later`); the text of version 2 is in [`LICENSE`](LICENSE).
