#!/usr/bin/python3
"""Deterministic M1 fault peer. It does not call a provider or touch a real repository."""
import json
import os
import pathlib
import subprocess
import sys
import time

mode = "normal"
if "-e" in sys.argv:
    mode = pathlib.Path(sys.argv[sys.argv.index("-e") + 1]).name
if "--version" in sys.argv:
    # Version mismatch uses a separate generated wrapper in the verifier.
    print("1.5.2")
    raise SystemExit(0)
root = pathlib.Path.cwd()
if "--worker" in sys.argv:
    (root / "worker.pid").write_text(str(os.getpid()))
    while True:
        with (root / "heartbeat").open("a") as stream:
            stream.write("x")
        time.sleep(0.03)

def emit(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    command = json.loads(line)
    kind = command["type"]
    response = {"type": "response", "id": command.get("id"), "success": True, "data": {}}
    if kind == "get_state":
        if mode == "connect-timeout":
            continue
        response["data"] = {"sessionId": "fixture", "model": {"id": "fixture"}, "isStreaming": False, "pendingMessageCount": 0}
    elif kind == "prompt":
        with (root / "prompt-count").open("a") as stream:
            stream.write("x")
        if mode == "timeout":
            continue
        if mode == "rejected":
            response["success"] = False
            response["error"] = "Fixture rejection"
        else:
            response["data"] = {"disposition": "started"}
            emit(response)
            emit({"type": "agent_start"})
            if mode == "malformed":
                print("{invalid protocol}", flush=True)
            elif mode == "crash":
                subprocess.Popen([sys.executable, __file__, "--worker"], start_new_session=True,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                emit({"type": "tool_execution_start", "toolCallId": "fixture-tool", "toolName": "bash", "args": {"command": "fixture heartbeat"}})
            elif mode == "authentication":
                emit({"type": "message_start", "message": {"role": "assistant"}})
                emit({"type": "message_end", "message": {"role": "assistant", "content": [], "stopReason": "error", "errorMessage": "401 unauthorized sk-m1-fake-secret"}})
                emit({"type": "agent_settled"})
            else:
                emit({"type": "message_start", "message": {"role": "assistant"}})
                emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "incremental"}})
                emit({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "canonical fixture result"}]}})
                emit({"type": "agent_settled"})
            continue
    elif kind == "clear_queue":
        response["data"] = {"steering": [], "followUp": []}
    elif kind == "abort":
        emit({"type": "agent_settled", "aborted": True})
    emit(response)
