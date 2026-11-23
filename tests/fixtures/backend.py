#!/usr/bin/env python3
"""e2e 用の上流（バックエンド）。受け取った要求を JSON にして返す。使い方: backend.py PORT NAME"""
import http.server
import json
import socketserver
import sys
import time

PORT = int(sys.argv[1])
NAME = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_any(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        path = self.path.split("?")[0]
        if path.endswith("/hang"):
            time.sleep(30)
            return
        if path.endswith("/slow"):
            time.sleep(5)
        if path.endswith("/chunked"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("X-Backend", NAME)
            self.end_headers()
            for part in (b"hello ", b"chunked ", b"world"):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
            self.wfile.write(b"0\r\n\r\n")
            return
        if path.endswith("/tinychunks"):
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"".join(b"1\r\nx\r\n" for _ in range(200000)) + b"0\r\n\r\n")
            return
        if path.endswith("/notfound"):
            out = b"nope"
            self.send_response(404)
            self.send_header("Content-Length", str(len(out)))
            self.send_header("X-Backend", NAME)
            self.end_headers()
            self.wfile.write(out)
            return
        if path.endswith("/hopbyhop"):
            out = b"hop"
            self.send_response(200)
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Connection", "close, X-Drop-Me")
            self.send_header("X-Drop-Me", "secret")
            self.send_header("Keep-Alive", "timeout=5")
            self.send_header("X-Backend", NAME)
            self.end_headers()
            self.wfile.write(out)
            return
        record = {
            "backend": NAME,
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body_hex": body.hex(),
        }
        out = json.dumps(record).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.send_header("X-Backend", NAME)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(out)

    do_GET = do_POST = do_PUT = do_HEAD = do_DELETE = handle_any

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


Server(("127.0.0.1", PORT), Handler).serve_forever()
