"""In-cluster SSE reader: state files stay in the disposable load-client pod."""
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.request


def main():
    action, name, *args = sys.argv[1:]
    status = Path("/tmp") / ("stream-" + name + ".json")
    if action == "read":
        state = {"deltas": 0, "done": False}

        def save():
            tmp = status.with_suffix(".tmp")
            tmp.write_text(json.dumps(state))
            tmp.replace(status)

        try:
            with urllib.request.urlopen(args[0], timeout=920) as response:
                for line in response:
                    if line.startswith(b"event: delta"):
                        state["deltas"] += 1
                        save()
                    elif line.startswith(b"event: done"):
                        state["done"] = True
                if not state["done"]:
                    raise RuntimeError("Missing SSE done")
        except Exception as exc:
            state["error"] = str(exc)
            raise
        finally:
            save()
    elif action == "start":
        status.unlink(missing_ok=True)
        with status.with_suffix(".log").open("w") as log:
            subprocess.Popen([sys.executable, __file__, "read", name, args[0]], stdout=log, stderr=log,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        wait(status, "deltas", 60)
    elif action == "done":
        wait(status, "done", 115)
    else:
        raise ValueError(action)


def wait(path, field, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if path.exists():
            state = json.loads(path.read_text())
            if "error" in state:
                raise RuntimeError(state["error"])
            if state[field]:
                print(json.dumps(state))
                return
        time.sleep(.2)
    raise TimeoutError(field)


if __name__ == "__main__":
    main()
