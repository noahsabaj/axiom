#!/usr/bin/env python3
"""A stand-in for the Claude Messages API, to try Axiom's 'ask' without an
account, on QEMU's user network.

    python tools/claudemock.py [--port 8444] [--key KEY] [--seed N]

Then in Axiom (booted with --nic rtl8139):

    claude server https://10.0.2.2:8444 -k
    claude key <KEY>
    ask anything

It speaks TLS 1.3 with the test certificate tools/test/tlsclient/run.py
makes (Axiom does not trust its CA, hence -k), checks each request the way
the real API would (POST /v1/messages, x-api-key, anthropic-version, the
JSON: model, max_tokens, stream, system, messages alternating from the
user's), and answers with server-sent events over HTTP/1.1 chunks, cut at
random places and sent in pieces, so that every layer of Axiom's reader
sees its input split anywhere: chunk sizes, event lines, JSON escapes,
UTF-8 sequences. What it answers depends on the last question:

    (anything)   echoes it, with Unicode that the console must map
    long         some 1500 words, for wrapping
    think        a thinking block first, which Axiom must not show
    overloaded   some words, then an error event
    cut          some words, then the connection dropped
    maxtokens    stop_reason max_tokens
    plain        not chunked: the body ends when the connection does
    badrequest   400, chunked
A wrong key gets 401. Each request is kept in MockServer.requests.
"""
import argparse
import json
import pathlib
import importlib.util
import random
import socket
import ssl
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
KEY = "sk-ant-mock-0123456789abcdefghijklmnopqrstuvwxyz"

UNICODE = ("Quotes ‘single’ and “double” — a dash… "
           "• a bullet → an arrow ✓ café, naïve, Zürich, "
           "10 °C, 5 µs, 3 × 4 ≈ 12 ≤ 13 ≥ 11. "
           "Emoji \U0001F600 and a \"quote\", a back\\slash, a tab\there.\n"
           "┌─┐\n└─┘\nThe end.")

WORDS = ("the quick brown fox jumps over a lazy dog while seven hardware threads "
         "watch an assembler build kernel pages from nothing but bytes and patience "
         "interrupts arrive packets leave caches warm and the console wraps each "
         "word where it fits").split()


