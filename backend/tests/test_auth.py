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

import pytest
from fastapi import HTTPException
from starlette.requests import Request
from starlette.responses import PlainTextResponse

import server

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
    assert _run_guard(_request(path="/engines/chatterbox/install")).status_code == 401


def test_verify_is_auth_exempt():
    # /verify must pass the guard WITHOUT a token (the app probes an untrusted
    # listener with no Authorization header).
    assert _run_guard(_request(path="/verify")).status_code == 200


def test_verify_returns_correct_hmac():
    nonce = "challenge-nonce-xyz"
    expected = hmac.new(TOKEN.encode(), nonce.encode(), hashlib.sha256).hexdigest()
    assert server.verify(nonce=nonce)["proof"] == expected


def test_verify_requires_nonce():
    with pytest.raises(HTTPException) as ei:
        server.verify(nonce="")
    assert ei.value.status_code == 400


def test_verify_proof_does_not_equal_token():
    # The proof is an HMAC, not the token itself.
    assert server.verify(nonce="abc")["proof"] != TOKEN
