#!/usr/bin/env python3
"""Serve web/ over HTTPS so iOS Safari will hand out motion events.

DeviceMotionEvent.requestPermission() only works in a secure context, and
`localhost` is not secure when the page is opened from the phone. This starts a
TLS server on the LAN with a self-signed certificate (generated on first run
into .certs/, which stays out of the repo).

    python3 scripts/serve.py            # https://<lan-ip>:8443

Safari will warn about the certificate: "Show details" -> "visit this website".
After accepting once, motion permission works. If your phone and Mac are on
different networks, use a tunnel (ngrok / cloudflared) against port 8443 instead.
"""

from __future__ import annotations

import argparse
import http.server
import socket
import ssl
import subprocess
import sys
from functools import partial
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "web"
CERTS = ROOT / ".certs"


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))          # no packets sent, just picks the route
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def ensure_cert() -> tuple[Path, Path]:
    CERTS.mkdir(exist_ok=True)
    key, crt = CERTS / "dev.key", CERTS / "dev.crt"
    if key.exists() and crt.exists():
        return key, crt
    ip = lan_ip()
    print(f"generating self-signed certificate for {ip} ...")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(key), "-out", str(crt), "-days", "365",
         "-subj", "/CN=repper-dev",
         "-addext", f"subjectAltName=IP:{ip},IP:127.0.0.1,DNS:localhost"],
        check=True, capture_output=True,
    )
    return key, crt


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8443)
    args = ap.parse_args()

    if not WEB.exists():
        sys.exit(f"missing {WEB}")
    key, crt = ensure_cert()

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, key)

    handler = partial(http.server.SimpleHTTPRequestHandler, directory=str(WEB))
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", args.port), handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    print(f"\n  https://{lan_ip()}:{args.port}   <- open this on the phone")
    print(f"  https://localhost:{args.port}\n  Ctrl-C to stop")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
