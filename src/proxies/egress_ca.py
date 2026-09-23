"""Per-job certificate authority for intercepting registry TLS in the egress proxy.

Package registries are allowlisted, but they also serve *newer releases of the
task's own package* — the fix, in a tarball. A CONNECT tunnel is opaque, so the
proxy terminates TLS for registry hosts itself: it presents a leaf certificate
for the requested host signed by this CA, reads the HTTP request, applies the
per-trial package denylist, and only then opens a real TLS connection upstream.

The CA lives on tmpfs for the lifetime of one host process (Slurm job) and is
trusted inside the sandbox through a CA bundle (system roots + this CA) that the
enroot backend installs and points every client at (``SSL_CERT_FILE``,
``REQUESTS_CA_BUNDLE``, ``PIP_CERT``, ``NODE_EXTRA_CA_CERTS``, ``CARGO_HTTP_CAINFO``,
``GIT_SSL_CAINFO``, ``CURL_CA_BUNDLE``). A client that drops the bundle simply
fails TLS to the proxy — fail closed.
"""
from __future__ import annotations

import datetime as dt
import ipaddress
import ssl
import threading
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

LEAF_DAYS = 7
CA_DAYS = 30


def client_tls_context(cafile: str | None = None) -> ssl.SSLContext:
    """Verifying client context with an explicit TLS 1.2 floor (used for every
    upstream connection the proxy opens and for the CA's own trust context)."""
    ctx = ssl.create_default_context(cafile=cafile)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx


class EgressCA:
    def __init__(self, directory: Path, common_name: str = "SWE-Together egress sandbox CA") -> None:
        self.dir = Path(directory)
        self.dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.ca_pem = self.dir / "ca.pem"
        self._key_path = self.dir / "ca.key"
        self._contexts: dict[str, ssl.SSLContext] = {}
        self._lock = threading.Lock()
        if self.ca_pem.exists() and self._key_path.exists():
            self._key = serialization.load_pem_private_key(self._key_path.read_bytes(), password=None)
            self._cert = x509.load_pem_x509_certificate(self.ca_pem.read_bytes())
        else:
            self._key, self._cert = self._make_ca(common_name)
            self._key_path.write_bytes(self._key.private_bytes(
                serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            self._key_path.chmod(0o600)
            self.ca_pem.write_bytes(self._cert.public_bytes(serialization.Encoding.PEM))

    @staticmethod
    def _make_ca(common_name: str):
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
        now = dt.datetime.now(dt.timezone.utc)
        cert = (
            x509.CertificateBuilder()
            .subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - dt.timedelta(minutes=5))
            .not_valid_after(now + dt.timedelta(days=CA_DAYS))
            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
            .add_extension(x509.KeyUsage(digital_signature=True, key_cert_sign=True, crl_sign=True,
                                         content_commitment=False, key_encipherment=False, data_encipherment=False,
                                         key_agreement=False, encipher_only=False, decipher_only=False), critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
            .sign(key, hashes.SHA256())
        )
        return key, cert

    def _leaf(self, hostname: str) -> tuple[bytes, bytes]:
        key = ec.generate_private_key(ec.SECP256R1())
        now = dt.datetime.now(dt.timezone.utc)
        try:
            san: x509.GeneralName = x509.IPAddress(ipaddress.ip_address(hostname))
        except ValueError:
            san = x509.DNSName(hostname)
        cert = (
            x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, hostname[:64])]))
            .issuer_name(self._cert.subject).public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - dt.timedelta(minutes=5))
            .not_valid_after(now + dt.timedelta(days=LEAF_DAYS))
            .add_extension(x509.SubjectAlternativeName([san]), critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(self._key.public_key()), critical=False)
            .sign(self._key, hashes.SHA256())
        )
        return (cert.public_bytes(serialization.Encoding.PEM) + self._cert.public_bytes(serialization.Encoding.PEM),
                key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))

    def server_context(self, hostname: str) -> ssl.SSLContext:
        """A server-side TLS context presenting a leaf for ``hostname`` (cached)."""
        host = hostname.lower()
        with self._lock:
            ctx = self._contexts.get(host)
            if ctx is not None:
                return ctx
            chain, key = self._leaf(host)
            cert_path = self.dir / f"leaf-{host}.pem"
            key_path = self.dir / f"leaf-{host}.key"
            cert_path.write_bytes(chain)
            key_path.write_bytes(key)
            key_path.chmod(0o600)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            ctx.load_cert_chain(str(cert_path), str(key_path))
            self._contexts[host] = ctx
            return ctx

    def client_context(self) -> ssl.SSLContext:
        """A client context that trusts only this CA (tests / self-checks)."""
        return client_tls_context(str(self.ca_pem))
