import json
import socket
import subprocess
import sys
import time
import unittest
import urllib.request
from pathlib import Path


class Entrypoint(unittest.TestCase):
    def test_ready_using_docker_cmd(self):
        root = Path(__file__).resolve().parents[1] / "app"
        line = next(s for s in (root / "Dockerfile").read_text().splitlines() if s.startswith("CMD "))
        args = json.loads(line[4:])
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = str(sock.getsockname()[1])
        args[args.index("8000")] = port
        args[args.index("0.0.0.0")] = "127.0.0.1"
        p = subprocess.Popen([sys.executable, "-m", *args], cwd=root)
        try:
            for _ in range(100):
                self.assertIsNone(p.poll(), "Docker command exited before readiness")
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/ready", timeout=1) as r:
                        self.assertTrue(json.load(r)["ready"])
                        break
                except OSError:
                    time.sleep(.1)
            else:
                self.fail("readiness timeout")
            base = f"http://127.0.0.1:{port}"
            with urllib.request.urlopen(base + "/streams/disconnect", timeout=3) as stream:
                self.assertEqual(stream.readline().strip(), b"event: delta")
                with urllib.request.urlopen(base + "/metrics", timeout=2) as r:
                    self.assertIn(b"\nagent_runs_active 1.0\n", r.read())
            for _ in range(50):
                with urllib.request.urlopen(base + "/metrics", timeout=2) as r:
                    if b"\nagent_runs_active 0.0\n" in r.read():
                        break
                time.sleep(.05)
            else:
                self.fail("disconnected SSE client still counted")
        finally:
            p.terminate()
            p.wait(timeout=10)
