#!/usr/bin/env python3
"""Publish an atomic SPIFFE Bundle Map from one local SPIRE server's bundle API."""
import argparse
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OWN_DOMAIN = "east.example.test"
SERVER = ["/opt/spire/bin/spire-server"]


def spire(context, *args):
    return subprocess.run(
        ["kubectl", "--context", context, "-n", "spire", "exec", "spire-server-0", "-c", "spire-server", "--", *SERVER, *args],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout


def bundle(raw):
    value = json.loads(raw)
    if not isinstance(value, dict) or not isinstance(value.get("keys"), list):
        raise ValueError("SPIRE returned an invalid SPIFFE bundle")
    return value


def current_map(context):
    own = bundle(spire(context, "bundle", "show", "-format", "spiffe"))
    listed = json.loads(spire(context, "bundle", "list", "-output", "json"))
    records = listed.get("bundles") if isinstance(listed, dict) else None
    if not isinstance(records, list):
        raise ValueError("SPIRE bundle list response has no bundles array")
    domains = {record.get("trustDomain", record.get("trust_domain")) for record in records if isinstance(record, dict)}
    domains.discard(None)
    if any(not isinstance(domain, str) or not domain for domain in domains):
        raise ValueError("SPIRE returned an invalid trust domain")
    trust_domains = {OWN_DOMAIN: own}
    for domain in sorted(domains - {OWN_DOMAIN}):
        trust_domains[domain] = bundle(spire(context, "bundle", "list", "-id", domain, "-format", "spiffe"))
    return {"trust_domains": trust_domains}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--context")
    parser.add_argument("--cert")
    parser.add_argument("--key")
    parser.add_argument("--port", type=int, default=9443)
    args = parser.parse_args()
    if not args.context or not args.cert or not args.key:
        parser.error("--context, --cert, and --key are required")
    published = Path(__file__).with_name(".runtime") / "bundle-map.json"
    failure = None
    last_success = 0.0

    def refresh():
        nonlocal failure, last_success
        while True:
            try:
                content = json.dumps(current_map(args.context), separators=(",", ":")).encode()
                with tempfile.NamedTemporaryFile(dir=published.parent, delete=False) as temp:
                    temp.write(content)
                    temp.flush()
                    os.fsync(temp.fileno())
                    name = temp.name
                os.replace(name, published)
                failure = None
                last_success = time.monotonic()
            except Exception as error:  # Keep the last complete map during local SPIRE/API outages.
                failure = str(error)
            time.sleep(2)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/bundle":
                self.send_error(404)
                return
            if not published.exists() or time.monotonic() - last_success > 15:
                self.send_error(503, failure or "SPIRE bundle map is stale or not ready")
                return
            content = published.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        def log_message(self, fmt, *values):
            pass

    thread = threading.Thread(target=refresh, daemon=True)
    thread.start()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(args.cert, args.key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
