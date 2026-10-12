"""Fake notification receiver: records every Alertmanager webhook so tests can count deliveries.

POST /  -> record the notification
GET  /  -> all recorded notifications as a JSON array
DELETE / -> clear
"""
import http.server
import json
import threading

notifications = []
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self, body=b""):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        with lock:
            notifications.append(payload)
        for alert in payload.get("alerts", []):
            print(f"{payload.get('status')}: {alert['labels'].get('alertname')} {alert['labels'].get('instance', '')}")
        self._reply()

    def do_GET(self):
        with lock:
            body = json.dumps(notifications).encode()
        self._reply(body)

    def do_DELETE(self):
        with lock:
            notifications.clear()
        self._reply()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("", 5001), Handler).serve_forever()
