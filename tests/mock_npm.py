#!/usr/bin/env python3
"""NPM finto (solo le rotte usate da npm-init/setup.sh).

uso: mock_npm.py STATE_DIR SERVER_PROXY_CONF
  scrive la porta in STATE_DIR/port e ogni richiesta in STATE_DIR/requests.log (JSON per riga).
  Interruttori (file in STATE_DIR):
    le_fail        la richiesta di un certificato Let's Encrypt fallisce (HTTP 400)
    upload_fail    l'upload di cert/key di un certificato fallisce (HTTP 400)
    reject_global  come NPM, salva comunque l'host ma lo segna meta.nginx_online=false se, in quel
                   momento, SERVER_PROXY_CONF contiene il blocco CrowdSec ("crowdsec-auth")
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = sys.argv[1]
CONF = sys.argv[2]
certs, hosts = [], []


def flag(name):
    return os.path.exists(os.path.join(STATE, name))


def nginx_status():
    if flag("reject_global") and os.path.exists(CONF) and "crowdsec-auth" in open(CONF).read():
        return False, "nginx: [emerg] duplicate location \"/crowdsec-auth\""
    return True, None


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw) if raw and "json" in (self.headers.get("Content-Type") or "") else None
        except ValueError:
            return None

    def record(self, b):
        with open(os.path.join(STATE, "requests.log"), "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "body": b}) + "\n")

    def do_GET(self):
        self.record(None)
        p = self.path.split("?")[0]
        if p in ("/api/", "/api"):
            return self.reply(200, {"status": "OK"})
        if p == "/api/nginx/certificates":
            return self.reply(200, certs)
        if p == "/api/nginx/proxy-hosts":
            return self.reply(200, hosts)
        m = re.fullmatch(r"/api/nginx/proxy-hosts/(\d+)", p)
        if m:
            for h in hosts:
                if h["id"] == int(m.group(1)):
                    return self.reply(200, h)
        self.reply(404, {"error": {"message": "not found"}})

    def do_POST(self):
        b = self.body()
        self.record(b)
        p = self.path.split("?")[0]
        if p == "/api/tokens":
            return self.reply(200, {"token": "tok", "expires": "2099-01-01"})
        if p == "/api/nginx/certificates":
            if b.get("provider") == "letsencrypt" and flag("le_fail"):
                return self.reply(400, {"error": {"code": 400, "message": "Some challenges have failed."}})
            c = dict(b, id=len(certs) + 1)
            if b.get("provider") == "letsencrypt":
                c["nice_name"] = ", ".join(b["domain_names"])
            certs.append(c)
            return self.reply(201, c)
        if re.fullmatch(r"/api/nginx/certificates/\d+/upload", p):
            if flag("upload_fail"):
                return self.reply(400, {"error": {"code": 400, "message": "upload failed"}})
            return self.reply(200, {"certificate": "x", "certificate_key": "y"})
        if p == "/api/nginx/proxy-hosts":
            online, err = nginx_status()
            h = dict(b, id=len(hosts) + 1, meta={"nginx_online": online, "nginx_err": err})
            hosts.append(h)
            return self.reply(201, dict(h, meta={}))
        self.reply(404, {"error": {"message": "not found"}})

    def do_PUT(self):
        b = self.body()
        self.record(b)
        m = re.fullmatch(r"/api/nginx/proxy-hosts/(\d+)", self.path.split("?")[0])
        if m:
            for i, h in enumerate(hosts):
                if h["id"] == int(m.group(1)):
                    online, err = nginx_status()
                    hosts[i] = dict(b, id=h["id"], meta={"nginx_online": online, "nginx_err": err})
                    return self.reply(200, dict(hosts[i], meta={}))
        self.reply(404, {"error": {"message": "not found"}})


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(STATE, "port"), "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
