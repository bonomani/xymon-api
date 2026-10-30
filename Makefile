# SPDX-License-Identifier: GPL-2.0-or-later
# Install the Xymon API into an existing Xymon server: xymonapi(8).
#
#   make install XYMONHOME=/usr/lib/xymon/server
#   make install-client [PREFIX=$HOME/.local]
#
# install is for the Xymon server. install-client is for a laptop that reads
# an API elsewhere: the MCP server and the search commands, under PREFIX,
# with xymonapi-mcp and xymonapi-rag in PREFIX/bin.
#
# XYMONHOME is the server directory, as xymonserver.cfg names it. Xymon's own
# install links $XYMONHOME/ext and $XYMONHOME/etc to wherever those really
# are, so nothing else needs saying. DESTDIR stages the install for a package;
# MANDIR is where the manual page goes. Nothing is built: the API is copied as
# it is, and needs no Python until it runs.
#
# Every path is quoted in the recipes, and XYMONHOME is escaped before it is
# put into a task file with sed: a directory with a space, an & or a | in
# its name is a directory like any other.

MANDIR = /usr/share/man
PREFIX = $(HOME)/.local
API = app.py xymon.py openapi.yaml requirements.txt xymonapi.sh
RAG = rag/xymonrag.py rag/xymonapi-rag.sh rag/requirements.txt
MCP = mcp-server/server.py mcp-server/client.py mcp-server/xymonapi-mcp.sh mcp-server/requirements.txt
CLIENT = $(DESTDIR)$(PREFIX)/libexec/xymonapi
# xymonrag.py reads the history through mcp-server/client.py, found beside rag/.
EXT = $(DESTDIR)$(XYMONHOME)/ext/xymonapi
TASKDIR = $(DESTDIR)$(XYMONHOME)/etc/tasks.d
MAN1 = $(DESTDIR)$(MANDIR)/man1
MAN8 = $(DESTDIR)$(MANDIR)/man8

all:

# A task file is written only where there is none, so the one an admin
# enabled is not put back to DISABLED by the next install.
install:
	@test -n "$(XYMONHOME)" || { echo "usage: make install XYMONHOME=<the Xymon server directory>" >&2; exit 1; }
	mkdir -p "$(EXT)/rag" "$(EXT)/mcp-server"
	cp -f $(API) "$(EXT)/"
	chmod 644 "$(EXT)/app.py" "$(EXT)/xymon.py" "$(EXT)/openapi.yaml" "$(EXT)/requirements.txt"
	chmod 755 "$(EXT)/xymonapi.sh"
	cp -f $(RAG) "$(EXT)/rag/"
	cp -f mcp-server/client.py "$(EXT)/mcp-server/"
	chmod 644 "$(EXT)/rag/xymonrag.py" "$(EXT)/rag/requirements.txt" "$(EXT)/mcp-server/client.py"
	chmod 755 "$(EXT)/rag/xymonapi-rag.sh"
	mkdir -p "$(MAN8)" "$(MAN1)"
	cp -f xymonapi.8 "$(MAN8)/"
	cp -f rag/xymonapi-rag.1 "$(MAN1)/"
	chmod 644 "$(MAN8)/xymonapi.8" "$(MAN1)/xymonapi-rag.1"
	mkdir -p "$(TASKDIR)"
	$(call task,xymonapi.tasks.DIST,xymonapi)
	$(call task,rag/xymonapi-rag.tasks.DIST,xymonapi-rag)
	@if [ -e "$(DESTDIR)$(XYMONHOME)/etc/xymonapi-apache.conf" ]; then \
		echo "keeping $(DESTDIR)$(XYMONHOME)/etc/xymonapi-apache.conf"; \
	else \
		cp xymonapi-apache.conf "$(DESTDIR)$(XYMONHOME)/etc/"; \
		chmod 644 "$(DESTDIR)$(XYMONHOME)/etc/xymonapi-apache.conf"; \
	fi

# The client side, where no Xymon is: the MCP server and the search
# commands, in PREFIX/libexec/xymonapi, with two commands in PREFIX/bin
# that run them from there. xymonrag.py finds client.py beside it, as in
# the repository.
install-client:
	mkdir -p "$(CLIENT)/mcp-server" "$(CLIENT)/rag" "$(DESTDIR)$(PREFIX)/bin" "$(DESTDIR)$(PREFIX)/share/man/man1"
	cp -f $(MCP) "$(CLIENT)/mcp-server/"
	cp -f $(RAG) "$(CLIENT)/rag/"
	chmod 644 "$(CLIENT)/mcp-server/server.py" "$(CLIENT)/mcp-server/client.py" "$(CLIENT)/mcp-server/requirements.txt" "$(CLIENT)/rag/xymonrag.py" "$(CLIENT)/rag/requirements.txt"
	chmod 755 "$(CLIENT)/mcp-server/xymonapi-mcp.sh" "$(CLIENT)/rag/xymonapi-rag.sh"
	printf '#!/bin/sh\nexec "%s/libexec/xymonapi/mcp-server/xymonapi-mcp.sh" "$$@"\n' '$(PREFIX)' > "$(DESTDIR)$(PREFIX)/bin/xymonapi-mcp"
	printf '#!/bin/sh\nexec "%s/libexec/xymonapi/rag/xymonapi-rag.sh" "$$@"\n' '$(PREFIX)' > "$(DESTDIR)$(PREFIX)/bin/xymonapi-rag"
	chmod 755 "$(DESTDIR)$(PREFIX)/bin/xymonapi-mcp" "$(DESTDIR)$(PREFIX)/bin/xymonapi-rag"
	cp -f mcp-server/xymonapi-mcp.1 rag/xymonapi-rag.1 "$(DESTDIR)$(PREFIX)/share/man/man1/"
	chmod 644 "$(DESTDIR)$(PREFIX)/share/man/man1/xymonapi-mcp.1" "$(DESTDIR)$(PREFIX)/share/man/man1/xymonapi-rag.1"

# task DIST NAME -- write DIST as $(TASKDIR)/NAME, with @XYMONHOME@ replaced,
# unless NAME is there already. The replacement is escaped for sed first: a
# backslash, an & and the | used as the delimiter would otherwise be read
# as sed syntax.
define task
	if [ -e "$(TASKDIR)/$(2)" ]; then \
		echo "keeping $(TASKDIR)/$(2)"; \
	else \
		home=$$(printf '%s\n' '$(XYMONHOME)' | sed -e 's/[\\&|]/\\&/g'); \
		sed -e "s|@XYMONHOME@|$$home|g" "$(1)" > "$(TASKDIR)/$(2)"; \
		chmod 644 "$(TASKDIR)/$(2)"; \
	fi
endef

.PHONY: all install install-client
