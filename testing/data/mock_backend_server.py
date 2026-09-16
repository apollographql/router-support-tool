# Adapted from runtime-testing-framework/mock-backend/server.py:
# - drops the /gcs/ path restriction
# - drops the fake Prometheus query_range endpoint
# - accepts a PUT/GET on any path so the router-diagnostics Job can upload the
#    bundle via job.storage.provider: url and the Scenario can retrieve it for verification.
import http.server
import sys
import threading
import urllib.parse

_store: dict[str, bytes] = {}
_lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        with _lock:
            _store[path] = body
        print(f"PUT {path} {len(body)} bytes", file=sys.stderr, flush=True)
        self._respond(200, b"")

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        with _lock:
            data = _store.get(path)
        print(f"GET {path}", file=sys.stderr, flush=True)
        self._respond(200, data) if data is not None else self._respond(404, b"not found")

    def _respond(self, status: int, body: bytes, content_type: str | None = None):
        self.send_response(status)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("", 8080), Handler)
    print("mock-backend listening on :8080", file=sys.stderr, flush=True)
    server.serve_forever()
