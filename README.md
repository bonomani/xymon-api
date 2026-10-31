# xymon-api

A read-only HTTP and JSON interface to a [Xymon](https://github.com/xymon-monitoring/xymon)
server: the status board, its alarms and hosts, the values in its RRD files,
the graphs drawn from them, and the history of colour changes with the status
text saved at each. It changes nothing in Xymon; it only reads.

It is an add-on. It installs into an existing Xymon server, runs as one of its
`xymonlaunch` tasks, and uses Xymon's own settings from `xymonserver.cfg`.
Xymon itself is unchanged and needs none of it.

Its operations, under `/xymon/api/v1` and all GET but for `/tokens`:
`/health`, `/states`, `/alarms`, `/entities`, `/status` (one test's current
status, text and acknowledgement included), `/series` (the values of one RRD
dataset), `/graphs` (the PNG showgraph draws), `/events` (the colour changes,
newest first, a page at a time), `/histlog` (the status text saved at one),
`/search` (the manual-page and history passages nearest a question, by
meaning), `/client` (a setup script for a laptop, this API's address filled
in) and `/tokens` (a machine's own token, listed, made and revoked with your
password). The manual page, [`xymonapi.8`](xymonapi.8), is the
specification: every operation, every setting, and how to enable it. The
OpenAPI description is [`openapi.yaml`](openapi.yaml), also served by the
API at `/openapi.json`.

Two more pieces run where you are, not on the server: an [MCP server](#mcp-server)
that gives Claude the same operations as tools, and a [search](#search)
command line. A laptop needs only those, installed with `make install-client`.

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
| `$XYMONHOME/ext/xymonapi/app.py`, `xymon.py`, `clientsetup.py`, `tokens.py`, `openapi.yaml`, `requirements.txt` | the files of the same name |
| `$XYMONHOME/ext/xymonapi/xymonapi.sh`, the launcher | `xymonapi.sh` |
| `$XYMONHOME/etc/tasks.d/xymonapi`, the task, written `DISABLED` | `xymonapi.tasks.DIST`, with `@XYMONHOME@` replaced |
| `$XYMONHOME/ext/xymonapi/rag/`, the search and its launcher, and `mcp-server/client.py` it reads the API with | `rag/xymonrag.py`, `xymonapi-rag.sh`, `requirements.txt`, `mcp-server/client.py` |
| `$XYMONHOME/etc/tasks.d/xymonapi-rag`, the daily index task, written `DISABLED` | `rag/xymonapi-rag.tasks.DIST` |
| `$XYMONHOME/etc/xymonapi-{apache,nginx,lighttpd}.conf`, the web server snippets, written once | the files of the same name |
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

### On a laptop

Nothing of the above: `git`, `curl`, and Python 3.10 or later with its
`venv` module, which Debian and Ubuntu package apart, as `python3-venv`.
Ask the API for its setup script, read it, run it:

```sh
curl -u me https://xymon.example.ch/xymon/api/v1/client > xymon-setup.sh
sh xymon-setup.sh
```

Where the certificate is the server's own, xymond's, and not one this
machine trusts, copy it first to where the script will look for it, and
name it to curl. Never `-k`: a script fetched without checking the
certificate could be anyone's, and running it runs that code.

```sh
mkdir -p ~/.config/xymon-api
scp xymon.example.ch:/etc/xymon/tls/xymond.pem ~/.config/xymon-api/xymon-ca.pem
curl --cacert ~/.config/xymon-api/xymon-ca.pem -u me \
  https://xymon.example.ch/xymon/api/v1/client > xymon-setup.sh
sh xymon-setup.sh
```

It carries the API's address and your user name, and never the password.
The address is `XYMONAPI_PUBLIC_URL` when the server sets it, else the one
the request came through, from its `Host` header, which the script says in
its first lines: set `XYMONAPI_PUBLIC_URL` on any server other machines
reach, so that the script carries the address you mean and not the one a
request happened to use.
It clones this repository at the commit the server was installed from, so
both sides run the same code, runs `make install-client`, makes a virtualenv
with the `mcp` module, checks it reaches the API and trusts its certificate
-- and stops, saying where to put the certificate, before asking for anything
when it does not -- asks for your password once to get **this machine a
token of its own**, named by its short hostname, keeps the token in
`~/.config/xymon-api/xymon.token` and not the password, checks `/health`
answers, and registers the MCP server with Claude Code. The API's `/tokens`
lists your machines and revokes one (`xymonapi.8`, TOKENS); running the
script again keeps a token that still works and replaces one that does
not. `?name=xymon-lab` gives a second server its own name and token file;
`?format=env` gives the two settings alone.

By hand, `make install-client` from a clone puts `xymonapi-mcp` and
`xymonapi-rag` in `$PREFIX/bin` (`~/.local` by default) and the code under
`$PREFIX/libexec/xymonapi`; `xymonapi-rag search` and `ask` need no module
beyond Python, since they use the server's index through the API. The API
must be reachable from the laptop first: see
[Reaching the API from elsewhere](#reaching-the-api-from-elsewhere).

## Settings

All of them are environment variables. The API's go in a file under
`xymonserver.d/`; the client's and the search's go there too for the index
task, and in the MCP registration for Claude. Every one is described in the
manual page named.

| setting | meaning | default |
|---|---|---|
| `XYMONAPI_LISTEN` | where the API listens, HOST:PORT | `127.0.0.1:1986` |
| `XYMONAPI_PASSWD` | an htpasswd file; every request needs a user from it; empty for none | Xymon's `etc/xymonpasswd` when it exists |
| `XYMONAPI_TLS_CERT`, `_KEY` | a certificate and key; with them the API speaks HTTPS | xymond's `etc/tls/xymond.pem` and `.key` when they exist |
| `XYMONAPI_PUBLIC_URL` | the address `/client` writes; set it on a server other machines reach | the address the request came through |
| `XYMONAPI_TOKENS` | the file of client tokens' SHA-256s | `$XYMONVAR/xymonapi/tokens` |
| `XYMONAPI_HIDE` | a file of regular expressions; what they match is `[hidden]` in every text returned | none |
| `XYMONAPI_PYTHON` | the Python 3.10+ to run with | `python3` on PATH |
| `XYMONAPI_URL` | where the API is, for the MCP server and the search | `http://127.0.0.1:1986` |
| `XYMONAPI_TOKEN_FILE`, `XYMONAPI_TOKEN` | this machine's client token, from the first line of this file, or itself; sent before a user and password | none |
| `XYMONAPI_USER`, `XYMONAPI_PASSWORD` | the user and password they send | none |
| `XYMONAPI_PASSWORD_FILE` | the password from the first line of this file instead | none |
| `XYMONAPI_CA` | the certificate, or CA, to trust for an https:// API the system does not trust already | the system's store |
| `XYMONAPI_RAG_DOCS` | a directory of manual pages to index | none |
| `XYMONAPI_RAG_INDEX` | the index file | `~/.cache/xymonapi-rag/index.npz` |
| `XYMONAPI_RAG_SINCE` | how far back the history is indexed | `-30d` |
| `XYMONAPI_RAG_MAX_HISTORY` | how many changes at most, the newest first | `5000` |
| `XYMONAPI_RAG_MODEL` | the embedding model | `BAAI/bge-small-en-v1.5` |
| `XYMONAPI_RAG_OFFLINE` | set, the model is never downloaded, only read from the cache | unset |
| `XYMONAPI_RAG_LLM_URL`, `_MODEL`, `_KEY` | the language model `ask` uses: any OpenAI-compatible server, Ollama or LM Studio | a local Ollama, `llama3.1`, no key |
| `XYMONAPI_RAG_LLM_MAX_TOKENS`, `_TIMEOUT` | the model's token budget, and how long `ask` waits | `2048`, `300` seconds |

The first seven are `xymonapi.8`'s; the next five `xymonapi-mcp.1`'s; the
rest `xymonapi-rag.1`'s, and the API reads `XYMONAPI_RAG_INDEX`, `_MODEL`
and `_OFFLINE` too, for `/search`.

## Reaching the API from elsewhere

Xymon is what you look at when the rest is down, so the API depends on
nothing central: no directory, no certificate authority it must reach, no
DNS. Its password file and its certificate are Xymon's own, files on the
server. It listens on 127.0.0.1 unless told otherwise. From another
machine, use HTTPS, one of:

- **The API's own HTTPS.** Where the server has TLS for the Xymon protocol
  (`xymon-tls(7)`, from Xymon pull requests #617–#623, not yet merged), the API finds xymond's certificate and
  key in `etc/tls/` and speaks HTTPS on 1986 by itself; or name any
  certificate and key in `XYMONAPI_TLS_CERT` and `_KEY`. Open the port
  (`XYMONAPI_LISTEN="0.0.0.0:1986"`), then `XYMONAPI_URL=https://server:1986`
  on the laptop, with `XYMONAPI_CA` naming that certificate when it is
  self-signed. No web server in the path.
- **The web server in front of it.** `make install` writes
  `etc/xymonapi-apache.conf`, `-nginx.conf` and `-lighttpd.conf`, each
  passing `/xymon/api/` to the API. Include the one for your server where
  its Xymon configuration is, in the HTTPS part. Then
  `XYMONAPI_URL=https://xymon.example.ch`, one hostname for pages and API.
- **An SSH tunnel**, for one person: `ssh -L 1986:127.0.0.1:1986 xymon-server`,
  then `XYMONAPI_URL=http://127.0.0.1:1986` as if local. Encrypted,
  nothing to set up.

Plain HTTP across a network (`XYMONAPI_LISTEN="0.0.0.0:1986"` with no
certificate) carries the password and the status texts readable, as port
1984 does: keep it to a network where the Xymon pages themselves are plain
and trusted.

Whichever you choose, keep the secrets out of the texts: the API is
read-only and shows what the web pages show, and a process list can carry
a password typed on a command line. `XYMONAPI_HIDE` names a file of
regular expressions whose matches come out as `[hidden]`, on every text and
in the search index built from them. The password file is Xymon's own, so
each person has the user they have for the web pages.

Check from the laptop before anything else:

```sh
curl -u me https://xymon.example.ch/xymon/api/v1/health
```

Its `search` field says whether the server has an index, how big, and how
old. When the MCP server cannot reach the API, or is refused, its error says
which setting to look at first.

## MCP server

[`mcp-server/`](mcp-server) gives an AI client that speaks the Model Context
Protocol -- Claude Desktop, Claude Code -- read-only tools over the API:
`health`, `states`, `alarms`, `entities`, `status`, `series`, and the two
searches of the next section, `search_docs` and `search_history`, which ask
the API's `/search`. It runs where the client runs, from this checkout or
from `make install-client`, with the Python module in
[`mcp-server/requirements.txt`](mcp-server/requirements.txt) and nothing
else. For Claude Code, once, at user scope so every project has it:

```sh
claude mcp add --scope user xymon \
  -e XYMONAPI_URL=https://xymon.example.ch \
  -e XYMONAPI_TOKEN_FILE=$HOME/.config/xymon-api/xymon.token \
  -e XYMONAPI_PYTHON=/path/to/python3.12 \
  -- ~/.local/bin/xymonapi-mcp
```

That is the registration the [setup script](#on-a-laptop) makes. By hand,
the token is what a POST to `/tokens` with your password answers
(`xymonapi.8`, TOKENS), written alone in that file, mode 600.
`XYMONAPI_USER` and `XYMONAPI_PASSWORD_FILE` still work instead, but keep a
password on the machine. Leave out the token file when the API asks for no
password, and `XYMONAPI_PYTHON` when the system `python3` has the module.
For two Xymon servers, register twice under two names, `xymon-prod` and
`xymon-lab`, each with its own URL and token file. The two searches answer
a tool error until the server has an index.

For an API on another machine, see
[Reaching the API from elsewhere](#reaching-the-api-from-elsewhere): HTTPS,
with `XYMONAPI_CA` when the certificate is the server's own.

Every tool and setting is in
[`mcp-server/xymonapi-mcp.1`](mcp-server/xymonapi-mcp.1).

## Search

[`rag/`](rag) searches Xymon's manual pages and its history by meaning. The
index lives on the Xymon server, where the manual pages and the history
are: `make install` writes a daily xymonlaunch task, `tasks.d/xymonapi-rag`,
DISABLED. To enable it, remove the line, install the modules in
[`rag/requirements.txt`](rag/requirements.txt) for the Xymon user, and put
`XYMONAPI_RAG_DOCS` (a directory with Xymon's manual pages, `/usr/share/man`
will do) and, when the API asks for a password, `XYMONAPI_USER` and
`XYMONAPI_PASSWORD_FILE` in a file under `xymonserver.d/`. The first run
downloads a 65 MB embedding model, which `XYMONAPI_RAG_OFFLINE` can forbid
once the cache is seeded, and takes about a minute; the next ones embed only
what is new and take seconds. The index holds the last 30 days of history,
the newest 5000 changes at most, and the API serves it at `/search` as soon
as it is written.

From anywhere with access to the API:

```sh
xymonapi-rag search "what does purple mean"
xymonapi-rag ask "has /boot filled up before, and where?"
```

`search` uses the server's index when there is none here. `ask` hands the
passages to a language model speaking the OpenAI-compatible API, a local
Ollama by default, LM Studio with two settings. Pick the model with care: a
small one such as `llama3.2` answers in a second but makes options up, where
a larger one says when the passages do not hold the answer. With Claude, the
MCP tools are the simpler way. `eval` scores the search against a file of
questions; [`tests/eval/docs.json`](tests/eval/docs.json) is the one CI
runs. Every command and setting is in [`rag/xymonapi-rag.1`](rag/xymonapi-rag.1).

## Tests

The tests run against a server build of Xymon's current `main`: two of them
start its `xymond`, and all of them use its test helpers, which no release
has. `XYMON_SRC` names that tree, and is required: without it every test fails
at once.

```sh
XYMON_SRC=/path/to/built/xymon tests/run.sh
```

| test, under `tests/api/` | what it checks |
|---|---|
| `xymonapi-auth` | the htpasswd file, Xymon's own by default, lets in only its users; the MCP client with `XYMONAPI_PASSWORD_FILE`; `/client` writes the user who asked, and the address the request came through, and its script gets a password with a space, a quote, a backslash and a glob character to the API as it is, keeps a token for this machine's short hostname instead, and registers the MCP server with it; under `bash`, a Ctrl-C at its password prompt ends it with echo back on; a virtualenv a run before left half made is made again |
| `xymonapi-tokens` | a token per user and machine opens the API, replaces the last, is revoked on its own, cannot make, list or revoke tokens, is stored as its SHA-256 only, and lets the MCP client in |
| `xymonapi-board` | `/states`, `/alarms`, `/entities` and `/health` against a real `xymond`; `/status` gives exactly the host and test asked for, its text decoded as `xymondboard` wrote it and without the command line, and says whether it is acknowledged or disabled; `XYMONAPI_HIDE` blanks secrets, and a bad expression stops the API |
| `xymonapi-history` | `/events` and `/histlog` read what `xymond_history` wrote, its two-letter colours included, a long history a page at a time |
| `xymonapi-series` | `/series` reads an RRD, an HTTP test's too, answers 404 and 400 as documented, and refuses names that leave `XYMONRRDS` |
| `xymonapi-graphs` | `/graphs` reaches `showgraph.sh` through `XYMONWEBHOST` when `XYMONSERVERCGIURL` is a path |
| `xymonapi-install` | `make install` lays out the files, the web server snippets included, keeps what the admin edited; `make install-client` lays out the laptop side |
| `xymonapi-mcp` | the MCP server's eight tools answer with the API's board, are read-only, tell the model a status text is data, and say what to check when the API is out of reach |
| `xymonapi-rag` | the search finds the right manual page and history passage, from the index here or the API's; `/search` and `/health` serve the index and see it change; `index` embeds only what is new; `eval` scores; `ask` reaches a language model |
| `xymonapi-rag-eval` | ten questions about Xymon's own manual pages, all of them, score at least 8 |
| `xymonapi-rag-startup` | `index` waits for an API that is not up yet, and not for one that refuses it |
| `xymonapi-tls` | with xymond's certificate the API speaks HTTPS, `/client` says so and its script names the certificate file before asking for a password, the MCP client trusts `XYMONAPI_CA`, a readable key refuses to start |

They need `bash`, `curl`, and the Python modules of all three
`requirements.txt` -- the API's, `mcp-server/`'s and `rag/`'s -- for `python3`,
or the Python `XYMONAPI_PYTHON` names; some also need `rrdtool`, `openssl` or Apache's
`htpasswd`. The web server and the language model are stand-ins under
`tests/lib/`; the embedding model is the real one, downloaded once, about
65 MB. A test skips (exit 77) when something it needs is missing, and says
what. The whole run takes three to four minutes, most of it the search
tests. CI builds Xymon's `main` and runs them with nothing missing:
[`.github/workflows/test.yml`](.github/workflows/test.yml).

## Licence

GNU General Public License version 2 or, at your option, any later version
(`GPL-2.0-or-later`); the text of version 2 is in [`LICENSE`](LICENSE).
