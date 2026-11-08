#!/usr/bin/env python3
"""Finto server HTTP che imita l'API WiFi di una GoPro HERO8 per provare l'app senza camera.

Uso:
    swift tools/make_mock_assets.swift tools/mock_assets   # una volta sola
    python3 tools/mock_gopro.py --port 18765 --assets tools/mock_assets

Poi in GoPro Connector > Impostazioni > Connessione: host 127.0.0.1, porte 18765 / 18765.
"""
import argparse
import json
import os
import re
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

ASSETS = "tools/mock_assets"
MEDIA = {}  # "100GOPRO" -> [entries]


def asset(name):
    return os.path.join(ASSETS, name)


def build_media():
    video_size = os.path.getsize(asset("video.mp4"))
    photo_size = os.path.getsize(asset("photo.jpg"))
    base = int(time.mktime((2026, 8, 14, 10, 0, 0, 0, 0, 0))) - time.timezone
    fs = []
    n = 1
    for day in range(3):
        for k in range(8):
            t = base + day * 86400 + k * 1800
            if k % 4 == 0:
                fs.append({"n": "GOPR%04d.JPG" % n, "cre": str(t), "mod": str(t), "s": str(photo_size)})
            elif k % 4 == 3:
                fs.append({"n": "G%03d%04d.JPG" % (n % 1000, 1), "g": str(n % 1000), "b": "1", "l": "6",
                           "m": [], "t": "b", "cre": str(t), "mod": str(t), "s": str(photo_size * 6)})
            else:
                fs.append({"n": "GH01%04d.MP4" % n, "cre": str(t), "mod": str(t), "glrv": str(video_size),
                           "ls": "-1", "s": str(video_size)})
                if k == 2:
                    fs.append({"n": "GH02%04d.MP4" % n, "cre": str(t + 60), "mod": str(t + 60),
                               "glrv": str(video_size), "ls": "-1", "s": str(video_size)})
            n += 1
    MEDIA["100GOPRO"] = fs


def find(path):
    d, _, name = path.partition("/")
    for e in MEDIA.get(d, []):
        if e["n"] == name:
            return d, e
    return None, None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("[mock]", self.command, self.path, fmt % args if args else "")

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path, ctype):
        size = os.path.getsize(path)
        start, end = 0, size - 1
        rng = self.headers.get("Range")
        m = re.match(r"bytes=(\d*)-(\d*)", rng or "")
        if m:
            if m.group(1):
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
            elif m.group(2):
                start = size - int(m.group(2))
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        else:
            self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(256 * 1024, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)
                time.sleep(0.01)  # simula la banda limitata del WiFi della camera

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        p = u.path
        if p == "/gp/gpControl/info":
            return self.send_json({"info": {"model_number": 50, "model_name": "HERO8 Black (mock)",
                                            "firmware_version": "HD8.01.02.51.00", "serial_number": "C3301325000000",
                                            "ap_ssid": "GP25000000"}})
        if p == "/gp/gpControl/status":
            return self.send_json({"status": {"70": 78, "54": 41234567, "33": 0}, "settings": {}})
        if p == "/gp/gpMediaList":
            return self.send_json({"id": "1234567890", "media": [{"d": d, "fs": fs} for d, fs in MEDIA.items()]})
        if p == "/gp/gpMediaMetadata":
            path = q.get("p", [""])[0]
            d, e = find(path)
            if not e:
                return self.send_json({}, 404)
            idx = sum(map(ord, e["n"])) % 10
            return self.send_file(asset("thumb%d.jpg" % idx), "image/jpeg")
        if p.startswith("/gp/gpControl/command/storage/delete"):
            path = q.get("p", [""])[0]
            d, e = find(path)
            if not e:
                return self.send_json({}, 404)
            MEDIA[d].remove(e)
            return self.send_json({})
        m = re.match(r"/videos/DCIM/([^/]+)/(.+)", p)
        if m:
            name = m.group(2).upper()
            if name.endswith(".MP4") or name.endswith(".LRV"):
                return self.send_file(asset("video.mp4"), "video/mp4")
            if name.endswith(".JPG"):
                return self.send_file(asset("photo.jpg"), "image/jpeg")
        self.send_json({"error": "not found"}, 404)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18765)
    ap.add_argument("--assets", default=ASSETS)
    a = ap.parse_args()
    ASSETS = a.assets
    build_media()
    print("Mock GoPro su http://127.0.0.1:%d" % a.port)
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()
