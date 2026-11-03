"""Synthetic HTTPS API: keep listening while readiness changes independently."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
import time


class API(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/readyz" or self.headers.get("Authorization"):
            self.send_response(400)
        else:
            state = Path("/run/api-state").read_text().strip()
            if state.startswith("auth"):
                state = state[4:] if self.connection.getpeercert() else "401"
            if state == "timeout":
                time.sleep(5)
                return
            if state == "disconnect":
                self.connection.close()
                return
            self.send_response(int(state))
            if state == "302":
                self.send_header("Location", "/readyz?exclude=etcd")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args):
        pass


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/run/api-fixture/cert.pem", "/run/api-fixture/key.pem")
context.load_verify_locations("/run/api-fixture/cert.pem")
context.verify_mode = ssl.CERT_OPTIONAL
server = ThreadingHTTPServer(("127.0.0.1", 6443), API)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
