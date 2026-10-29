# SPDX-License-Identifier: GPL-2.0-or-later
"""A stand-in HTTP server for the tests: a language model that speaks the
OpenAI-compatible API, for xymonapi-rag ask, or a server that redirects.

    fake-llm.py PORTFILE RECORD [REDIRECT]

Listens on a free port on 127.0.0.1 and writes it to PORTFILE. Every request
is written to RECORD -- its Authorization header, then its body. A POST to
/v1/chat/completions is answered with the fixed text FAKE ANSWER. With
REDIRECT, a URL, every request is answered 302 to it instead.
"""
import http.server
import json
import sys

portfile, record = sys.argv[1], sys.argv[2]
redirect = sys.argv[3] if len(sys.argv) > 3 else ""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.do_POST()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(record, "w", encoding="utf-8") as fd:
            fd.write(f'Authorization: {self.headers.get("Authorization", "")}\n')
            fd.write(body.decode("utf-8"))
        if redirect:
            self.send_response(302)
            self.send_header("Location", redirect)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        answer = json.dumps({"choices": [{"message": {"role": "assistant",
                                                      "content": "FAKE ANSWER"}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)

    def log_message(self, *args):
        pass


httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(portfile, "w") as fd:
    fd.write(str(httpd.server_address[1]))
httpd.serve_forever()
