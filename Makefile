# SPDX-License-Identifier: GPL-2.0-or-later
# Install the Xymon API into an existing Xymon server: xymonapi(8).
#
#   make install XYMONHOME=/usr/lib/xymon/server
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
API = app.py xymon.py openapi.yaml requirements.txt xymonapi.sh
RAG = rag/xymonrag.py rag/xymonapi-rag.sh rag/requirements.txt
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

.PHONY: all install
