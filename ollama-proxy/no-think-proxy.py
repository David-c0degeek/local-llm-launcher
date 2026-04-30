#!/usr/bin/env python3
import http.client
import json
import socket
import sys
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


TARGET_HOST = "127.0.0.1"
TARGET_PORT = 11434


def strip_thinking_fields(value):
    """
    Remove Claude/Anthropic thinking-related fields recursively.
    This keeps local/Ollama backends from choking on unsupported thinking config.
    """
    if isinstance(value, dict):
        cleaned = {}

        for key, item in value.items():
            lowered = key.lower()

            if lowered in {
                "thinking",
                "thinking_budget",
                "budget_tokens",
                "max_thinking_tokens",
                "reasoning",
                "reasoning_effort",
            }:
                continue

            cleaned[key] = strip_thinking_fields(item)

        return cleaned

    if isinstance(value, list):
        return [strip_thinking_fields(item) for item in value]

    return value


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Keep the terminal readable.
        sys.stdout.write("proxy: " + (fmt % args) + "\n")
        sys.stdout.flush()

    def _send_plain(self, status, text):
        body = text.encode("utf-8", errors="replace")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()

        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")

        if length <= 0:
            return b""

        return self.rfile.read(length)

    def _clean_request_body(self, body):
        if not body:
            return body

        content_type = self.headers.get("Content-Type", "")

        if "application/json" not in content_type.lower():
            return body

        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            return body

        data = strip_thinking_fields(data)

        # Extra hard disable, useful for Claude Code wrappers.
        data.pop("thinking", None)
        data.pop("reasoning", None)
        data.pop("reasoning_effort", None)

        return json.dumps(data, separators=(",", ":")).encode("utf-8")

    def _forward(self, method):
        body = self._read_body()
        body = self._clean_request_body(body)

        headers = {}

        for key, value in self.headers.items():
            lk = key.lower()

            if lk in {
                "host",
                "content-length",
                "connection",
                "proxy-connection",
                "accept-encoding",
                "transfer-encoding",
            }:
                continue

            headers[key] = value

        headers["Host"] = f"{TARGET_HOST}:{TARGET_PORT}"
        headers["Content-Length"] = str(len(body))
        headers["Connection"] = "close"

        conn = http.client.HTTPConnection(TARGET_HOST, TARGET_PORT, timeout=600)

        try:
            conn.request(method, self.path, body=body, headers=headers)
            resp = conn.getresponse()

            self.send_response(resp.status, resp.reason)

            response_headers = resp.getheaders()

            for key, value in response_headers:
                lk = key.lower()

                if lk in {
                    "connection",
                    "proxy-connection",
                    "keep-alive",
                    "transfer-encoding",
                    "content-length",
                }:
                    continue

                self.send_header(key, value)

            # Force close avoids a lot of half-open Windows socket weirdness.
            self.send_header("Connection", "close")
            self.end_headers()

            while True:
                try:
                    chunk = resp.read(8192)
                except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
                    print("proxy: upstream/downstream connection reset while reading response")
                    break

                if not chunk:
                    break

                try:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    print("proxy: client disconnected while writing response")
                    break

        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
            print("proxy: connection reset/aborted")
        except socket.timeout:
            self._send_plain(504, "Proxy timeout while waiting for Ollama.")
        except Exception as ex:
            print("proxy error:", repr(ex))
            traceback.print_exc()
            self._send_plain(502, f"Proxy error: {ex}")
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def do_GET(self):
        # Simple health endpoint.
        if self.path in {"/", "/health", "/healthz"}:
            self._send_plain(200, "ok")
            return

        self._forward("GET")

    def do_POST(self):
        self._forward("POST")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Connection", "close")
        self.end_headers()


def main():
    listen_port = int(sys.argv[1]) if len(sys.argv) > 1 else 11435

    server = ThreadingHTTPServer(("127.0.0.1", listen_port), ProxyHandler)
    server.daemon_threads = True

    print(f"no-think-proxy: 127.0.0.1:{listen_port} -> {TARGET_HOST}:{TARGET_PORT}", flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nno-think-proxy: stopped", flush=True)


if __name__ == "__main__":
    main()