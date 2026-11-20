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
                        return
                except OSError:
                    time.sleep(.1)
            self.fail("readiness timeout")
        finally:
            p.terminate()
            p.wait(timeout=10)
