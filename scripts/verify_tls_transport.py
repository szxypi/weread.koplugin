#!/usr/bin/env python3
"""Local synthetic TLS acceptance through a real KOReader Client. No account.

Run inside the KOReader validation container under xvfb-run; requires openssl.
The temporary CA and leaf keys are synthetic and removed on exit. Failed TLS
must deliver zero HTTP requests (including the synthetic authorization header).
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading


def verify(runtime, repo):
    records = []
    with tempfile.TemporaryDirectory(prefix="weread-tls-") as directory:
        base = Path(directory)

        def openssl(*args):
            subprocess.run(["openssl", *args], cwd=base, check=True, capture_output=True, timeout=15)

        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem",
                "-days", "2", "-subj", "/CN=WeRead synthetic validation CA", "-addext", "basicConstraints=critical,CA:TRUE")
        for name, san, days in (("good", "DNS:localhost", "1"), ("wrong", "DNS:example.invalid", "1"),
                                ("expired", "DNS:localhost", "-1"), ("no-san", None, "1")):
            openssl("req", "-newkey", "rsa:2048", "-nodes", "-keyout", name+".key", "-out", name+".csr",
                    "-subj", "/CN=localhost")
            ext = "basicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
            if san:
                ext += "subjectAltName=" + san + "\n"
            (base / "leaf.ext").write_text(ext)
            openssl("x509", "-req", "-in", name+".csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
                    "-out", name+".pem", "-days", days, "-extfile", "leaf.ext")

        class Handler(BaseHTTPRequestHandler):
            requests = 0

            def do_GET(self):
                type(self).requests += 1
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"OK")

            def log_message(self, *_):
                pass

        for case, name, ca, expected in (("trusted", "good", str(base/"ca.pem"), True),
                                         ("untrusted", "good", "-", False),
                                         ("wrong_hostname", "wrong", str(base/"ca.pem"), False),
                                         ("expired", "expired", str(base/"ca.pem"), False),
                                         ("missing_san", "no-san", str(base/"ca.pem"), False)):
            Handler.requests = 0
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(base/(name+".pem"), base/(name+".key"))
            server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                result = subprocess.run([str(runtime/"luajit"), str(repo/"spec/koreader/tls_transport_probe.lua"),
                                         str(repo), f"https://localhost:{server.server_port}/", ca],
                                        cwd=runtime, capture_output=True, text=True, timeout=15)
                # Runtime logs are synthetic, but keep diagnostics bounded anyway.
                data = json.loads(result.stdout.splitlines()[-1]) if result.returncode == 0 else {}
                assert data.get("ok") is expected and Handler.requests == int(expected), "tls_acceptance_failed/" + case
                records.append(dict(case=case, passed=True, http_requests=Handler.requests))
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
    return dict(result="TLS_TRANSPORT_VERIFIED", cases=records, real_credentials_used=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    print(json.dumps(verify(args.koreader.resolve(), args.repo.resolve()), indent=2))


if __name__ == "__main__":
    main()
