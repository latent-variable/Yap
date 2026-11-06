"""Loopback auth: the sidecar must require a shared-secret Bearer token and
reject browser-originated requests, closing CSRF (a website driving the install
endpoint) and impostor-trust (Yap reusing a squatter) holes.

These exercise the middleware + /verify directly (no HTTP client needed), so
they run in the bundled runtime. The HTTP-level matrix against a live uvicorn
server is covered by the curl e2e in the PR description.

Run: cd backend && pytest tests/test_auth.py -v
"""
import asyncio
import hashlib
import hmac
import os
import ssl
import stat

import pytest
from fastapi import HTTPException
from starlette.requests import Request
from starlette.responses import PlainTextResponse

import server
from local_tls import ensure_identity

TOKEN = "unit-test-secret-token"


def _request(path="/health", headers=None):
    raw = [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()]
    scope = {"type": "http", "method": "GET", "path": path,
             "headers": raw, "query_string": b"", "scheme": "http",
             "server": ("127.0.0.1", 8766)}
    return Request(scope)


def _run_guard(request):
    async def call_next(_req):
        return PlainTextResponse("reached", status_code=200)
    return asyncio.run(server.auth_guard(request, call_next))


@pytest.fixture(autouse=True)
def _token(monkeypatch):
    monkeypatch.setattr(server, "AUTH_TOKEN", TOKEN)


def _auth(token=TOKEN):
    return {"Authorization": f"Bearer {token}"}


def test_health_requires_token():
    assert _run_guard(_request()).status_code == 401


def test_health_accepts_correct_token():
    assert _run_guard(_request(headers=_auth())).status_code == 200


def test_health_rejects_wrong_token():
    assert _run_guard(_request(headers=_auth("nope"))).status_code == 401


def test_non_ascii_token_returns_401_not_500():
    # Starlette decodes the header latin-1; a non-ASCII Bearer value must yield a
    # clean 401, not a compare_digest ValueError -> 500.
    r = _run_guard(_request(headers={"Authorization": "Bearer café-Ω-\xff"}))
    assert r.status_code == 401


def test_browser_origin_rejected_even_with_token():
    r = _run_guard(_request(headers={**_auth(), "Origin": "https://evil.example"}))
    assert r.status_code == 403


def test_sec_fetch_cross_site_rejected():
    r = _run_guard(_request(headers={**_auth(), "Sec-Fetch-Site": "cross-site"}))
    assert r.status_code == 403


def test_sec_fetch_same_origin_allowed():
    r = _run_guard(_request(headers={**_auth(), "Sec-Fetch-Site": "same-origin"}))
    assert r.status_code == 200


def test_install_endpoint_csrf_blocked_without_token():
    # The no-body POST a malicious page would fire to trigger a multi-GB pip run.
    assert _run_guard(_request(path="/engines/pocket/install")).status_code == 401


def test_missing_token_fails_closed_for_all_routes(monkeypatch):
    monkeypatch.setattr(server, "AUTH_TOKEN", None)
    assert _run_guard(_request(path="/health", headers=_auth())).status_code == 503
    assert _run_guard(_request(path="/engines/pocket/install", headers=_auth())).status_code == 503
    assert _run_guard(_request(path="/verify")).status_code == 503


def test_unwritable_token_path_never_creates_a_public_server(monkeypatch, tmp_path):
    blocker = tmp_path / "not-a-directory"
    blocker.write_text("blocker")
    monkeypatch.delenv("YAP_AUTH_TOKEN", raising=False)
    monkeypatch.setenv("YAP_AUTH_TOKEN_FILE", str(blocker / "auth-token"))
    assert server._load_or_create_token() is None


def test_auth_token_file_refuses_symlink(monkeypatch, tmp_path):
    target = tmp_path / "target"
    target.write_text("sensitive")
    link = tmp_path / "auth-token"
    link.symlink_to(target)
    monkeypatch.delenv("YAP_AUTH_TOKEN", raising=False)
    monkeypatch.setenv("YAP_AUTH_TOKEN_FILE", str(link))
    assert server._load_or_create_token() is None
    assert target.read_text() == "sensitive"


