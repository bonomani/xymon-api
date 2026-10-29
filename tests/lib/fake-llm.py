# SPDX-License-Identifier: GPL-2.0-or-later
"""A stand-in for a language model that speaks the OpenAI-compatible API, for
the tests of xymonapi-rag ask.

    fake-llm.py PORTFILE RECORD

Listens on a free port on 127.0.0.1 and writes it to PORTFILE. Each POST to
/v1/chat/completions is written to RECORD -- its Authorization header, then
its body -- and answered with the fixed text FAKE ANSWER.
"""
import http.server
import json
import sys

portfile, record = sys.argv[1], sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(record, "w", encoding="utf-8") as fd:
            fd.write(f'Authorization: {self.headers.get("Authorization", "")}\n')
            fd.write(body.decode("utf-8"))
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
