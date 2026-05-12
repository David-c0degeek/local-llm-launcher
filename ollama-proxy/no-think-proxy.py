#!/usr/bin/env python3
"""
no-think-proxy
==============
HTTP proxy that sits in front of a local LLM backend (Ollama or llama.cpp's
llama-server) for use with Claude Code / Unshackled.

Two jobs:

1. Strip Anthropic "thinking" config from outgoing /v1/messages requests so
   local backends don't choke on unsupported fields (existing behaviour).

2. Strip <think>...</think> blocks from incoming /v1/messages response text
   so reasoning models (Qwen3 reasoning variants, DeepSeek R1 merges, etc.)
   don't pollute the conversation or break consumers that JSON.parse the
   response body (e.g. session-title generation in Unshackled).

Streaming (SSE) and non-streaming JSON are both handled. The think-stripper
is stateful and tolerates <think> tags split across SSE chunks.

Usage
-----
  python no-think-proxy.py [LISTEN_PORT] [TARGET]

    LISTEN_PORT   Port to listen on. Default: 11435.
    TARGET        Upstream as "host:port" or just "port". Default: 127.0.0.1:11434
                  (Ollama). For llama.cpp pass "8080" or "127.0.0.1:8080".

Env-var fallbacks (used when arg not given):
    NO_THINK_PROXY_LISTEN_PORT
    NO_THINK_PROXY_TARGET
"""
import http.client
import json
import os
import socket
import sys
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Bump on every wire-format change (request rewriting, response stripping, SSE
# handling). LocalBox compares this against NoThinkProxyRequiredVersion in
# defaults.json and warns when the deployed proxy is older than the launcher
# expects. Format: SemVer "MAJOR.MINOR.PATCH".
__version__ = "1.0.0"


TARGET_HOST = "127.0.0.1"
TARGET_PORT = 11434

THINK_OPEN = "<think>"
THINK_CLOSE = "</think>"
# Hold back this many chars at the end of each chunk while not-in-think, in
# case the trailing bytes are the start of an unclosed `<think>` tag we'd
# otherwise emit early.
_HOLDBACK_OPEN = len(THINK_OPEN) - 1
_HOLDBACK_CLOSE = len(THINK_CLOSE) - 1


def strip_thinking_fields(value):
    """Remove Anthropic thinking-related fields recursively from a request body."""
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


class ThinkStripper:
    """
    Streaming text filter that removes <think>...</think> blocks.

    Designed for SSE deltas where text arrives in many small chunks: a tag may
    be split across chunks (e.g. one delta ends with "<thi" and the next
    starts with "nk>"). We keep state across calls and hold back a few tail
    characters when they could be the start of a tag.
    """

    def __init__(self):
        self.in_think = False
        self.buffer = ""

    def feed(self, text):
        if not text:
            return ""

        self.buffer += text
        out_parts = []

        while True:
            if self.in_think:
                idx = self.buffer.find(THINK_CLOSE)

                if idx == -1:
                    # No close tag yet. Keep enough tail to match a future split close tag.
                    keep = min(len(self.buffer), _HOLDBACK_CLOSE)
                    self.buffer = self.buffer[-keep:] if keep > 0 else ""
                    break

                # Drop everything through the close tag.
                self.buffer = self.buffer[idx + len(THINK_CLOSE):]
                self.in_think = False
                continue

            idx = self.buffer.find(THINK_OPEN)

            if idx == -1:
                # No open tag in buffer. Emit everything except a possible
                # partial-tag tail.
                keep = min(len(self.buffer), _HOLDBACK_OPEN)

                if keep > 0:
                    out_parts.append(self.buffer[:-keep])
                    self.buffer = self.buffer[-keep:]
                else:
                    out_parts.append(self.buffer)
                    self.buffer = ""

                break

            # Emit text before the open tag, then enter think mode.
            out_parts.append(self.buffer[:idx])
            self.buffer = self.buffer[idx + len(THINK_OPEN):]
            self.in_think = True

        return "".join(out_parts)

    def flush(self):
        """Emit any remaining buffered text (called at end-of-stream)."""
        # If we're still inside a think block when the stream ends, drop it.
        out = "" if self.in_think else self.buffer
        self.buffer = ""
        self.in_think = False
        return out


def _strip_think_in_obj(obj):
    """
    Walk a non-streaming Anthropic /v1/messages response and strip <think>
    blocks from any text content blocks. Mutates and returns `obj`.
    """
    if not isinstance(obj, dict):
        return obj

    content = obj.get("content")

    if isinstance(content, list):
        stripper = ThinkStripper()

        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                cleaned = stripper.feed(block.get("text", "")) + stripper.flush()
                # Reset for the next block — think tags shouldn't span blocks.
                stripper = ThinkStripper()
                block["text"] = cleaned

    return obj


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
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

    def _is_messages_path(self):
        return self.path.startswith("/v1/messages")

    def _stream_strip(self, resp):
        """
        Forward an SSE response chunk-by-chunk while stripping <think> blocks
        from `content_block_delta` text_delta payloads. Other event types
        (message_start, content_block_start/stop, message_delta, ping, etc.)
        pass through unmodified.

        Per-block <think> state lives in `strippers` keyed by content-block
        index. On `content_block_stop` we flush any held-back tail by
        injecting a synthetic `content_block_delta` event ahead of the stop.
        """
        strippers = {}

        def get_stripper(idx):
            if idx not in strippers:
                strippers[idx] = ThinkStripper()
            return strippers[idx]

        buffer = b""

        while True:
            try:
                chunk = resp.read(8192)
            except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
                print("proxy: upstream connection reset while reading SSE")
                return

            if not chunk:
                break

            buffer += chunk

            while True:
                sep_idx = buffer.find(b"\n\n")

                if sep_idx == -1:
                    break

                event_bytes = buffer[:sep_idx]
                buffer = buffer[sep_idx + 2:]
                emit = self._rewrite_event(event_bytes, get_stripper)

                try:
                    self.wfile.write(emit)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    print("proxy: client disconnected during SSE")
                    return

        # Trailing partial event (no terminating blank line). Forward as-is.
        if buffer:
            try:
                self.wfile.write(buffer)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass

    def _rewrite_event(self, event_bytes, get_stripper):
        """
        Rewrite a single SSE event. Returns the bytes to emit, terminated
        with a `\\n\\n` event separator. May emit multiple events (e.g. an
        injected text_delta carrying flushed tail bytes ahead of a
        content_block_stop).
        """
        prefix_events = b""
        out_lines = []

        for line in event_bytes.split(b"\n"):
            if not line.startswith(b"data: "):
                out_lines.append(line)
                continue

            payload = line[6:]

            try:
                data = json.loads(payload.decode("utf-8"))
            except Exception:
                out_lines.append(line)
                continue

            if not isinstance(data, dict):
                out_lines.append(line)
                continue

            event_type = data.get("type")

            if (
                event_type == "content_block_delta"
                and isinstance(data.get("delta"), dict)
                and data["delta"].get("type") == "text_delta"
            ):
                idx = data.get("index", 0)
                stripper = get_stripper(idx)
                data["delta"]["text"] = stripper.feed(data["delta"].get("text", ""))
                out_lines.append(b"data: " + json.dumps(data, separators=(",", ":")).encode("utf-8"))
                continue

            if event_type == "content_block_stop":
                idx = data.get("index", 0)
                stripper = get_stripper(idx)
                tail = stripper.flush()

                if tail:
                    synthetic = {
                        "type": "content_block_delta",
                        "index": idx,
                        "delta": {"type": "text_delta", "text": tail},
                    }
                    prefix_events += (
                        b"event: content_block_delta\n"
                        + b"data: "
                        + json.dumps(synthetic, separators=(",", ":")).encode("utf-8")
                        + b"\n\n"
                    )

                out_lines.append(line)
                continue

            out_lines.append(line)

        return prefix_events + b"\n".join(out_lines) + b"\n\n"

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
            response_ct = ""

            for key, value in response_headers:
                lk = key.lower()

                if lk == "content-type":
                    response_ct = value

                if lk in {
                    "connection",
                    "proxy-connection",
                    "keep-alive",
                    "transfer-encoding",
                    "content-length",
                }:
                    continue

                self.send_header(key, value)

            self.send_header("Connection", "close")
            self.end_headers()

            is_sse = "text/event-stream" in response_ct.lower()
            should_rewrite = self._is_messages_path()

            if should_rewrite and is_sse:
                self._stream_strip(resp)
                return

            if should_rewrite and "application/json" in response_ct.lower():
                # Buffer the whole body, strip <think> from text blocks, re-emit.
                raw = b""

                while True:
                    try:
                        chunk = resp.read(8192)
                    except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
                        break

                    if not chunk:
                        break

                    raw += chunk

                rewritten = raw

                try:
                    obj = json.loads(raw.decode("utf-8"))
                    obj = _strip_think_in_obj(obj)
                    rewritten = json.dumps(obj, separators=(",", ":")).encode("utf-8")
                except Exception:
                    pass

                try:
                    self.wfile.write(rewritten)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass

                return

            # Plain pass-through for everything else.
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
            self._send_plain(504, f"Proxy timeout while waiting for upstream {TARGET_HOST}:{TARGET_PORT}.")
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
        if self.path in {"/", "/health", "/healthz"}:
            body = json.dumps(
                {
                    "status": "ok",
                    "target_host": TARGET_HOST,
                    "target_port": TARGET_PORT,
                    "target": f"{TARGET_HOST}:{TARGET_PORT}",
                },
                separators=(",", ":"),
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()

            try:
                self.wfile.write(body)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass
            return

        self._forward("GET")

    def do_POST(self):
        self._forward("POST")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Connection", "close")
        self.end_headers()


def _parse_target(spec):
    """Accept 'host:port' or bare 'port' (uses 127.0.0.1)."""
    if ":" in spec:
        host, port_str = spec.rsplit(":", 1)
        return host or "127.0.0.1", int(port_str)

    return "127.0.0.1", int(spec)


def main():
    global TARGET_HOST, TARGET_PORT

    # --version is parsed before any other arg so the launcher can detect a
    # stale deployment without launching the server.
    if len(sys.argv) > 1 and sys.argv[1] in ("--version", "-V"):
        print(__version__)
        return

    listen_port = (
        int(sys.argv[1])
        if len(sys.argv) > 1
        else int(os.environ.get("NO_THINK_PROXY_LISTEN_PORT", "11435"))
    )

    target_spec = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.environ.get("NO_THINK_PROXY_TARGET", "127.0.0.1:11434")
    )

    TARGET_HOST, TARGET_PORT = _parse_target(target_spec)

    server = ThreadingHTTPServer(("127.0.0.1", listen_port), ProxyHandler)
    server.daemon_threads = True

    print(
        f"no-think-proxy: 127.0.0.1:{listen_port} -> {TARGET_HOST}:{TARGET_PORT}",
        flush=True,
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nno-think-proxy: stopped", flush=True)


if __name__ == "__main__":
    main()
