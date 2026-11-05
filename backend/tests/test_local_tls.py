"""Local HTTPS listener identity: reject symlink/private-key attacks."""
import os
import shutil
from concurrent.futures import ThreadPoolExecutor
import threading
import ssl
import stat
import subprocess

import pytest

from local_tls import ensure_identity, identity_paths


def test_identity_created_private_and_usable(tmp_path):
    tmp_path.chmod(0o700)
    token = tmp_path / "auth-token"
    token.write_text("test-secret")
    cert, key = ensure_identity(token)
    assert cert == tmp_path / "backend-tls-cert.pem"
    assert key == tmp_path / "backend-tls-key.pem"
    assert stat.S_IMODE(cert.stat().st_mode) == 0o600
    assert stat.S_IMODE(key.stat().st_mode) == 0o600
    assert cert.read_bytes().startswith(b"-----BEGIN CERTIFICATE-----")
    assert b"PRIVATE KEY-----" in key.read_bytes().splitlines()[0]
    assert ensure_identity(token) == (cert, key)  # identity persists
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(str(cert), str(key))
    san = subprocess.check_output(
        ["/usr/bin/openssl", "x509", "-in", str(cert), "-noout", "-ext", "subjectAltName"],
        text=True,
    )
    assert "IP Address:127.0.0.1" in san


def test_identity_fails_closed_on_symlink_private_key(tmp_path):
    tmp_path.chmod(0o700)
    victim = tmp_path / "other"
    victim.write_text("private")
    _, key = identity_paths(tmp_path / "auth-token")
    key.symlink_to(victim)
    with pytest.raises(RuntimeError):
        ensure_identity(tmp_path / "auth-token")
    assert victim.read_text() == "private"


def test_identity_rejects_public_directory(tmp_path):
    tmp_path.chmod(0o755)
    with pytest.raises(RuntimeError, match="private"):
        ensure_identity(tmp_path / "auth-token")


def test_identity_refuses_preexisting_unrelated_certificate(tmp_path):
    tmp_path.chmod(0o700)
    cert, _ = identity_paths(tmp_path / "auth-token")
    cert.write_text("not a certificate")
    cert.chmod(0o600)
    with pytest.raises(RuntimeError, match="incomplete or unsafe"):
        ensure_identity(tmp_path / "auth-token")
    assert cert.read_text() == "not a certificate"


def test_concurrent_first_launch_reuses_one_private_tls_identity(tmp_path):
    tmp_path.chmod(0o700)
    token = tmp_path / "auth-token"
    token.write_text("test-secret")
    barrier = threading.Barrier(2)

    def launch():
        barrier.wait(timeout=10)
        return ensure_identity(token)

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(launch) for _ in range(2)]
        results = [future.result(timeout=25) for future in futures]

    assert results[0] == results[1]
    cert, key = results[0]
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(cert), str(key))
    assert stat.S_IMODE(key.stat().st_mode) == 0o600


def test_mismatched_certificate_and_key_fails_closed(tmp_path):
    first = tmp_path / "first"
    second = tmp_path / "second"
    mixed = tmp_path / "mixed"
    for d in (first, second, mixed):
        d.mkdir(mode=0o700)
    cert_a, _ = ensure_identity(first / "auth-token")
    _, key_b = ensure_identity(second / "auth-token")
    cert, key = identity_paths(mixed / "auth-token")
    shutil.copyfile(cert_a, cert)
    shutil.copyfile(key_b, key)
    cert.chmod(0o600)
    key.chmod(0o600)
    with pytest.raises(RuntimeError, match="incomplete or unsafe"):
        ensure_identity(mixed / "auth-token")
