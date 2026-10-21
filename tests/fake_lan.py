"""Fake LAN for tests: a TCP 'dish', an HTML page (like the dish's own router), a JNAP router that needs no
auth and one that needs auth. Every server binds a free port chosen by the OS, so several test runs can share
one computer; the ports are written to the file given as argv[1] (shell syntax) once all servers listen."""
import json, os, socket, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def dish(s):
    while True:
        c, _ = s.accept(); c.close()

class Html(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(b"<html><body>router</body></html>")
    log_message = lambda *a: None

class Jnap(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        act = self.headers.get("X-JNAP-Action", "").rsplit("/", 1)[-1]
        out = {"GetDeviceInfo": {"modelNumber": "EA0000", "hardwareVersion": "1", "firmwareVersion": "0.0.0.0", "services": []},
               "GetWANStatus": {"wanStatus": "Connected", "wanConnection": {"wanType": "DHCP", "ipAddress": "198.51.100.2"}},
               "GetNetworkConnections": {"connections": [{"macAddress": "02:00:00:00:00:01", "negotiatedMbps": 866,
                                                          "wireless": {"band": "5GHz", "signalDecibels": -61}}]},
               "GetDevices": {"devices": []}, "GetFirmwareUpdateSettings": {"updatePolicy": "AutomaticallyCheckAndInstall"}}
        if self.server.needs_auth and act != "GetDeviceInfo" and not self.headers.get("X-JNAP-Authorization"):
            body = {"result": "_ErrorUnauthorized"}
        else:
            body = {"result": "OK", "output": out[act]} if act in out else {"result": "_ErrorUnknownAction"}
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    log_message = lambda *a: None

d = socket.socket(); d.bind(("127.0.0.1", 0)); d.listen()
html_srv = ThreadingHTTPServer(("127.0.0.1", 0), Html)
open_srv = ThreadingHTTPServer(("127.0.0.1", 0), Jnap); open_srv.needs_auth = False
auth_srv = ThreadingHTTPServer(("127.0.0.1", 0), Jnap); auth_srv.needs_auth = True
threading.Thread(target=dish, args=(d,), daemon=True).start()
for srv in (html_srv, auth_srv):
    threading.Thread(target=srv.serve_forever, daemon=True).start()
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as f:
    f.write(f"P_DISH={d.getsockname()[1]}\nP_HTML={html_srv.server_port}\nP_OPEN={open_srv.server_port}\nP_AUTH={auth_srv.server_port}\n")
os.replace(tmp, sys.argv[1])   # appears complete or not at all
open_srv.serve_forever()
