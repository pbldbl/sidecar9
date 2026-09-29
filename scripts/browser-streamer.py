#!/usr/bin/env python3
"""iPad как второй монитор: снимки виртуального дисплея (DeskPad) через screencapture,
раздача по HTTP. На планшете открывается http://<mac>:8081/ в Safari.

Запуск:  ipad-screen.py [--display N] [--fps 6] [--port 8081]
--display: номер дисплея для screencapture (1 = основной), по умолчанию последний.
"""
import argparse
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = """<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<title>Mac screen</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
img{width:100%;height:100%;object-fit:contain;display:block}</style></head>
<body><img id="s" src="/frame">
<script>
// Старый Safari не обновляет MJPEG-поток, поэтому опрашиваем кадры по одному.
var img=document.getElementById('s'), busy=false;
function tick(){
  if(busy) return; busy=true;
  var n=new Image();
  n.onload=function(){ img.src=n.src; busy=false; };
  n.onerror=function(){ busy=false; };
  n.src='/frame?'+Date.now();
}
setInterval(tick, 70);
</script></body></html>"""


def display_count():
    p = subprocess.run(["displayplacer", "list"], capture_output=True, text=True)
    return p.stdout.count("Persistent screen id")


class Frames:
    def __init__(self):
        self.cond = threading.Condition()
        self.frame = None
        self.seq = 0
        self.alive = True

    def push(self, data):
        with self.cond:
            self.frame = data
            self.seq += 1
            self.cond.notify_all()

    def wait(self, last_seq, timeout=5.0):
        with self.cond:
            self.cond.wait_for(lambda: self.seq != last_seq or not self.alive, timeout)
            return self.frame, self.seq


SCKCAP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sckcap")


def capture_loop(frames, display, fps, quality=0.8):
    """ScreenCaptureKit (sckcap) даёт поток JPEG-кадров; если бинарника нет — screencapture."""
    if os.path.exists(SCKCAP):
        while frames.alive:
            proc = subprocess.Popen([SCKCAP, "0", str(fps), str(quality), "1024"],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            buf = b""
            try:
                while frames.alive:
                    chunk = proc.stdout.read(65536)
                    if not chunk:
                        break
                    buf += chunk
                    while True:
                        s = buf.find(b"\xff\xd8\xff")
                        e = buf.find(b"\xff\xd9", s + 3) if s >= 0 else -1
                        if s < 0 or e < 0:
                            break
                        frames.push(buf[s:e + 2])
                        buf = buf[e + 2:]
            finally:
                proc.kill()
                err = proc.stderr.read().decode(errors="replace").strip()
                if err:
                    print(err[-400:], file=sys.stderr, flush=True)
            if frames.alive:
                print("[capture] sckcap остановился, перезапуск через 2 с", file=sys.stderr, flush=True)
                time.sleep(2)
        return
    capture_loop_screencapture(frames, display, fps)


def capture_loop_screencapture(frames, display, fps):
    """Запасной путь: screencapture умеет снимать конкретный дисплей вместе с курсором (-C)."""
    tmp = os.path.join(tempfile.gettempdir(), f"ipad-screen-{os.getpid()}.jpg")
    period = 1.0 / max(1, fps)
    fails = 0
    while frames.alive:
        t0 = time.time()
        p = subprocess.run(["screencapture", "-x", "-C", "-t", "jpg", "-D", str(display), tmp],
                           capture_output=True, text=True)
        try:
            with open(tmp, "rb") as f:
                data = f.read()
            if data.startswith(b"\xff\xd8"):
                frames.push(data)
                fails = 0
            else:
                raise ValueError("не JPEG")
        except Exception as e:  # noqa: BLE001
            fails += 1
            if fails in (1, 10, 100):
                print(f"[capture] display {display}: {e} {p.stderr.strip()[-200:]}", file=sys.stderr, flush=True)
            time.sleep(1)
        dt = time.time() - t0
        if dt < period:
            time.sleep(period - dt)
    try:
        os.remove(tmp)
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    frames = None
    protocol_version = "HTTP/1.1"

    stats = {"n": 0, "bytes": 0, "t": time.time(), "seq": 0}

    def log_message(self, fmt, *args):
        if "/frame" in self.path:
            st = Handler.stats
            st["n"] += 1
            now = time.time()
            if now - st["t"] >= 10:
                print(f"[stats] {self.client_address[0]} забирает {st['n'] / (now - st['t']):.1f} кадров/с, "
                      f"источник даёт {(self.frames.seq - st['seq']) / (now - st['t']):.1f} кадров/с", file=sys.stderr, flush=True)
                st["n"] = 0; st["t"] = now; st["seq"] = self.frames.seq
            return
        print(f"{self.client_address[0]} {fmt % args}", file=sys.stderr, flush=True)

    def do_GET(self):
        if self.path.startswith("/frame"):
            frame, _ = self.frames.wait(-1, 3.0)
            if not frame:
                self.send_response(503); self.send_header("Content-Length", "0"); self.end_headers(); return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(frame)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(frame)
            return
        if self.path.startswith("/stream"):
            return self.stream()
        if self.path.startswith("/m"):
            data = PAGE.replace('src="/frame"', 'src="/stream"').replace("setInterval(tick, 70);", "").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        data = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def stream(self):
        """MJPEG для браузеров, которые его умеют (на iOS 9 не работает)."""
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-cache, no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        seq = -1
        try:
            while self.frames.alive:
                frame, seq = self.frames.wait(seq)
                if not frame:
                    continue
                self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                 + str(len(frame)).encode() + b"\r\n\r\n" + frame + b"\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--display", type=int, default=None, help="номер дисплея для screencapture")
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--quality", type=float, default=0.8)
    ap.add_argument("--port", type=int, default=8081)
    ap.add_argument("--width", type=int, default=0, help="не используется, оставлен для совместимости")
    a = ap.parse_args()

    display = a.display or display_count() or 1
    print(f"[screen] дисплей {display} из {display_count()}, до {a.fps} кадров/с", flush=True)

    frames = Frames()
    Handler.frames = frames
    threading.Thread(target=capture_loop, args=(frames, display, a.fps, a.quality), daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", a.port), Handler)
    srv.daemon_threads = True

    def stop(*_):
        frames.alive = False
        srv.shutdown()
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    print(f"[http] http://0.0.0.0:{a.port}/  (на планшете: http://<ip-мака>:{a.port}/)", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
