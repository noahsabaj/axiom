#!/usr/bin/env python3
"""A local HTTPS server for trying Axiom's https on QEMU's user network.

    python tools/httpsd.py [--port 8443] [--dir DIR]

Serves DIR (default build/www, made with an index page and a 300 KB file,
big.bin, if missing) over TLS 1.3 only, on 127.0.0.1, with the test
certificate for axiom.test that tools/test/tlsclient/run.py makes (made
here too if it is not there yet). Axiom does not trust that test CA, so
`http https://10.0.2.2:8443/` is refused; booted with --nic rtl8139,
`http -k https://10.0.2.2:8443/` or `http -k https://10.0.2.2:8443/big.bin
big.bin` fetch without checking the certificate.
Each request is printed with the cipher it came over.
"""
import argparse
import functools
import hashlib
import http.server
import importlib.util
import pathlib
import random
import ssl

ROOT = pathlib.Path(__file__).resolve().parents[1]


def certs():
    d = ROOT / "build" / "test" / "tlsclient" / "certs"
    if not (d / "done2").exists():
        spec = importlib.util.spec_from_file_location(
            "tlsclient", ROOT / "tools" / "test" / "tlsclient" / "run.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.make_certs(d)
    return d / "rsa-chain.pem", d / "rsa.key"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8443)
    ap.add_argument("--dir", default=str(ROOT / "build" / "www"))
    opts = ap.parse_args()
    www = pathlib.Path(opts.dir)
    if not www.exists():
        www.mkdir(parents=True)
        (www / "index.html").write_text(
            "<!doctype html>\n<title>Axiom TLS test</title>\n"
            "<p>This page came to Axiom over TLS 1.3.</p>\n")
        (www / "big.bin").write_bytes(random.Random(1).randbytes(300000))
    for f in sorted(www.iterdir()):
        if f.is_file():
            print(f"{f.name}: {f.stat().st_size} bytes, sha256 "
                  f"{hashlib.sha256(f.read_bytes()).hexdigest()}")

    cert, key = certs()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(cert, key)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, fmt, *args):
            c = self.connection.cipher()
            print(f"{self.address_string()} {c[1]} {c[0]}: {fmt % args}", flush=True)

    httpd = http.server.ThreadingHTTPServer(
        ("127.0.0.1", opts.port), functools.partial(Handler, directory=str(www)))
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"https://127.0.0.1:{opts.port}/ (from QEMU: https://10.0.2.2:{opts.port}/)",
          flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
