"""Static file server that sends no-cache headers on every response, so phones
and browsers always pull the freshest build (no stale Flutter web assets).

Run from the directory you want to serve, e.g. build/web:
    python tools/nocache_server.py 8090
"""
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
    HTTPServer(("0.0.0.0", port), NoCacheHandler).serve_forever()
