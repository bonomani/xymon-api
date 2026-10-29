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
| `$MANDIR/man8/xymonapi.8` | `xymonapi.8` |

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

## A worked install: Xymon from Homebrew on macOS

What one real install needed, as a checklist for yours. Xymon came from
the `xymon-server-preview` Homebrew formula (a build of `main`), running as
the login user, with Homebrew's Apache on port 8080.

```sh
make install XYMONHOME=/opt/homebrew/opt/xymon-server-preview/server MANDIR=/opt/homebrew/share/man
```

- **Enable it**: delete the `DISABLED` line from `etc/tasks.d/xymonapi`.
  xymonlaunch notices the change by itself and starts the task.
- **Python**: `xymonserver.cfg` sets a PATH of its own, on which `python3`
  was Apple's 3.9, so the task exited 77. Name a 3.10+ with the modules in
  `XYMONAPI_PYTHON` -- here a pyenv interpreter, where `pip install -r
  requirements.txt` had put them.
- **rrdtool**: Homebrew's `/opt/homebrew/bin` was not on that PATH either,
  so `/series` could not run it. Append it.
- **Graphs**: `XYMONSERVERCGIURL` is a path, and the API prefixes
  `XYMONWEBHOST` to reach it. That is `http://$XYMONSERVERWWWNAME`, which
  must carry the port when the web server is not on 80:
  `XYMONSERVERWWWNAME="localhost:8080"` in `xymonserver.cfg`.
- **Password**: `xymon-apache.conf` already named the htpasswd file to use,
  `$XYMONHOME/etc/xymonpasswd`; it did not exist until `htpasswd -cB`
  created it. The API reads it on every request, so a password change needs
  no restart.

The settings file, `etc/xymonserver.d/xymonapi.cfg`, ended up as:

```sh
XYMONAPI_PYTHON="/Users/me/.pyenv/versions/3.12.3/bin/python3"
XYMONAPI_LISTEN="127.0.0.1:1986"
XYMONAPI_PASSWD="/opt/homebrew/opt/xymon-server-preview/server/etc/xymonpasswd"
PATH="$PATH:/opt/homebrew/bin"
```

Mind that `$XYMONHOME/ext` is inside the Homebrew Cellar there, so
`brew upgrade` of the formula drops `ext/xymonapi`: run `make install`
again after one. The task file and the settings live under `/opt/homebrew/etc`
and survive.

For the MCP server below, the same Python needs `mcp-server/requirements.txt`
and, for the two searches, `rag/requirements.txt`. Register it once, at user
scope so every project has it, with the credentials and the man page
directory the index reads:

```sh
claude mcp add --scope user xymon \
  -e XYMONAPI_URL=http://127.0.0.1:1986 \
  -e XYMONAPI_USER=me -e XYMONAPI_PASSWORD=... \
  -e XYMONAPI_PYTHON=/Users/me/.pyenv/versions/3.12.3/bin/python3 \
  -e XYMONAPI_RAG_DOCS=/opt/homebrew/opt/xymon-server-preview/share/man \
  -- /path/to/xymon-api/mcp-server/xymonapi-mcp.sh
```

Then build the index with the same variables in the environment:
`rag/xymonapi-rag.sh index` read 1874 passages from the man pages and
30 days of history in about a minute, after a one-time 65 MB model download.
Rerun it now and then: the history part is only as fresh as the last run.

## MCP server

[`mcp-server/`](mcp-server) gives an AI client that speaks the Model Context
Protocol -- Claude Desktop, Claude Code -- read-only tools over the API:
`health`, `states`, `alarms`, `entities`, `series`, and the two searches
below, `search_docs` and `search_history`. It runs where the client
runs, from this checkout, and needs the Python module in
[`mcp-server/requirements.txt`](mcp-server/requirements.txt); the two
searches also need those in [`rag/requirements.txt`](rag/requirements.txt)
and an index built by `rag/xymonapi-rag.sh index`, and answer a tool error
until then. For Claude Code:

```sh
claude mcp add xymon -e XYMONAPI_URL=https://xymon.example.com/ -- /path/to/xymon-api/mcp-server/xymonapi-mcp.sh
```

For an API on another machine, use HTTPS through a web server in front of
it, as `xymonapi.8` says: over plain HTTP, a password crosses the network in
the clear.

Every tool and setting is in
[`mcp-server/xymonapi-mcp.1`](mcp-server/xymonapi-mcp.1).

## Search

[`rag/`](rag) searches Xymon's manual pages, read from the directory
`XYMONAPI_RAG_DOCS` names, and its history through the API, by meaning:
`xymonapi-rag.sh index` builds the index, `search` returns the
passages nearest a question, and `ask` hands them to a language model that
speaks the OpenAI-compatible API -- a local Ollama by default, so no key and no
cost. The embeddings are computed on this machine. With a Claude subscription,
the MCP tools above are the simpler way: Claude reads the passages and writes
the answer. Every command and setting is in
[`rag/xymonapi-rag.1`](rag/xymonapi-rag.1).

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
