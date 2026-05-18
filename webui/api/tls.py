"""
Self-signed TLS cert generation + SSL context for the webui.

Why this exists: browsers refuse `navigator.mediaDevices.getUserMedia()`
on plain HTTP for any origin that isn't `localhost` / `127.0.0.1`. The
voice tab's mic capture therefore fails when the webui is accessed from
a phone or another host on the LAN over HTTP. Wrapping the server with
TLS — even a self-signed cert — moves the origin into a "secure context"
and the mic permission flow works normally.

Storage layout:
    ~/.hermes/webui-tls/cert.pem
    ~/.hermes/webui-tls/key.pem

The cert is regenerated when missing or expired. Subject Alternative
Names include `localhost`, `127.0.0.1`, `::1`, every IPv4 address bound
to a local interface at generation time, and `0.0.0.0` (for the
default-bind case). That keeps a single cert valid for both
`https://localhost:PORT` on the host and `https://<lan-ip>:PORT` from
other devices.

Browsers will still show "Not Private" the first time because the cert
is self-signed (no CA chain). Tap Advanced → Proceed once and the
session caches the exception until the cert rotates.
"""

from __future__ import annotations

import datetime
import ipaddress
import os
import socket
import ssl
from pathlib import Path
from typing import List, Optional, Tuple


_DEFAULT_TLS_DIR = Path.home() / ".hermes" / "webui-tls"
_CERT_VALID_DAYS = 825   # max Apple/iOS will accept for a cert chain
_CERT_FILE = "cert.pem"
_KEY_FILE = "key.pem"


def _collect_local_ipv4s() -> List[str]:
    """Best-effort enumeration of local IPv4 addresses to bake into SANs.

    Picks up loopback, LAN, Hyper-V virtual switches, Tailscale, WireGuard,
    Docker bridges — anything bound to an interface on this host. The user
    can then access `https://<any-of-them>:PORT` without a hostname mismatch.
    """
    ips: set[str] = {"127.0.0.1"}
    try:
        # The egress IP — the one Linux/Windows would use for outbound TCP.
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            ips.add(s.getsockname()[0])
        finally:
            s.close()
    except Exception:
        pass
    try:
        # All addresses for the hostname (catches multi-homed setups)
        for info in socket.getaddrinfo(socket.gethostname(), None, family=socket.AF_INET):
            ip = info[4][0]
            ips.add(ip)
    except Exception:
        pass
    return sorted(ips)


def _build_san(ips: List[str]):
    """Build the X.509 SubjectAlternativeName list as cryptography expects."""
    from cryptography import x509
    from cryptography.x509.oid import NameOID  # noqa: F401  (imported for symmetry)

    entries: list = [
        x509.DNSName("localhost"),
        x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
        x509.IPAddress(ipaddress.ip_address("::1")),
    ]
    seen_ips: set[str] = {"127.0.0.1", "::1"}
    for raw_ip in ips:
        if raw_ip in seen_ips:
            continue
        try:
            addr = ipaddress.ip_address(raw_ip)
        except ValueError:
            continue
        entries.append(x509.IPAddress(addr))
        seen_ips.add(raw_ip)
    return x509.SubjectAlternativeName(entries)


def _generate_cert(cert_path: Path, key_path: Path, ips: List[str]) -> None:
    """Generate a self-signed 4096-bit RSA cert + key, write both files atomically.

    File modes: 0600 on the private key, 0644 on the cert.
    """
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=4096)
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "hermes-webui-self-signed"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Hermes WebUI (local)"),
    ])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(days=_CERT_VALID_DAYS))
        .add_extension(_build_san(ips), critical=False)
        .add_extension(
            x509.BasicConstraints(ca=False, path_length=None), critical=True,
        )
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=True,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]),
            critical=False,
        )
        .sign(private_key=key, algorithm=hashes.SHA256())
    )

    # Write atomically — temp file + replace — so a concurrent read never
    # sees a half-written PEM.
    cert_tmp = cert_path.with_suffix(cert_path.suffix + ".tmp")
    key_tmp = key_path.with_suffix(key_path.suffix + ".tmp")
    cert_path.parent.mkdir(parents=True, exist_ok=True)

    cert_tmp.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_tmp.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    try:
        os.chmod(key_tmp, 0o600)
    except Exception:
        # Windows chmod is a no-op for granular perms; the file inherits
        # the ACL of its parent dir. The ~/.hermes tree is already user-only
        # on Hermes-managed setups.
        pass
    cert_tmp.replace(cert_path)
    key_tmp.replace(key_path)


def _cert_is_valid(cert_path: Path) -> bool:
    """Return True if the existing cert is parseable and not expired."""
    if not cert_path.exists():
        return False
    try:
        from cryptography import x509
        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        now = datetime.datetime.now(datetime.timezone.utc)
        # Accept any cert whose not_valid_after_utc is in the future.
        # not_valid_after_utc is the modern attr; not_valid_after is the
        # naive-aware (now deprecated) one.
        not_after = getattr(cert, "not_valid_after_utc", None) or cert.not_valid_after.replace(
            tzinfo=datetime.timezone.utc
        )
        return not_after > now
    except Exception:
        return False


def ensure_self_signed_cert(
    cert_dir: Optional[Path] = None,
    force: bool = False,
) -> Tuple[Path, Path]:
    """Return (cert_path, key_path), generating them if missing or expired.

    If both files exist and the cert is still valid, this is a no-op
    (~1 ms). Otherwise generates a fresh 4096-bit RSA cert in `cert_dir`
    (default ~/.hermes/webui-tls/).
    """
    dirp = Path(cert_dir) if cert_dir else _DEFAULT_TLS_DIR
    cert_path = dirp / _CERT_FILE
    key_path = dirp / _KEY_FILE
    if not force and cert_path.exists() and key_path.exists() and _cert_is_valid(cert_path):
        return cert_path, key_path
    ips = _collect_local_ipv4s()
    _generate_cert(cert_path, key_path, ips)
    return cert_path, key_path


def build_ssl_context(cert_path: Path, key_path: Path) -> ssl.SSLContext:
    """Create an SSLContext configured for serving HTTPS with the given cert."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    # No client cert verification — this is a single-user dev/LAN server.
    ctx.verify_mode = ssl.CERT_NONE
    ctx.load_cert_chain(certfile=str(cert_path), keyfile=str(key_path))
    return ctx


def cert_fingerprint_sha256(cert_path: Path) -> str:
    """Return the cert's SHA-256 fingerprint in colon-separated hex.

    Useful for the startup banner — lets the user verify the cert hasn't
    rotated unexpectedly between runs.
    """
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes
        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        fp = cert.fingerprint(hashes.SHA256())
        return ":".join(f"{b:02X}" for b in fp)
    except Exception:
        return "(unavailable)"
