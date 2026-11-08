"""The demo phone's position (frontend/phone): it has no GPS, so the 📍
button on its page (position.js) picks one, and this writes it where the app
reads it (FilePositionSource in frontend/app/lib/core/location).

    GET  /position   the current one: "latitude,longitude", or "off"
    PUT  /position   body "latitude,longitude" or "off"

Anything else is refused, and the file only ever holds one of those two
shapes. Another port than the page's, so the page's script calls it across
origins: the answers allow any origin, as the screen and the sound do.

    python3 position.py <port> <file>
"""

import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
PATH = sys.argv[2]


def parse(text):
    """The text as the file will hold it, or None if it is not a position."""
    text = text.strip()
    if text == "off":
        return text
    parts = text.split(",")
    if len(parts) != 2:
        return None
    try:
        latitude, longitude = float(parts[0]), float(parts[1])
    except ValueError:
        return None
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        return None
    return f"{latitude},{longitude}"


class Handler(BaseHTTPRequestHandler):
    def _answer(self, status, body=""):
        data = body.encode()
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, PUT, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self._answer(204)

    def do_GET(self):
        if self.path != "/position":
            return self._answer(404)
        try:
            with open(PATH) as f:
                current = parse(f.read()) or "off"
        except FileNotFoundError:
            current = "off"
        self._answer(200, current)

    def do_PUT(self):
        if self.path != "/position":
            return self._answer(404)
        length = min(int(self.headers.get("Content-Length") or 0), 100)
        position = parse(self.rfile.read(length).decode(errors="replace"))
        if position is None:
            return self._answer(400, 'expected "latitude,longitude" or "off"')
        os.makedirs(os.path.dirname(PATH), exist_ok=True)
        # Replaced whole, never half-written: the app may read it right now.
        tmp = PATH + ".tmp"
        with open(tmp, "w") as f:
            f.write(position)
        os.replace(tmp, PATH)
        self._answer(200, position)

    def log_message(self, *args):
        pass  # one line per click is noise in the container's log


ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
