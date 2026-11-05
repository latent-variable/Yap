"""Local HTTPS listener identity: reject symlink/private-key attacks."""
import os
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
    assert key.read_bytes().startswith(b"-----BEGIN PRIVATE KEY-----")
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
