"""Private per-user TLS identity for Yap's loopback speech backend.

The client pins the self-signed certificate (by exact DER bytes) during the
TLS handshake BEFORE sending HTTP headers or selected text. A listener that
rebinds the port after /verify cannot impersonate the backend without the
private key. The key and certificate live under the same 0700 app-support
directory as auth-token. Same-user malware remains outside this boundary.
"""
from __future__ import annotations

import os
import shutil
import ssl
import stat
import subprocess
import tempfile
import time
from pathlib import Path


def identity_paths(token_file: Path) -> tuple[Path, Path]:
    parent = token_file.parent
    return parent / "backend-tls-cert.pem", parent / "backend-tls-key.pem"


def _private_file(path: Path) -> bool:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    return (
        stat.S_ISREG(info.st_mode)
        and info.st_uid == os.geteuid()
        and (info.st_mode & 0o077) == 0
    )


def ensure_identity(token_file: Path) -> tuple[Path, Path]:
    """Get/create a private certificate and key; otherwise fail closed.

    Never follow symlinks or replace an existing identity. Two first-launch
    backends may race; the second waits briefly for the first to finish.
    """
    token_file = Path(token_file)
    parent = token_file.parent
    info = parent.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise RuntimeError("Yap TLS identity directory is not user-owned")
    if info.st_mode & 0o077:
        raise RuntimeError("Yap TLS identity directory must be private (0700)")

    cert, key = identity_paths(token_file)

    def ready() -> bool:
        if not (_private_file(cert) and _private_file(key)):
            return False
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        try:
            context.load_cert_chain(certfile=str(cert), keyfile=str(key))
        except (OSError, ssl.SSLError):
            # During a competing first launch, the key may be published just
            # before the cert. Never confuse an incomplete/mismatched pair with
            # an authenticated listener, and never abort a waiting contender.
            return False
        return True

    def wait_for_ready() -> tuple[Path, Path]:
        # Concurrent first launches can create the private key and
        # certificate in separate atomic steps. Give the winner time to
        # finish instead of making the losing startup fail spuriously.
        for _ in range(40):
            if ready():
                return cert, key
            time.sleep(0.1)
        raise RuntimeError("Yap TLS identity is incomplete or unsafe")

    if cert.exists() or key.exists() or cert.is_symlink() or key.is_symlink():
        return wait_for_ready()

    tmp = Path(tempfile.mkdtemp(prefix=".yap-tls-", dir=parent))
    try:
        tmp_cert, tmp_key = tmp / "cert.pem", tmp / "key.pem"
        # Apple's /usr/bin/openssl ships with macOS; do not download a TLS
        # executable or install an unpinned certificate-generation dependency.
        subprocess.run(
            ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048",
             "-nodes", "-days", "3650", "-subj", "/CN=127.0.0.1",
             "-addext", "subjectAltName=IP:127.0.0.1",
             "-addext", "extendedKeyUsage=serverAuth",
             "-keyout", str(tmp_key), "-out", str(tmp_cert)],
            check=True, timeout=30, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        os.chmod(tmp_key, 0o600)
        os.chmod(tmp_cert, 0o600)
        if not (_private_file(tmp_cert) and _private_file(tmp_key)):
            raise RuntimeError("New Yap TLS identity is not private")
        # Atomic no-overwrite publication; os.link refuses a destination that
        # already exists, including a malicious symlink.
        try:
            os.link(tmp_key, key)
        except FileExistsError:
            # The other backend has already published its key; don't try to
            # replace it. Wait until its certificate is published and valid.
            return wait_for_ready()
        try:
            os.link(tmp_cert, cert)
        except FileExistsError:
            # No overwrite. If another launch published a matching identity,
            # use it; otherwise refuse to start rather than mixing key pairs.
            return wait_for_ready()
        return wait_for_ready()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
