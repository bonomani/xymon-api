# SPDX-License-Identifier: GPL-2.0-or-later
"""A stand-in for Xymon's web server, for the /graphs test.

    fake-showgraph.py PORTFILE RECORD

Listens on a free port on 127.0.0.1 and writes it to PORTFILE. Every GET is
written to RECORD -- its path with the query string -- and one whose path
ends in /showgraph.sh is answered with a small PNG, as showgraph.cgi would
draw one; any other path is a 404. Two hosts behave otherwise, as a real
showgraph can: host=slow.* is answered after five seconds, and host=html.*
with an HTML error page and status 200.
"""
import http.server
import sys
import time

portfile, record = sys.argv[1], sys.argv[2]
# The eight-byte PNG signature and nothing more: enough to be told from JSON.
PNG = b"\x89PNG\r\n\x1a\n"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(record, "w", encoding="utf-8") as fd:
            fd.write(self.path + "\n")
        if not self.path.split("?", 1)[0].endswith("/showgraph.sh"):
            self.send_error(404)
            return
        if "host=slow." in self.path:
            time.sleep(5)
        if "host=html." in self.path:
            page = b"<html><body>showgraph: no such graph</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(PNG)))
        self.end_headers()
        self.wfile.write(PNG)

    def log_message(self, *args):
        pass


httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(portfile, "w") as fd:
    fd.write(str(httpd.server_address[1]))
httpd.serve_forever()
