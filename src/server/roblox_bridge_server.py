#!/usr/bin/env python3
"""
Roblox Studio MCP Bridge Daemon v0.8
Run once; all AI agent instances share this bridge.

Usage:
    python roblox_bridge_server.py [--http-port 28650] [--quiet]
"""

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, urlparse

DEFAULT_CLIENT_ID = "studio"
DEFAULT_HTTP_PORT = 28650
DEFAULT_HTTP_BIND = ""
DEFAULT_POLL_TIMEOUT_SEC = 5


def _json_response(handler, status, payload):
    data = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


class JobQueue:
    """Thread-safe job queue with per-client pending lists and result storage."""

    def __init__(self):
        self._pending: dict[str, list[dict]] = {}
        self._results: dict[str, dict] = {}
        self._last_seen: dict[str, float] = {}
        self._cv = threading.Condition()

    def mark_seen(self, client_id: str):
        with self._cv:
            self._last_seen[client_id] = time.time()
            self._cv.notify_all()

    def get_last_seen(self, client_id: str):
        with self._cv:
            return self._last_seen.get(client_id)

    def is_connected(self, client_id: str, max_age: float = 15.0) -> bool:
        with self._cv:
            last = self._last_seen.get(client_id)
            if last is None:
                return False
            return (time.time() - last) < max_age

    def list_clients(self, max_age: float = 15.0):
        now = time.time()
        with self._cv:
            return [
                {
                    "client_id": client_id,
                    "connected": (now - last_seen) < max_age,
                    "last_seen_seconds": round(now - last_seen, 1),
                }
                for client_id, last_seen in sorted(self._last_seen.items())
            ]

    def enqueue(self, client_id: str, job: dict):
        with self._cv:
            self._pending.setdefault(client_id, []).append(job)
            self._cv.notify_all()

    def wait_for_job(self, client_id: str, timeout_sec: float):
        deadline = time.time() + timeout_sec
        with self._cv:
            while True:
                queue = self._pending.get(client_id)
                if queue:
                    return queue.pop(0)
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                self._cv.wait(timeout=remaining)

    def store_result(self, job_id: str, result: dict):
        with self._cv:
            self._results[job_id] = result
            self._cv.notify_all()

    def get_result(self, job_id: str):
        with self._cv:
            return self._results.pop(job_id, None)


class RobloxBridgeHttpHandler(BaseHTTPRequestHandler):
    server_version = "RobloxMcpBridge/0.8"

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/poll":
            qs = parse_qs(parsed.query or "")
            client_id = (qs.get("client_id") or [DEFAULT_CLIENT_ID])[0]
            self.server.job_queue.mark_seen(client_id)
            job = self.server.job_queue.wait_for_job(
                client_id, self.server.poll_timeout_sec
            )
            _json_response(self, 200, {"ok": True, "job": job})
            return

        if parsed.path.startswith("/result/"):
            job_id = parsed.path.rsplit("/", 1)[-1]
            if not job_id:
                _json_response(self, 400, {"ok": False, "error": "missing_job_id"})
                return
            result = self.server.job_queue.get_result(job_id)
            if result is None:
                _json_response(self, 200, {"ok": True, "ready": False})
                return
            _json_response(self, 200, {"ok": True, "ready": True, "result": result})
            return

        if parsed.path == "/clients":
            _json_response(self, 200, {"ok": True, "clients": self.server.job_queue.list_clients()})
            return

        if parsed.path == "/status":
            qs = parse_qs(parsed.query or "")
            client_id = (qs.get("client_id") or [None])[0]
            if client_id:
                last_seen = self.server.job_queue.get_last_seen(client_id)
                if last_seen is None:
                    payload = {"ok": True, "connected": False, "client_id": client_id}
                else:
                    age = time.time() - last_seen
                    payload = {
                        "ok": True,
                        "connected": age < 15,
                        "client_id": client_id,
                        "last_seen_seconds": round(age, 1),
                    }
            else:
                payload = {"ok": True, "status": "running", "clients": self.server.job_queue.list_clients()}
            _json_response(self, 200, payload)
            return

        if parsed.path == "/ping":
            qs = parse_qs(parsed.query or "")
            client_id = (qs.get("client_id") or [DEFAULT_CLIENT_ID])[0]
            self.server.job_queue.mark_seen(client_id)
            _json_response(self, 200, {"ok": True, "server_time": time.time()})
            return

        if parsed.path == "/health":
            _json_response(self, 200, {"ok": True, "uptime": time.time()})
            return

        _json_response(self, 404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        parsed = urlparse(self.path)

        if parsed.path == "/result":
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError:
                _json_response(self, 400, {"ok": False, "error": "invalid_json"})
                return

            job_id = payload.get("job_id")
            if not job_id:
                _json_response(self, 400, {"ok": False, "error": "missing_job_id"})
                return

            self.server.job_queue.store_result(job_id, payload)
            _json_response(self, 200, {"ok": True})
            return

        if parsed.path == "/job":
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError:
                _json_response(self, 400, {"ok": False, "error": "invalid_json"})
                return

            job_id = payload.get("job_id")
            client_id = payload.get("client_id") or DEFAULT_CLIENT_ID
            action = payload.get("action")
            params = payload.get("params")
            if not job_id:
                _json_response(self, 400, {"ok": False, "error": "missing_job_id"})
                return
            if not action:
                _json_response(self, 400, {"ok": False, "error": "missing_action"})
                return
            if not isinstance(params, dict):
                _json_response(self, 400, {"ok": False, "error": "invalid_params"})
                return

            self.server.job_queue.enqueue(
                client_id,
                {
                    "job_id": job_id,
                    "type": action,
                    "args": params,
                    "created_at": time.time(),
                },
            )
            _json_response(self, 200, {"ok": True, "job_id": job_id})
            return

        _json_response(self, 404, {"ok": False, "error": "not_found"})

    def log_message(self, fmt, *args):
        if not self.server.quiet:
            super().log_message(fmt, *args)


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class RobloxBridgeHttpServer(ThreadingHTTPServer):
    def __init__(self, addr, handler, job_queue, poll_timeout_sec, quiet):
        super().__init__(addr, handler)
        self.job_queue = job_queue
        self.poll_timeout_sec = poll_timeout_sec
        self.quiet = quiet


def main():
    parser = argparse.ArgumentParser(description="Roblox MCP bridge daemon")
    parser.add_argument("--http-bind", default=DEFAULT_HTTP_BIND)
    parser.add_argument("--http-port", type=int, default=DEFAULT_HTTP_PORT)
    parser.add_argument("--poll-timeout", type=int, default=DEFAULT_POLL_TIMEOUT_SEC)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    job_queue = JobQueue()
    pid_file = Path.home() / ".roblox-mcp-bridge.pid"
    pid_file.write_text(str(os.getpid()), encoding="utf-8")

    print(f"[Bridge v0.8] Listening on port {args.http_port}", file=sys.stderr)
    print("[Bridge v0.8] Multiple AI agents can now connect simultaneously", file=sys.stderr)

    http_server = RobloxBridgeHttpServer(
        (args.http_bind, args.http_port),
        RobloxBridgeHttpHandler,
        job_queue,
        args.poll_timeout,
        args.quiet,
    )

    try:
        http_server.serve_forever()
    finally:
        pid_file.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
