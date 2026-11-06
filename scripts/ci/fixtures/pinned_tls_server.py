#!/usr/bin/env python3
"""Loopback TLS fixture for the real Swift BackendClient integration test.

Uses Yap's identity generator, serves only synthetic responses, and records
counts/leak booleans rather than tokens or request contents. The replacement
mode closes the genuine listening socket and binds an impostor on the SAME
port before it returns a genuine /verify proof on the existing connection.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import importlib.util
import io
import json
import os
from pathlib import Path
import ssl
import socketserver
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import time
from urllib.parse import parse_qs, urlsplit
import wave


class Audit:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        self.active_protected = 0
        self.values = dict(
            connections=0, trusted_connections=0, impostor_connections=0,
            verify_requests=0, protected_requests=0, authorization_headers=0,
            valid_authorization_headers=0, sensitive_bodies=0,
            impostor_http_requests=0, max_concurrent_protected=0,
            replacement_bound=False, certificates_differ=False,
        )
        self.save()

    def save(self):
        # Callers hold the lock; atomic replacement keeps readers from seeing
        # an incomplete snapshot while several TLS connections finish together.
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.values))
        os.replace(temporary, self.path)

    def connection(self, impostor: bool):
        with self.lock:
            self.values["connections"] += 1
            key = "impostor_connections" if impostor else "trusted_connections"
            self.values[key] += 1
            self.save()

    def request(self, *, verify: bool, protected: bool, impostor: bool,
                authorization: str | None, valid_authorization: bool, body: bytes):
        with self.lock:
            self.values["verify_requests"] += int(verify)
            self.values["protected_requests"] += int(protected)
            self.values["impostor_http_requests"] += int(impostor)
            self.values["authorization_headers"] += int(authorization is not None)
            self.values["valid_authorization_headers"] += int(valid_authorization)
            self.values["sensitive_bodies"] += int(b"YAP-TLS-PRIVATE-CANARY:" in body)
            if protected:
                self.active_protected += 1
                self.values["max_concurrent_protected"] = max(
                    self.values["max_concurrent_protected"], self.active_protected
                )
            self.save()

    def protected_finished(self):
        with self.lock:
            self.active_protected -= 1
            self.save()

    def mark(self, key: str):
        with self.lock:
            self.values[key] = True
            self.save()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True
    request_queue_size = 64

    def __init__(self, owner, port: int, impostor: bool):
        self.owner = owner
        self.impostor = impostor
        self.context = owner.wrong_context if impostor else owner.trusted_context
        super().__init__(("127.0.0.1", port), Handler)

    def server_bind(self):
        # HTTPServer.server_bind() does getfqdn(), which can block on runner
        # DNS for a loopback-only test. The HTTP fixture needs no host lookup.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        self.owner.audit.connection(self.impostor)
        # Handshake in the worker, so one rejected client cannot serialize
        # acceptance of the other concurrent URLSession connections.
        return self.context.wrap_socket(
            connection, server_side=True, do_handshake_on_connect=False
        ), address

    def finish_request(self, request, client_address):
        request.do_handshake()
        super().finish_request(request, client_address)

    def handle_error(self, request, client_address):
        # A rejected certificate normally ends in a TLS alert/reset. HTTP
        # counters are the assertion surface; do not log secrets or noisy alerts.
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def respond(self, status: int, body: bytes, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", content_type)
        # Force a new TLS handshake for the protected request. In replacement
        # mode the next connection can reach only the new impostor listener.
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        self.handle_http()

    def do_POST(self):
        self.handle_http()

    def handle_http(self):
        owner = self.server.owner
        parsed = urlsplit(self.path)
        verify = self.command == "GET" and parsed.path == "/verify"
        protected = self.command == "POST" and parsed.path == "/synthesize"
        length = int(self.headers.get("Content-Length", "0"))
        if length < 0 or length > 8192:
            self.respond(413, b"{}")
            return
        body = self.rfile.read(length)
        authorization = self.headers.get("Authorization")
        valid = authorization is not None and hmac.compare_digest(
            authorization, "Bearer " + owner.token
        )
        owner.audit.request(
            verify=verify, protected=protected, impostor=self.server.impostor,
            authorization=authorization, valid_authorization=valid, body=body,
        )
        if verify:
            nonce = parse_qs(parsed.query)["nonce"][0]
            proof = hmac.new(owner.token.encode(), nonce.encode(), hashlib.sha256).hexdigest()
            if owner.mode == "replace" and not self.server.impostor:
                owner.replace_listener(self.server)
            self.respond(200, json.dumps({"proof": proof}).encode())
        elif protected:
            try:
                # This bounded overlap makes concurrency an observed property,
                # not merely a count of tasks that may have run serially.
                time.sleep(0.1)
                self.respond(200 if valid else 401,
                             owner.wav if valid else b"{}", "audio/wav")
            finally:
                owner.audit.protected_finished()
        else:
            self.respond(404, b"{}")


class Fixture:
    def __init__(self, token_path: Path, state: Path, mode: str):
        self.mode = mode
        self.token = token_path.read_text().strip()
        self.audit = Audit(state / "snapshot.json")
        module_path = Path(__file__).resolve().parents[3] / "backend/local_tls.py"
        spec = importlib.util.spec_from_file_location("yap_fixture_local_tls", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cert, key = module.ensure_identity(token_path)
        wrong_dir = state / "impostor"
        wrong_dir.mkdir(mode=0o700)
        wrong_cert, wrong_key = module.ensure_identity(wrong_dir / "auth-token")
        assert cert.read_bytes() != wrong_cert.read_bytes()
        self.audit.mark("certificates_differ")

        def context(certificate: Path, private_key: Path):
            result = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            result.minimum_version = ssl.TLSVersion.TLSv1_2
            result.load_cert_chain(certificate, private_key)
            return result

        self.trusted_context = context(cert, key)
        self.wrong_context = context(wrong_cert, wrong_key)
        audio = io.BytesIO()
        with wave.open(audio, "wb") as wav:
            wav.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\0\0" * 240)
        self.wav = audio.getvalue()
        self.servers = []
        initial = self.start_server(0, mode == "wrong")
        (state / "ready.json").write_text(json.dumps({"port": initial.server_port}))

    def start_server(self, port: int, impostor: bool):
        server = Server(self, port, impostor)
        self.servers.append(server)
        threading.Thread(
            target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
        ).start()
        return server

    def replace_listener(self, original):
        port = original.server_port
        original.shutdown()
        original.server_close()
        replacement = self.start_server(port, True)
        assert replacement.server_port == port
        self.audit.mark("replacement_bound")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--mode", choices=("trusted", "wrong", "replace"), required=True)
    args = parser.parse_args()
    parent = os.getppid()
    Fixture(args.token_file, args.state_dir, args.mode)
    # Do not leave a listener behind if the isolated XCTest subprocess times
    # out or crashes before its ordinary cleanup runs.
    while os.getppid() == parent:
        time.sleep(0.25)


if __name__ == "__main__":
    main()
