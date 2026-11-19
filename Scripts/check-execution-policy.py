#!/usr/bin/env python3
"""Exercise the shipped execution policy with Pi 1.5.2 and a loopback model."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import uuid


READ_TOOLS = {"read", "grep", "find", "ls"}
POLICY = Path(__file__).resolve().parents[1] / "Modules/PiRuntimeAdapter/Resources/execution-policy.ts"


class Model(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        offered = {tool["function"]["name"] for tool in request.get("tools", [])}
        self.server.calls.put(offered)
        if request["messages"][-1]["role"] == "tool":
            delta, reason = {"content": "Finished."}, "stop"
        else:
            name, args = self.server.tool_call
            delta = {"tool_calls": [{"index": 0, "id": "call_fixture", "type": "function",
                                     "function": {"name": name, "arguments": json.dumps(args)}}]}
            reason = "tool_calls"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for change, finished in [(delta, None), ({}, reason)]:
            chunk = {"id": "fixture", "object": "chat.completion.chunk", "created": 0,
                     "model": "fixture-model", "choices": [{"index": 0, "delta": change, "finish_reason": finished}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")


class Pi:
    def __init__(self, args, project, agent, mode):
        read_tools = sorted(READ_TOOLS)
        self.mode = mode
        self.tools = read_tools + (["pikachu_bash", "pikachu_edit", "pikachu_write"] if mode == "interactive" else [])
        environment = dict(os.environ, PI_CODING_AGENT_DIR=str(agent), PIKACHU_EXECUTION_MODE=mode,
                           NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
        command = [args.pi, "--mode", "rpc", "--session-dir", str(project / "sessions"),
                   "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-themes",
                   "--model", "fixture/fixture-model"]
        if mode != "automatic":
            command += ["--tools", ",".join(self.tools), "-e", str(POLICY)]
        else:
            command += ["-e", str(project / "automatic.ts")]
        self.process = subprocess.Popen(command, cwd=project, env=environment, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.records = queue.Queue()
        self.buffer = []
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            self.records.put(json.loads(line))
        self.records.put(None)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()

    def send(self, record):
        self.process.stdin.write(json.dumps(record) + "\n")
        self.process.stdin.flush()

    def receive(self, predicate, timeout=15):
        while True:
            for index, record in enumerate(self.buffer):
                if predicate(record):
                    return self.buffer.pop(index)
            record = self.records.get(timeout=timeout)
            if record is None:
                raise AssertionError(self.process.stderr.read())
            self.buffer.append(record)

    def command(self, kind, **fields):
        identity = str(uuid.uuid4())
        self.send({"type": kind, "id": identity, **fields})
        result = self.receive(lambda event: event.get("type") == "response" and event.get("id") == identity)
        assert result.get("success"), result
        return result.get("data", {})

    def verify_policy(self):
        commands = self.command("get_commands")["commands"]
        assert {command["name"] for command in commands} == {"pikachu-verify-policy"}, commands
        assert self.command("prompt", message="/pikachu-verify-policy fixture")["disposition"] == "handled"
        self.receive(lambda event: event.get("statusText") == f"{self.mode}:fixture")

    def prompt(self):
        assert self.command("prompt", message="Run the fixture operation")["disposition"] == "started"

    def confirmation(self):
        return self.receive(lambda event: event.get("method") == "confirm")

    def settle(self, timeout=15):
        self.receive(lambda event: event.get("type") == "agent_settled", timeout=timeout)


def verify(args, project, agent, server):
    target = project / "output.txt"
    with Pi(args, project, agent, "interactive") as pi:
        pi.verify_policy()
        server.tool_call = ("pikachu_write", {"path": target.name, "content": "approved"})
        pi.prompt()
        confirm = pi.confirmation()
        assert target.name in confirm["message"] and "approved" in confirm["message"]
        assert not target.exists()
        pi.send({"type": "extension_ui_response", "id": confirm["id"], "confirmed": True})
        pi.settle()
        assert target.read_text() == "approved"
        assert server.calls.get(timeout=2) == set(pi.tools)
        history = pi.command("get_state")["sessionFile"]
        print("PASS interactive write requires explicit approval", flush=True)

    with Pi(args, project, agent, "interactive") as pi:
        pi.verify_policy()
        target.unlink()
        cases = ["deny", "stop"] + (["timeout"] if args.wait_for_timeout else [])
        for outcome in cases:
            shell = f"printf fixture > {target.name}"
            server.tool_call = ("pikachu_bash", {"command": shell})
            pi.prompt()
            confirm = pi.confirmation()
            assert shell in confirm["message"] and not target.exists()
            if outcome == "deny":
                pi.send({"type": "extension_ui_response", "id": confirm["id"], "confirmed": False})
            elif outcome == "stop":
                pi.command("clear_queue")
                pi.command("abort")
            pi.settle(timeout=130 if outcome == "timeout" else 15)
            assert not target.exists(), outcome
            print(f"PASS interactive {outcome} does not execute shell", flush=True)

    with Pi(args, project, agent, "plan") as pi:
        pi.verify_policy()
        assert pi.command("switch_session", sessionPath=history)["cancelled"] is False
        pi.verify_policy()
        while not server.calls.empty():
            server.calls.get_nowait()
        server.tool_call = ("write", {"path": target.name, "content": "not allowed"})
        pi.prompt()
        pi.settle()
        assert server.calls.get(timeout=2) == READ_TOOLS
        assert not target.exists()
        print("PASS restored plan session exposes only read tools and rejects writes", flush=True)

    with Pi(args, project, agent, "automatic") as pi:
        commands = pi.command("get_commands")["commands"]
        assert any(command["name"] == "fixture-extension" for command in commands)
        assert pi.command("prompt", message="/fixture-extension")["disposition"] == "handled"
        print("PASS automatic mode loads the selected extension", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pi", default=str(Path.home() / "bin/pi"))
    parser.add_argument("--wait-for-timeout", action="store_true", help="Also wait for a real 120-second Pi confirmation expiry.")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="pikachu-mode-fixture-") as temp, ThreadingHTTPServer(("127.0.0.1", 0), Model) as server:
        server.calls = queue.Queue()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            project, agent = Path(temp) / "project", Path(temp) / "agent"
            project.mkdir()
            agent.mkdir()
            (project / "automatic.ts").write_text(
                'export default function(pi) { pi.registerCommand("fixture-extension", { handler: async () => {} }); }'
            )
            (agent / "models.json").write_text(json.dumps({"providers": {"fixture": {
                "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "api": "openai-completions",
                "apiKey": "fixture", "models": [{"id": "fixture-model"}],
            }}}))
            verify(args, project, agent, server)
        finally:
            server.shutdown()


if __name__ == "__main__":
    main()