def test_fresh_standalone_auth_parent_supports_tls_under_normal_umask(monkeypatch, tmp_path):
    token_file = tmp_path / "fresh-profile" / "auth-token"
    monkeypatch.delenv("YAP_AUTH_TOKEN", raising=False)
    monkeypatch.setenv("YAP_AUTH_TOKEN_FILE", str(token_file))
    previous_umask = os.umask(0o022)
    try:
        token = server._load_or_create_token()
    finally:
        os.umask(previous_umask)
    assert token
    assert token_file.read_text() == token
    assert stat.S_IMODE(token_file.parent.stat().st_mode) == 0o700
    assert stat.S_IMODE(token_file.stat().st_mode) == 0o600
    cert, key = ensure_identity(token_file)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=str(cert), keyfile=str(key))


@pytest.mark.parametrize("mode", [0o755, 0o777])
def test_existing_unsafe_auth_parent_is_refused_without_changes(monkeypatch, tmp_path, mode):
    parent = tmp_path / "shared-parent"
    parent.mkdir(mode=mode)
    parent.chmod(mode)
    token_file = parent / "auth-token"
    token_file.write_text("existing-token")
    token_file.chmod(0o600)
    monkeypatch.delenv("YAP_AUTH_TOKEN", raising=False)
    monkeypatch.setenv("YAP_AUTH_TOKEN_FILE", str(token_file))
    assert server._load_or_create_token() is None
    assert stat.S_IMODE(parent.stat().st_mode) == mode
    assert token_file.read_text() == "existing-token"
    assert sorted(p.name for p in parent.iterdir()) == ["auth-token"]


def test_symlink_auth_parent_is_refused_without_creating_token(monkeypatch, tmp_path):
    target = tmp_path / "target-parent"
    target.mkdir(mode=0o700)
    parent = tmp_path / "linked-parent"
    parent.symlink_to(target, target_is_directory=True)
    monkeypatch.delenv("YAP_AUTH_TOKEN", raising=False)
    monkeypatch.setenv("YAP_AUTH_TOKEN_FILE", str(parent / "auth-token"))
    assert server._load_or_create_token() is None
    assert parent.is_symlink()
    assert list(target.iterdir()) == []


def test_foreign_owned_auth_parent_is_refused(monkeypatch, tmp_path):
    parent = tmp_path / "foreign-parent"
    parent.mkdir(mode=0o700)
    monkeypatch.delenv("YAP_AUTH_TOKEN", raising=False)
    monkeypatch.setenv("YAP_AUTH_TOKEN_FILE", str(parent / "auth-token"))
    monkeypatch.setattr(server.os, "geteuid", lambda: parent.stat().st_uid + 1)
    assert server._load_or_create_token() is None
    assert list(parent.iterdir()) == []


def test_verify_is_auth_exempt():
    # /verify must pass the guard WITHOUT a token (the app probes an untrusted
    # listener with no Authorization header).
    assert _run_guard(_request(path="/verify")).status_code == 200


def test_verify_blocks_browser_origin():
    # A website must not be able to fingerprint the backend via /verify: the
    # Origin guard runs before the /verify exemption.
    r = _run_guard(_request(path="/verify", headers={"Origin": "https://evil.example"}))
    assert r.status_code == 403


def test_verify_returns_correct_hmac():
    nonce = "challenge-nonce-xyz"
    expected = hmac.new(TOKEN.encode(), nonce.encode(), hashlib.sha256).hexdigest()
    assert server.verify(nonce=nonce)["proof"] == expected


def test_verify_requires_nonce():
    with pytest.raises(HTTPException) as ei:
        server.verify(nonce="")
    assert ei.value.status_code == 400


def test_verify_rejects_overlong_nonce():
    # /verify is auth-exempt; an enormous nonce must be refused (DoS bound),
    # not fed into HMAC.
    with pytest.raises(HTTPException) as ei:
        server.verify(nonce="x" * 129)
    assert ei.value.status_code == 400


def test_verify_proof_does_not_equal_token():
    # The proof is an HMAC, not the token itself.
    assert server.verify(nonce="abc")["proof"] != TOKEN
