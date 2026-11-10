#!/usr/bin/env python3
"""Minimal stand-in for the Tailscale API used by tests/tailscale-provisioning.nix.

Serves GET /api/v2/tailnet/-/devices from /var/lib/tailscale-mock-api/devices.json
and logs each DELETE /api/v2/device/<id> to /var/lib/tailscale-mock-api/deletes.log,
so the VM test can assert exactly which device IDs the dedup script deleted.
Requires the same bearer token the script under test uses (FAKE_ prefixed --
never a real credential) on every request.
"""

import http.server
import os
import sys

TOKEN = "FAKE_test_api_token"
STATE_DIR = "/var/lib/tailscale-mock-api"
DEVICES_PATH = os.path.join(STATE_DIR, "devices.json")
REQUESTS_LOG_PATH = os.path.join(STATE_DIR, "requests.log")
DELETES_LOG_PATH = os.path.join(STATE_DIR, "deletes.log")


class Handler(http.server.BaseHTTPRequestHandler):
    def parse_request(self):
        parsed = super().parse_request()
        if parsed:
            with open(REQUESTS_LOG_PATH, "a") as log:
                log.write(f"{self.command} {self.path}\n")
        return parsed

    def _authorized(self):
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def do_GET(self):
        if not self._authorized():
            self.send_response(401)
            self.end_headers()
            return
        if self.path == "/api/v2/tailnet/-/devices":
            if not os.path.exists(DEVICES_PATH):
                self.send_response(503)
                self.end_headers()
                return
            with open(DEVICES_PATH, "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_DELETE(self):
        if not self._authorized():
            self.send_response(401)
            self.end_headers()
            return
        prefix = "/api/v2/device/"
        if self.path.startswith(prefix):
            device_id = self.path[len(prefix) :]
            with open(DELETES_LOG_PATH, "a") as f:
                f.write(device_id + "\n")
            self.send_response(200)
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8927
    os.makedirs(STATE_DIR, exist_ok=True)
    if not os.path.exists(DELETES_LOG_PATH):
        open(DELETES_LOG_PATH, "w").close()
    http.server.HTTPServer(("0.0.0.0", port), Handler).serve_forever()
