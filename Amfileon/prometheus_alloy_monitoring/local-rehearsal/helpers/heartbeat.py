"""Fake healthchecks.io: expects a ping at least every GRACE seconds.

When pings stop it "pages" once by posting a HeartbeatMissing notification to the sink — the same
thing the real service would do by email/Slack. GET /status shows the current state.
"""
import http.server
import json
import os
import threading
import time
import urllib.request

GRACE = int(os.environ.get("GRACE_SECONDS", "30"))
SINK = os.environ.get("SINK_URL", "http://172.31.10.60:5001/")

state = {"status": "new", "last_ping": None, "pings": 0}
lock = threading.Lock()


def page(alertname):
    body = json.dumps({"status": "firing", "alerts": [{"labels": {"alertname": alertname}}]}).encode()
    req = urllib.request.Request(SINK, data=body, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=5)
    except Exception as exc:  # the sink being down must not kill the watcher
        print(f"could not page: {exc}")
    print(f"PAGED: {alertname}")


def watcher():
    while True:
        time.sleep(1)
        with lock:
            overdue = state["status"] == "up" and time.time() - state["last_ping"] > GRACE
            if overdue:
                state["status"] = "down"
        if overdue:
            page("HeartbeatMissing")


class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with lock:
            if state["status"] == "down":
                print("heartbeat back")
            state.update(status="up", last_ping=time.time(), pings=state["pings"] + 1)
        self._reply({"ok": True})

    def do_GET(self):
        with lock:
            age = None if state["last_ping"] is None else round(time.time() - state["last_ping"], 1)
            self._reply({"status": state["status"], "last_ping_age": age, "pings": state["pings"], "grace": GRACE})

    def log_message(self, *args):
        pass


threading.Thread(target=watcher, daemon=True).start()
http.server.ThreadingHTTPServer(("", 8000), Handler).serve_forever()
