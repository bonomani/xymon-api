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

MANDIR = /usr/share/man
API = app.py xymon.py openapi.yaml requirements.txt xymonapi.sh
RAG = rag/xymonrag.py rag/xymonapi-rag.sh rag/requirements.txt
# xymonrag.py reads the history through mcp-server/client.py, found beside rag/.
EXT = $(DESTDIR)$(XYMONHOME)/ext/xymonapi
TASKDIR = $(DESTDIR)$(XYMONHOME)/etc/tasks.d

all:

# The task file is written only where there is none, so the one an admin
# enabled is not put back to DISABLED by the next install.
install:
	@test -n "$(XYMONHOME)" || { echo "usage: make install XYMONHOME=<the Xymon server directory>" >&2; exit 1; }
	mkdir -p $(EXT)
	cp -f $(API) $(EXT)/
	chmod 644 $(EXT)/app.py $(EXT)/xymon.py $(EXT)/openapi.yaml $(EXT)/requirements.txt
	chmod 755 $(EXT)/xymonapi.sh
	mkdir -p $(EXT)/rag $(EXT)/mcp-server
	cp -f $(RAG) $(EXT)/rag/
	cp -f mcp-server/client.py $(EXT)/mcp-server/
	chmod 644 $(EXT)/mcp-server/client.py
	chmod 644 $(EXT)/rag/xymonrag.py $(EXT)/rag/requirements.txt
	chmod 755 $(EXT)/rag/xymonapi-rag.sh
	mkdir -p $(DESTDIR)$(MANDIR)/man8 $(DESTDIR)$(MANDIR)/man1
	cp -f xymonapi.8 $(DESTDIR)$(MANDIR)/man8/
	cp -f rag/xymonapi-rag.1 $(DESTDIR)$(MANDIR)/man1/
	chmod 644 $(DESTDIR)$(MANDIR)/man8/xymonapi.8 $(DESTDIR)$(MANDIR)/man1/xymonapi-rag.1
	mkdir -p $(TASKDIR)
	if [ -e $(TASKDIR)/xymonapi ]; then \
		echo "keeping $(TASKDIR)/xymonapi"; \
	else \
		sed -e 's!@XYMONHOME@!$(XYMONHOME)!g' xymonapi.tasks.DIST > $(TASKDIR)/xymonapi; \
		chmod 644 $(TASKDIR)/xymonapi; \
	fi
	if [ -e $(TASKDIR)/xymonapi-rag ]; then \
		echo "keeping $(TASKDIR)/xymonapi-rag"; \
	else \
		sed -e 's!@XYMONHOME@!$(XYMONHOME)!g' rag/xymonapi-rag.tasks.DIST > $(TASKDIR)/xymonapi-rag; \
		chmod 644 $(TASKDIR)/xymonapi-rag; \
	fi

.PHONY: all install