def certs():
    d = ROOT / "build" / "test" / "tlsclient" / "certs"
    if not (d / "done2").exists():
        spec = importlib.util.spec_from_file_location(
            "tlsclient", ROOT / "tools" / "test" / "tlsclient" / "run.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.make_certs(d)
    return d / "rsa-chain.pem", d / "rsa.key"


def long_text(rng):
    paras = []
    for _ in range(12):
        paras.append(" ".join(rng.choice(WORDS) for _ in range(rng.randint(80, 150))) + ".")
    return "\n\n".join(paras)


class MockServer:
    def __init__(self, port=8444, key=KEY, seed=1):
        self.port = port
        self.key = key
        self.rng = random.Random(seed)
        self.requests = []          # (headers dict, body dict or None, problems)
        self.answers = []           # what each answer said, in full
        self.planned = []           # what each was to say
        cert, k = certs()
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        self.ctx.load_cert_chain(cert, k)
        self.sock = socket.create_server(("127.0.0.1", port))
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def serve(self):
        while True:
            try:
                raw, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.connection, args=(raw,), daemon=True).start()

    def close(self):
        self.sock.close()

    # -- one request --
    def connection(self, raw):
        raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        raw.settimeout(30)
        try:
            s = self.ctx.wrap_socket(raw, server_side=True)
        except (ssl.SSLError, OSError) as e:
            print(f"claudemock: handshake failed: {e}", flush=True)
            raw.close()
            return
        try:
            self.handle(s)
        except (OSError, ssl.SSLError) as e:
            print(f"claudemock: {e}", flush=True)
        finally:
            try:
                s.close()
            except OSError:
                pass

    def handle(self, s):
        data = b""
        while b"\r\n\r\n" not in data:
            got = s.recv(65536)
            if not got:
                return
            data += got
        head, _, body = data.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        method, path, version = lines[0].split(" ", 2)
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        n = int(headers.get("content-length", "0"))
        while len(body) < n:
            got = s.recv(65536)
            if not got:
                break
            body += got
        problems = []
        if method != "POST" or path != "/v1/messages" or version != "HTTP/1.1":
            problems.append(f"request line {lines[0]!r}")
        for name, want in (("anthropic-version", "2023-06-01"),
                           ("content-type", "application/json")):
            if headers.get(name) != want:
                problems.append(f"{name}: {headers.get(name)!r}")
        if "host" not in headers:
            problems.append("no Host")
        try:
            req = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as e:
            req = None
            problems.append(f"the body is not JSON: {e}")
        if req is not None:
            problems += self.check(req)
        self.requests.append((headers, req, problems, body))
        print(f"claudemock: {lines[0]}, {len(body)} B" +
              (f", problems: {problems}" if problems else ""), flush=True)
        if headers.get("x-api-key") != self.key:
            return self.error(s, 401, "authentication_error", "invalid x-api-key")
        if problems:
            return self.error(s, 400, "invalid_request_error", "mock: " + "; ".join(problems))
        if req["messages"][-1]["content"].strip().lower() == "badrequest":
            return self.error(s, 400, "invalid_request_error", "mock: asked for a 400")
        self.answer(s, req)

    def check(self, req):
        p = []
        if not isinstance(req.get("model"), str) or not req["model"]:
            p.append("no model")
        if not isinstance(req.get("max_tokens"), int) or req["max_tokens"] < 1:
            p.append("max_tokens")
        if req.get("stream") is not True:
            p.append("not streamed")
        if not isinstance(req.get("system"), str):
            p.append("no system prompt")
        msgs = req.get("messages")
        if not isinstance(msgs, list) or not msgs:
            p.append("no messages")
            return p
        for i, m in enumerate(msgs):
            want = "user" if i % 2 == 0 else "assistant"
            if m.get("role") != want or not isinstance(m.get("content"), str):
                p.append(f"message {i}: {m.get('role')!r}")
        if msgs[-1].get("role") != "user":
            p.append("the last message is not the user's")
        # what the assistant said before must come back exactly, or the
        # start of it if the client stopped listening
        for i, m in enumerate(msgs):
            c = m.get("content")
            if m.get("role") == "assistant" and c not in self.answers and \
                    not any(c and t.startswith(c) for t in self.planned):
                p.append(f"message {i}, an answer, came back changed")
        return p

    def error(self, s, status, kind, message):
        body = json.dumps({"type": "error", "error": {"type": kind, "message": message},
                           "request_id": "req_mock"}).encode()
        reason = {400: "Bad Request", 401: "Unauthorized"}.get(status, "Error")
        if status == 400:       # chunked, as it may well be
            s.sendall(f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\n"
                      f"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n".encode())
            self.chunks(s, body, final=True)
        else:
            s.sendall(f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\n"
                      f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body)

    def chunks(self, s, data, final=False):
        """data as HTTP/1.1 chunks of random sizes, each sent in random pieces"""
        rng = self.rng
        i = 0
        while i < len(data):
            n = min(len(data) - i, rng.choice([1, 2, 7, 30, 100, 300, 1000]))
            size = f"{n:x}" if rng.random() < 0.5 else f"{n:X}"
            ext = ";mock=1" if rng.random() < 0.1 else ""
            self.pieces(s, f"{size}{ext}\r\n".encode() + data[i:i + n] + b"\r\n")
            i += n
        if final:
            self.pieces(s, b"0\r\n\r\n")

    def pieces(self, s, b):
        rng = self.rng
        while b:
            n = rng.choice([1, 3, 9, 40, len(b)])
            s.sendall(b[:n])
            b = b[n:]
            if rng.random() < 0.05:
                time.sleep(0.01)

    def answer(self, s, req):
        rng = self.rng
        q = req["messages"][-1]["content"]
        n = len(req["messages"])
        word = q.strip().lower()
        text = {"long": long_text(rng)}.get(word, f"You asked: {q}\nThis is answer "
                                                  f"{n // 2 + 1}. {UNICODE}")
        self.planned.append(text)
        stop = "max_tokens" if word == "maxtokens" else "end_turn"
        chunked = word != "plain"
        s.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n" +
                  (b"Transfer-Encoding: chunked\r\n" if chunked else b"") +
                  b"request-id: req_mock\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n")

        def event(kind, obj):
            seps = (",", ":") if rng.random() < 0.5 else (", ", ": ")
            js = json.dumps(obj, ensure_ascii=rng.random() < 0.5, separators=seps)
            out = f"event: {kind}\ndata: {js}\n\n".encode()
            if chunked:
                self.chunks(s, out)
            else:
                self.pieces(s, out)

        event("message_start", {"type": "message_start", "message": {
            "id": "msg_mock", "type": "message", "role": "assistant", "model": req["model"],
            "content": [], "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": len(json.dumps(req)) // 4, "output_tokens": 1}}})
        index = 0
        if word == "think":
            event("content_block_start", {"type": "content_block_start", "index": 0,
                                          "content_block": {"type": "thinking", "thinking": ""}})
            event("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {
                "type": "thinking_delta", "thinking": "SECRET THOUGHTS, not to be shown"}})
            event("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {
                "type": "signature_delta", "signature": "c2lnbmF0dXJl"}})
            event("content_block_stop", {"type": "content_block_stop", "index": 0})
            index = 1
        event("content_block_start", {"type": "content_block_start", "index": index,
                                      "content_block": {"type": "text", "text": ""}})
        event("ping", {"type": "ping"})
        said = ""
        i = 0
        limit = len(text) if word not in ("overloaded", "cut") else 60
        while i < limit:
            k = min(limit - i, rng.randint(1, 8))
            piece = text[i:i + k]
            event("content_block_delta", {"type": "content_block_delta", "index": index,
                                          "delta": {"type": "text_delta", "text": piece}})
            said += piece
            i += k
        self.answers.append(said)
        if word == "cut":
            s.sendall(b"")
            s.shutdown(socket.SHUT_RDWR)      # no close_notify, no last chunk
            return
        if word == "overloaded":
            event("error", {"type": "error", "error": {"type": "overloaded_error",
                                                       "message": "Overloaded"}})
            if chunked:
                self.pieces(s, b"0\r\n\r\n")
            return
        event("content_block_stop", {"type": "content_block_stop", "index": index})
        event("message_delta", {"type": "message_delta",
                                "delta": {"stop_reason": stop, "stop_sequence": None},
                                "usage": {"output_tokens": len(text) // 4}})
        event("message_stop", {"type": "message_stop"})
        if chunked:
            self.pieces(s, b"0\r\n\r\n")
        try:                                  # Axiom hangs up now; read its close
            s.settimeout(2)
            s.recv(100)
        except (OSError, ssl.SSLError):
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8444)
    ap.add_argument("--key", default=KEY)
    ap.add_argument("--seed", type=int, default=1)
    opts = ap.parse_args()
    MockServer(opts.port, opts.key, opts.seed).start()
    print(f"claudemock: https://127.0.0.1:{opts.port}/v1/messages "
          f"(from QEMU: claude server https://10.0.2.2:{opts.port} -k), key {opts.key}",
          flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
