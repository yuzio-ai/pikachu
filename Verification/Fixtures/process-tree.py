"""Verification-only synthetic runtime with detached descendants; no model or real repository."""
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

folder = pathlib.Path.cwd()
if "--short-lived-parent" in sys.argv:
    env = dict(os.environ)
    env.pop("ZIVVI_EXECUTION_TOKEN", None)
    leaf = subprocess.Popen(["/bin/sleep", "10"], env=env, start_new_session=True,
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (folder / "leaf.pid").write_text(str(leaf.pid))
    # Give the watchdog time to observe lineage before the unmarked leaf is reparented.
    time.sleep(0.25)
elif "--child" in sys.argv or "--leaf" in sys.argv:
    role = "child" if "--child" in sys.argv else "leaf"
    (folder / (role + ".pid")).write_text(str(os.getpid()))
    if "--ignore-term" in sys.argv:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if role == "child":
        subprocess.Popen([sys.executable, __file__, "--leaf"] + (["--ignore-term"] if "--ignore-term" in sys.argv else []),
                         start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    while True:
        with (folder / (role + ".heartbeat")).open("a") as output:
            output.write("x")
        time.sleep(0.03)
else:
    for line in sys.stdin:
        command = json.loads(line)
        if command["type"] == "spawn_lineage_only":
            subprocess.run([sys.executable, __file__, "--short-lived-parent"], check=True)
        if command["type"] == "spawn":
            subprocess.Popen([sys.executable, __file__, "--child"] + (["--ignore-term"] if command.get("ignoreTerm") else []),
                             start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 3
            while not (folder / "leaf.heartbeat").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
        print(json.dumps({"type": "response", "id": command["id"], "success": True, "data": {}}), flush=True)
    if "--ignore-eof" in sys.argv:
        while True:
            time.sleep(1)
