#!/usr/bin/env python3
"""キャッシュ結合テスト用の上流バックエンド。
使い方: cache_backend.py PORT [LOG_FILE]
"""
import http.server
import socketserver
import sys
import threading

PORT = int(sys.argv[1])
LOG_FILE = sys.argv[2] if len(sys.argv) > 2 else None

seq = 0
lock = threading.Lock()


def record_request(path):
    global seq
    with lock:
        seq += 1
        cnt = seq
    if LOG_FILE:
        with open(LOG_FILE, "a") as f:
            f.write(f"{path} count={cnt}\n")
    return cnt


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_any(self):
        path_only = self.path.split("?")[0]

        if path_only.endswith("/ping"):
            self.send_response(200)
            self.send_header("Content-Length", "4")
            self.end_headers()
            self.wfile.write(b"pong")
            return

        cnt = record_request(self.path)

        if path_only.endswith("/cacheable"):
            out = f"cached response count={cnt}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "public, max-age=2")
            self.send_header("X-Origin-Count", str(cnt))
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/s-maxage"):
            out = f"s-maxage response count={cnt}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "public, s-maxage=2, max-age=60")
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/private"):
            out = f"private response count={cnt}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "private, max-age=60")
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/private-qual"):
            out = f"private-qual response count={cnt}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "private=\"x-user-info\", max-age=60")
            self.send_header("X-User-Info", "secret-token")
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/no-cache-qual"):
            out = f"no-cache-qual response count={cnt}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "no-cache=\"x-user-info\", max-age=60")
            self.send_header("X-User-Info", "secret-token")
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/age-stale"):
            out = f"age-stale response count={cnt}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "max-age=10")
            self.send_header("Age", "15")
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/age-active"):
            out = f"age-active response count={cnt}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "max-age=10")
            self.send_header("Age", "2")
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/no-store"):
            out = f"no-store response count={cnt}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/set-cookie"):
            out = f"cookie response count={cnt}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "public, max-age=60")
            self.send_header("Set-Cookie", "session=xyz; Path=/")
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/vary"):
            out = f"vary response count={cnt}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "public, max-age=60")
            self.send_header("Vary", "Accept-Language")
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/big"):
            # 3500 bytes (> 3072 bytes limit)
            out = b"X" * 3500
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "public, max-age=60")
            self.end_headers()
            self.wfile.write(out)
            return

        if path_only.endswith("/notfound"):
            out = b"not found"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Cache-Control", "public, max-age=60")
            self.end_headers()
            self.wfile.write(out)
            return

        out = f"default count={cnt}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    do_GET = do_POST = do_PUT = do_HEAD = do_DELETE = handle_any

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


Server(("127.0.0.1", PORT), Handler).serve_forever()
