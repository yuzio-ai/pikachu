#!/usr/bin/python3
"""Deterministic synthetic ACP v1 (protocolVersion: 1) stdio agent fixture.

Supports bidirectional JSON-RPC 2.0 over newline-delimited stdin/stdout:
- initialize (strict protocolVersion negotiation, capabilities, authMethods)
- authenticate
- session/new, session/load (with history replay via session/update)
- session/prompt (streaming thought, text, tool_call, tool_call_update with diff, plan, usage_update)
- session/request_permission (Agent -> Client JSON-RPC request with int or string ID)
- session/cancel (notification cancelling in-flight prompt and permission waits)
- session/set_mode, session/set_model, session/set_config_option
- Fault injection: malformed JSON, crash (optional detached worker), auth errors, refusal, max_tokens, slow/cancel.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import threading
import time


def parse_args():
    parser = argparse.ArgumentParser(description="Synthetic ACP v1 stdio server")
    parser.add_argument("--protocol-version", type=int, default=1)
    parser.add_argument("--require-auth", action="store_true")
    parser.add_argument("--require-auth-strict", action="store_true")
    parser.add_argument("--terminal-auth-state", default="")
    parser.add_argument("--terminal-login", action="store_true")
    parser.add_argument("--terminal-reconnect-gate", default="")
    parser.add_argument("--terminal-old-exit-gate", default="")
    parser.add_argument("--fail-terminal-reconnect", action="store_true")
    parser.add_argument("--terminal-supervisor-test", default="")
    parser.add_argument("--receipt-path", default="")
    parser.add_argument("--no-load-session", action="store_true")
    parser.add_argument("--no-image", action="store_true")
    parser.add_argument("--legacy-models", action="store_true")
    parser.add_argument("--config-options-only", action="store_true")
    parser.add_argument("--delay-prompt", type=float, default=0.0)
    parser.add_argument("--ignore-cancel", action="store_true")
    parser.add_argument("--permission-id-type", choices=["int", "string"], default="int")
    parser.add_argument("--state-file", default="")
    parser.add_argument("--v1-extended", action="store_true")
    parser.add_argument("--worker", action="store_true")
    return parser.parse_args()


def run_worker():
    root = pathlib.Path.cwd()
    (root / "worker.pid").write_text(str(os.getpid()), encoding="utf-8")
    while True:
        with (root / "heartbeat").open("a", encoding="utf-8") as stream:
            stream.write("x")
        time.sleep(0.03)


class FakeACPServer:
    def __init__(self, args):
        self.args = args
        self.write_lock = threading.Lock()
        self.state_lock = threading.Lock()
        self.authenticated = not (args.require_auth or args.require_auth_strict or args.terminal_auth_state)
        if args.terminal_auth_state and pathlib.Path(args.terminal_auth_state).exists():
            self.authenticated = True
        self.initialized = False
        self.pending_authentication = set()
        self.next_session_num = 0
        self.next_server_req_id = 100
        self.sessions = {}
        self.pending_client_responses = {}  # id_key -> (threading.Event, result_box)
        self.active_cancel_events = {}  # session_id -> threading.Event
        self.load_persisted_state()

    def load_persisted_state(self):
        if not self.args.state_file:
            return
        path = pathlib.Path(self.args.state_file)
        if not path.exists():
            return
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            self.sessions = data.get("sessions", {})
            self.next_session_num = int(data.get("next_session_num", len(self.sessions)))
        except Exception:
            self.sessions = {}

    def save_persisted_state(self):
        if not self.args.state_file:
            return
        path = pathlib.Path(self.args.state_file)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "next_session_num": self.next_session_num,
                "sessions": self.sessions,
            }
            path.write_text(json.dumps(payload), encoding="utf-8")
        except Exception:
            pass

    def record_receipt(self, event_name, extra=None):
        receipt_path = self.args.receipt_path or os.environ.get("FAKE_ACP_RECEIPT", "")
        if not receipt_path:
            return
        entry = {"event": event_name}
        if extra is not None:
            entry["detail"] = extra
        try:
            with open(receipt_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry) + "\n")
        except Exception:
            pass

    def send(self, payload):
        line = json.dumps(payload, separators=(",", ":"))
        with self.write_lock:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()

    def send_raw(self, raw_line):
        with self.write_lock:
            sys.stdout.write(raw_line + "\n")
            sys.stdout.flush()

    def send_result(self, req_id, result):
        self.send({"jsonrpc": "2.0", "id": req_id, "result": result})

    def send_error(self, req_id, code, message, data=None):
        err = {"code": code, "message": message}
        if data is not None:
            err["data"] = data
        self.send({"jsonrpc": "2.0", "id": req_id, "error": err})

    def send_update(self, session_id, update):
        self.send({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": session_id,
                "update": update,
            },
        })

    def available_modes(self):
        return [
            {"id": "default", "name": "Default", "description": "Standard coding mode with permission prompts."},
            {"id": "plan", "name": "Plan", "description": "Read-only planning mode."},
            {"id": "accept-edits", "name": "Accept Edits", "description": "Automatically approve file edits."},
            {"id": "auto", "name": "Auto", "description": "Run tools autonomously."},
        ]

    def available_models(self):
        return [
            {"modelId": "fake/model-alpha", "name": "Fake Alpha", "description": "Primary synthetic ACP model."},
            {"modelId": "fake/model-beta", "name": "Fake Beta", "description": "Secondary synthetic ACP model."},
        ]

    def build_config_options(self, session):
        return [
            {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": session["modelId"],
                "options": [
                    {"value": m["modelId"], "name": m["name"], "description": m["description"]}
                    for m in self.available_models()
                ],
            },
            {
                "id": "thought_level",
                "name": "Reasoning Effort",
                "category": "thought_level",
                "type": "select",
                "currentValue": session["thoughtLevel"],
                "options": [
                    {"value": "low", "name": "Low"},
                    {"value": "medium", "name": "Medium"},
                    {"value": "high", "name": "High"},
                ],
            },
            {
                "id": "mode",
                "name": "Mode",
                "category": "mode",
                "type": "select",
                "currentValue": session["modeId"],
                "options": [
                    {"value": m["id"], "name": m["name"], "description": m["description"]}
                    for m in self.available_modes()
                ],
            },
        ]

    def build_session_metadata(self, session):
        result = {}
        if not self.args.legacy_models:
            result["configOptions"] = self.build_config_options(session)
        if not self.args.config_options_only:
            result["modes"] = {
                "currentModeId": session["modeId"],
                "availableModes": self.available_modes(),
            }
            result["models"] = {
                "currentModelId": session["modelId"],
                "availableModels": self.available_models(),
            }
        return result

    def check_auth(self, req_id):
        if self.authenticated:
            return True
        self.send_error(
            req_id,
            -32000,
            "Authentication required",
            {"code": "auth_required", "hint": "Run agy acp --login or authenticate first."},
        )
        return False

    def handle_initialize(self, req_id, params):
        self.initialized = True
        self.record_receipt("initialize", {
            "protocolVersion": params.get("protocolVersion"), "pid": os.getpid(), "supervisorPID": os.getppid()
        })
        if self.args.terminal_auth_state and pathlib.Path(self.args.terminal_auth_state).exists():
            if self.args.terminal_reconnect_gate:
                gate = pathlib.Path(self.args.terminal_reconnect_gate)
                deadline = time.monotonic() + 8
                while not gate.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
            if self.args.fail_terminal_reconnect:
                self.send_error(req_id, -32603, "Fixture reconnect failure")
                return
        elif self.args.terminal_old_exit_gate:
            gate = pathlib.Path(self.args.terminal_old_exit_gate)

            def exit_after_gate():
                deadline = time.monotonic() + 10
                while not gate.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                if gate.exists():
                    os._exit(0)

            threading.Thread(target=exit_after_gate, daemon=True).start()
        auth_methods = []
        if self.args.require_auth or self.args.require_auth_strict:
            auth_methods.append({
                "id": "oauth-browser",
                "name": "Browser Login",
                "description": "Sign in interactively with your agent account.",
            })
        if self.args.terminal_auth_state and params.get("clientCapabilities", {}).get("auth", {}).get("terminal") is True:
            auth_methods.append({
                "id": "terminal-login",
                "name": "Browser Login",
                "type": "terminal",
                "args": ["--terminal-login"],
                "env": {"FAKE_LOGIN_FLAG": "terminal"},
            })
        result = {
            "protocolVersion": self.args.protocol_version,
            "agentInfo": {
                "name": "fake-acp",
                "title": "Fake ACP v1 Agent",
                "version": "1.0.0",
            },
            "agentCapabilities": {
                "loadSession": not self.args.no_load_session,
                "promptCapabilities": {
                    "image": not self.args.no_image,
                    "audio": False,
                    "embeddedContext": True,
                },
                "mcpCapabilities": {
                    "http": False,
                    "sse": False,
                },
            },
            "authMethods": auth_methods,
        }
        if self.args.v1_extended:
            result["agentCapabilities"]["sessionCapabilities"] = {
                key: {} for key in ["list", "delete", "resume", "close"]
            }
            result["agentCapabilities"]["auth"] = {"logout": {}}
            auth_methods.extend([
                {"id": "verify-form", "name": "Verify form", "type": "agent"},
                {"id": "verify-url", "name": "Verify URL", "type": "agent"},
                {"id": "verify-cancel", "name": "Verify cancellation", "type": "agent"},
            ])
        self.send_result(req_id, result)

    def handle_authenticate(self, req_id, params):
        method_id = params.get("methodId", "")
        self.record_receipt("authenticate", {"methodId": method_id})
        if method_id == "terminal-login":
            self.send_error(req_id, -32602, "Terminal login is out of band")
            return
        if self.args.v1_extended and method_id == "verify-cancel":
            self.pending_authentication.add(req_id)
            self.record_receipt("authenticate/hold")
            return
        if self.args.v1_extended and method_id in ["verify-form", "verify-url"]:
            threading.Thread(target=self.verify_elicitation, args=(req_id, method_id), daemon=True).start()
            return
        if self.args.require_auth_strict or not method_id:
            self.send_error(req_id, -32000, "Authentication failed", {"code": "auth_required"})
            return
        self.authenticated = True
        self.send_result(req_id, {})

    def verify_elicitation(self, req_id, method_id):
        params = {"requestId": req_id, "message": "Provide a fixture response."}
        if method_id == "verify-form":
            params.update({
                "mode": "form",
                "requestedSchema": {
                    "type": "object",
                    "properties": {"confirm": {"type": "boolean", "default": True}},
                    "required": ["confirm"],
                },
            })
        else:
            params.update({"mode": "url", "url": "https://example.test/confirm", "elicitationId": "fixture-url"})
        reply = self.send_client_request("elicitation/create", params, use_string_id=True)
        result = (reply or {}).get("result", {})
        valid = result.get("action") == "accept"
        if method_id == "verify-form":
            valid = valid and result.get("content") == {"confirm": True}
        if not valid:
            self.send_error(req_id, -32000, "Authentication interrupted")
            return
        self.authenticated = True
        if method_id == "verify-url":
            for item in ["unknown-id", "fixture-url", "fixture-url"]:
                self.send({"jsonrpc": "2.0", "method": "elicitation/complete", "params": {"elicitationId": item}})
        self.send_result(req_id, {})

    def handle_session_management(self, method, req_id, params):
        if not self.check_auth(req_id):
            return
        self.record_receipt(method)
        session_id = params.get("sessionId")
        with self.state_lock:
            if method == "session/list":
                entries = [{"sessionId": key, "cwd": value["cwd"], "title": key}
                           for key, value in self.sessions.items() if value["cwd"] == params.get("cwd")]
                cursor = int(params.get("cursor") or "0")
                next_cursor = str(cursor + 1) if cursor + 1 < len(entries) else None
                self.send_result(req_id, {"sessions": entries[cursor:cursor + 1], "nextCursor": next_cursor})
                return
            if session_id not in self.sessions:
                self.send_error(req_id, -32002, "Session unavailable")
                return
            if method == "session/delete":
                del self.sessions[session_id]
                self.save_persisted_state()
            metadata = self.build_session_metadata(self.sessions[session_id]) if method == "session/resume" else {}
        self.send_result(req_id, metadata)

    def handle_session_new(self, req_id, params):
        if not self.check_auth(req_id):
            return
        cwd = params.get("cwd", os.getcwd())
        with self.state_lock:
            self.next_session_num += 1
            session_id = f"acp-session-{self.next_session_num}"
            session = {
                "sessionId": session_id,
                "cwd": cwd,
                "modeId": "default",
                "modelId": "fake/model-alpha",
                "thoughtLevel": "medium",
                "history": [],
            }
            self.sessions[session_id] = session
            self.save_persisted_state()
        self.record_receipt("session/new", {"sessionId": session_id, "cwd": cwd})
        result = {"sessionId": session_id}
        result.update(self.build_session_metadata(session))
        self.send_result(req_id, result)

    def handle_session_load(self, req_id, params):
        if not self.check_auth(req_id):
            return
        if self.args.no_load_session:
            self.send_error(req_id, -32601, "session/load is not supported by this agent")
            return
        session_id = params.get("sessionId")
        if not isinstance(session_id, str) or not session_id:
            self.send_error(req_id, -32602, "Missing sessionId")
            return

        with self.state_lock:
            session = self.sessions.get(session_id)
            if session is None and session_id == "replay-fixture":
                session = {
                    "sessionId": session_id,
                    "cwd": params.get("cwd", os.getcwd()),
                    "modeId": "default",
                    "modelId": "fake/model-alpha",
                    "thoughtLevel": "medium",
                    "history": [
                        {"role": "user", "text": "Replay fixture user question"},
                        {
                            "role": "tool",
                            "toolCallId": "replay-tool-1",
                            "title": "Edit Demo.swift",
                            "kind": "edit",
                            "path": "Sources/Demo.swift",
                            "oldText": "let version = 1\n",
                            "newText": "let version = 2\n",
                            "output": "Updated Sources/Demo.swift",
                        },
                        {"role": "assistant", "text": "Replay fixture assistant answer"},
                    ],
                }
                self.sessions[session_id] = session
            if session is None:
                self.send_error(req_id, -32002, f"Session not found: {session_id}")
                return
            history_snapshot = list(session["history"])

        self.record_receipt("session/load", {"sessionId": session_id, "historyCount": len(history_snapshot)})

        # ACP v1: Replay history via session/update notifications BEFORE returning the session/load response.
        for item in history_snapshot:
            role = item.get("role")
            if role == "user":
                self.send_update(session_id, {
                    "sessionUpdate": "user_message_chunk",
                    "content": {"type": "text", "text": item.get("text", "")},
                })
            elif role == "assistant":
                self.send_update(session_id, {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": item.get("text", "")},
                })
            elif role == "tool":
                tool_id = item.get("toolCallId", "tool-replay")
                self.send_update(session_id, {
                    "sessionUpdate": "tool_call",
                    "toolCallId": tool_id,
                    "title": item.get("title", "Tool"),
                    "kind": item.get("kind", "other"),
                    "status": "in_progress",
                })
                content = [{"type": "content", "content": {"type": "text", "text": item.get("output", "")}}]
                if item.get("path"):
                    content.append({
                        "type": "diff",
                        "path": item["path"],
                        "oldText": item.get("oldText", ""),
                        "newText": item.get("newText", ""),
                    })
                self.send_update(session_id, {
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": tool_id,
                    "status": "completed",
                    "content": content,
                })

        result = self.build_session_metadata(session)
        self.send_result(req_id, result)

    def handle_set_mode(self, req_id, params):
        session_id = params.get("sessionId")
        mode_id = params.get("modeId")
        valid_ids = {m["id"] for m in self.available_modes()}
        with self.state_lock:
            session = self.sessions.get(session_id)
            if session is None:
                self.send_error(req_id, -32002, "Unknown session")
                return
            if mode_id not in valid_ids:
                self.send_error(req_id, -32602, f"Unsupported modeId: {mode_id}")
                return
            session["modeId"] = mode_id
            self.save_persisted_state()
            config_options = self.build_config_options(session) if not self.args.legacy_models else None

        self.send_update(session_id, {
            "sessionUpdate": "current_mode_update",
            "currentModeId": mode_id,
        })
        if config_options is not None:
            self.send_update(session_id, {
                "sessionUpdate": "config_option_update",
                "configOptions": config_options,
            })
        self.send_result(req_id, {})

    def handle_set_model(self, req_id, params):
        session_id = params.get("sessionId")
        model_id = params.get("modelId")
        valid_ids = {m["modelId"] for m in self.available_models()}
        with self.state_lock:
            session = self.sessions.get(session_id)
            if session is None:
                self.send_error(req_id, -32002, "Unknown session")
                return
            if model_id not in valid_ids:
                self.send_error(req_id, -32602, f"Unsupported modelId: {model_id}")
                return
            session["modelId"] = model_id
            self.save_persisted_state()
            config_options = self.build_config_options(session) if not self.args.legacy_models else None

        if config_options is not None:
            self.send_update(session_id, {
                "sessionUpdate": "config_option_update",
                "configOptions": config_options,
            })
        self.send_result(req_id, {})

    def handle_set_config_option(self, req_id, params):
        if self.args.legacy_models:
            self.send_error(req_id, -32601, "Method not found: session/set_config_option")
            return
        session_id = params.get("sessionId")
        config_id = params.get("configId")
        value = params.get("value")
        with self.state_lock:
            session = self.sessions.get(session_id)
            if session is None:
                self.send_error(req_id, -32002, "Unknown session")
                return
            if config_id == "model":
                valid = {m["modelId"] for m in self.available_models()}
                if value not in valid:
                    self.send_error(req_id, -32602, f"Invalid model value: {value}")
                    return
                session["modelId"] = value
            elif config_id == "thought_level":
                if value not in {"low", "medium", "high"}:
                    self.send_error(req_id, -32602, f"Invalid thought_level value: {value}")
                    return
                session["thoughtLevel"] = value
            elif config_id == "mode":
                valid = {m["id"] for m in self.available_modes()}
                if value not in valid:
                    self.send_error(req_id, -32602, f"Invalid mode value: {value}")
                    return
                session["modeId"] = value
            else:
                self.send_error(req_id, -32602, f"Unknown configId: {config_id}")
                return
            self.save_persisted_state()
            config_options = self.build_config_options(session)

        self.send_update(session_id, {
            "sessionUpdate": "config_option_update",
            "configOptions": config_options,
        })
        if config_id == "mode":
            self.send_update(session_id, {
                "sessionUpdate": "current_mode_update",
                "currentModeId": value,
            })
        self.send_result(req_id, {"configOptions": config_options})

    def send_client_request(self, method, params, use_string_id=False, cancel_event=None):
        with self.state_lock:
            self.next_server_req_id += 1
            num = self.next_server_req_id
            req_id = f"perm-{num}" if use_string_id else num
            id_key = (type(req_id).__name__, req_id)
            done = threading.Event()
            box = {}
            self.pending_client_responses[id_key] = (done, box)

        self.send({
            "jsonrpc": "2.0",
            "id": req_id,
            "method": method,
            "params": params,
        })

        # Wait until client responds or turn is cancelled.
        deadline = time.monotonic() + 30.0
        while time.monotonic() < deadline:
            if done.wait(timeout=0.05):
                break
            if cancel_event is not None and cancel_event.is_set():
                break

        with self.state_lock:
            self.pending_client_responses.pop(id_key, None)

        return box.get("response")

    def handle_session_prompt(self, req_id, params):
        if not self.check_auth(req_id):
            return
        session_id = params.get("sessionId")
        prompt_blocks = params.get("prompt", [])
        with self.state_lock:
            session = self.sessions.get(session_id)
            if session is None:
                self.send_error(req_id, -32002, f"Unknown session: {session_id}")
                return
            cancel_event = threading.Event()
            self.active_cancel_events[session_id] = cancel_event

        thread = threading.Thread(
            target=self._run_prompt_turn,
            args=(req_id, session_id, prompt_blocks, cancel_event),
            daemon=True,
        )
        thread.start()

    def _run_prompt_turn(self, req_id, session_id, prompt_blocks, cancel_event):
        try:
            texts = []
            image_count = 0
            for block in prompt_blocks:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                if btype == "text" and isinstance(block.get("text"), str):
                    texts.append(block["text"])
                elif btype == "image":
                    image_count += 1
            combined = "\n".join(texts).strip()
            lower = combined.lower()
            self.record_receipt("session/prompt", {"sessionId": session_id, "images": image_count})

            if "reject-length-fixture" in lower or "unknown-length-fixture" in lower:
                code = -32602 if "reject-length-fixture" in lower else -32603
                self.send_error(req_id, code, "Prompt error (401024 input tokens, limit 401 tokens)",
                                {"code": "context_length_exceeded", "details": "Request too large: fixture-secret"})
                return
            if "reject-length-text-fixture" in lower or "unknown-length-text-fixture" in lower:
                code = -32602 if "reject-length-text-fixture" in lower else -32603
                self.send_error(req_id, code, "Input too long: 401 tokens; limit 400; fixture-secret")
                return
            if "reject-auth-text-fixture" in lower:
                self.send_error(req_id, -32602, "401 Unauthorized: fixture-secret",
                                {"hint": "Input too long: fixture-secret"})
                return
            if "reject-auth-code-fixture" in lower:
                self.send_error(req_id, -32602, "Input too long: 401 tokens; fixture-secret",
                                {"code": "auth_required"})
                return
            if "reject-auth-echo-fixture" in lower or "unknown-auth-echo-fixture" in lower:
                code = -32602 if "reject-auth-echo-fixture" in lower else -32603
                message = "HTTP 401 Unauthorized: API key invalid. Request echo: Input too long: fixture-secret"
                if code == -32603:
                    message = f"Provider request failed ({message})"
                self.send_error(req_id, code, message)
                return
            if "reject-length-echo-fixture" in lower:
                self.send_error(req_id, -32602,
                                "Input too long: 401 tokens, limit 400. Request echo: HTTP 401 Unauthorized: fixture-secret")
                return

            if self.args.delay_prompt > 0:
                if cancel_event.wait(timeout=self.args.delay_prompt):
                    self.send_result(req_id, {"stopReason": "cancelled"})
                    return

            if self.args.v1_extended and lower.startswith("verify-client-"):
                try:
                    if lower == "verify-client-read-only":
                        self.verify_client_read_only(session_id)
                    elif lower == "verify-client-terminal-only":
                        self.start_leftover_terminal(session_id)
                    else:
                        self.verify_client_services(session_id)
                    self.send_update(session_id, {"sessionUpdate": "agent_message_chunk",
                                      "content": {"type": "text", "text": "client services verified"}})
                    self.send_result(req_id, {"stopReason": "end_turn"})
                except (AssertionError, KeyError, TypeError) as error:
                    self.record_receipt("client fixture failure", {"detail": repr(error)})
                    self.send_error(req_id, -32603, f"Fixture client services failure: {error!r}")
                return

            if "malformed" in lower:
                self.send_raw("{not valid json")
                return

            if "crash-worker" in lower:
                subprocess.Popen(
                    [sys.executable, __file__, "--worker"],
                    start_new_session=True,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                time.sleep(0.1)
                self.send_update(session_id, {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "crash-worker-tool",
                    "title": "Run background worker",
                    "kind": "execute",
                    "status": "in_progress",
                    "rawInput": {"command": "heartbeat"},
                })
                time.sleep(0.1)
                os._exit(1)

            if "crash" in lower:
                os._exit(1)

            if "auth-error" in lower:
                self.send_error(
                    req_id,
                    -32000,
                    "401 Unauthorized Bearer sk-fake-acp-secret",
                    {"code": "auth_required"},
                )
                return

            if "refusal" in lower:
                self.send_result(req_id, {"stopReason": "refusal"})
                return

            if "max-tokens" in lower:
                self.send_update(session_id, {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "Partial response before token cap."},
                })
                self.send_result(req_id, {"stopReason": "max_tokens"})
                return

            if "slow" in lower or "cancel-me" in lower:
                self.send_update(session_id, {
                    "sessionUpdate": "agent_thought_chunk",
                    "content": {"type": "text", "text": "Starting long-running operation..."},
                })
                self.send_update(session_id, {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "slow-tool-1",
                    "title": "Long running task",
                    "kind": "execute",
                    "status": "in_progress",
                    "rawInput": {"command": "sleep 15"},
                })
                self.send_update(session_id, {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "Working on long task..."},
                })
                cancelled = cancel_event.wait(timeout=15.0)
                if cancelled:
                    self.send_update(session_id, {
                        "sessionUpdate": "tool_call_update",
                        "toolCallId": "slow-tool-1",
                        "status": "failed",
                        "content": [{"type": "content", "content": {"type": "text", "text": "Cancelled"}}],
                    })
                    self.send_result(req_id, {"stopReason": "cancelled"})
                else:
                    self.send_result(req_id, {"stopReason": "end_turn"})
                return

            if "approval" in lower or "permission" in lower:
                tool_id = "perm-tool-1"
                id_only = "id-only" in lower
                with self.state_lock:
                    cwd = self.sessions.get(session_id, {}).get("cwd", os.getcwd())
                self.send_update(session_id, {
                    "sessionUpdate": "tool_call",
                    "toolCallId": tool_id,
                    "title": "Edit Sources/App.swift",
                    "kind": "edit",
                    "status": "pending",
                    "rawInput": {"path": "Sources/App.swift"},
                    **({"content": [
                        {"type": "diff", "path": os.path.join(cwd, "Sources/App.swift"),
                         "oldText": "let enabled = false\n", "newText": "let enabled = true\n"},
                        {"type": "diff", "path": os.path.join(cwd, "Tests/AppTests.swift"),
                         "oldText": None, "newText": "// Added test file\n"},
                    ]} if id_only else {"locations": [{"path": "Sources/App.swift", "line": 12}]}),
                })
                use_string_id = (self.args.permission_id_type == "string") or ("permission-string" in lower)
                reply = self.send_client_request(
                    "session/request_permission",
                    {
                        "sessionId": session_id,
                        "toolCall": {"toolCallId": tool_id} if id_only else {
                            "toolCallId": tool_id,
                            "title": "Edit Sources/App.swift",
                            "kind": "edit",
                            "status": "pending",
                            "rawInput": {"path": "Sources/App.swift"},
                            "locations": [{"path": "Sources/App.swift", "line": 12}],
                            "content": [
                                {
                                    "type": "diff",
                                    "path": "Sources/App.swift",
                                    "oldText": "let enabled = false\n",
                                    "newText": "let enabled = true\n",
                                }
                            ],
                        },
                        "options": [
                            {"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
                            {"optionId": "allow_always", "name": "Always allow", "kind": "allow_always"},
                            {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
                            {"optionId": "reject_always", "name": "Always reject", "kind": "reject_always"},
                        ],
                    },
                    use_string_id=use_string_id,
                    cancel_event=cancel_event,
                )
                if cancel_event.is_set() or reply is None:
                    self.send_result(req_id, {"stopReason": "cancelled"})
                    return
                outcome = ((reply.get("result") or {}).get("outcome")) or {}
                outcome_kind = outcome.get("outcome")
                if outcome_kind == "cancelled":
                    self.send_update(session_id, {
                        "sessionUpdate": "tool_call_update",
                        "toolCallId": tool_id,
                        "status": "failed",
                        "content": [{"type": "content", "content": {"type": "text", "text": "Permission cancelled"}}],
                    })
                    self.send_result(req_id, {"stopReason": "cancelled"})
                    return
                option_id = outcome.get("optionId", "")
                approved = option_id.startswith("allow")
                self.send_update(session_id, {
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": tool_id,
                    "status": "completed" if approved else "failed",
                    "content": [
                        {"type": "content", "content": {"type": "text", "text": f"Outcome: {option_id}"}},
                        {
                            "type": "diff",
                            "path": "Sources/App.swift",
                            "oldText": "let enabled = false\n",
                            "newText": "let enabled = true\n",
                        },
                    ],
                })
                final_text = f"Approved via {option_id}" if approved else f"Rejected via {option_id}"
                self.send_update(session_id, {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": final_text},
                })
                self._append_history(session_id, combined, final_text)
                self.send_result(req_id, {"stopReason": "end_turn"})
                return

            # Standard streaming turn: thought + plan (optional) + tool_call/diff + message chunks + usage
            self.send_update(session_id, {
                "sessionUpdate": "agent_thought_chunk",
                "content": {"type": "text", "text": "Inspecting request and preparing response."},
            })

            if "plan" in lower:
                self.send_update(session_id, {
                    "sessionUpdate": "plan",
                    "entries": [
                        {"content": "Analyze request", "priority": "high", "status": "completed"},
                        {"content": "Apply edit", "priority": "medium", "status": "in_progress"},
                        {"content": "Summarize result", "priority": "low", "status": "pending"},
                    ],
                })

            if "diff" in lower or "tool" in lower:
                tool_id = "edit-tool-1"
                self.send_update(session_id, {
                    "sessionUpdate": "tool_call",
                    "toolCallId": tool_id,
                    "title": "Edit Sources/Demo.swift",
                    "kind": "edit",
                    "status": "in_progress",
                    "rawInput": {"path": "Sources/Demo.swift"},
                })
                self.send_update(session_id, {
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": tool_id,
                    "status": "completed",
                    "content": [
                        {"type": "content", "content": {"type": "text", "text": "Applied edit to Sources/Demo.swift"}},
                        {
                            "type": "diff",
                            "path": "Sources/Demo.swift",
                            "oldText": "let value = 1\n",
                            "newText": "let value = 2\n",
                        },
                    ],
                })

            chunk_one = "Synthetic ACP reply: "
            chunk_two = combined if combined else "ok"
            if image_count > 0:
                chunk_two += f" [images={image_count}]"

            self.send_update(session_id, {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": chunk_one},
            })
            self.send_update(session_id, {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": chunk_two},
            })
            self.send_update(session_id, {
                "sessionUpdate": "usage_update",
                "used": 1200,
                "size": 200000,
                "cost": {"amount": 0.0042, "currency": "USD"},
            })

            self._append_history(session_id, combined, chunk_one + chunk_two)
            self.send_result(req_id, {
                "stopReason": "end_turn",
                "usage": {
                    "inputTokens": 800,
                    "outputTokens": 400,
                    "cachedReadTokens": 200,
                    "totalTokens": 1200,
                },
            })
        finally:
            with self.state_lock:
                if self.active_cancel_events.get(session_id) is cancel_event:
                    self.active_cancel_events.pop(session_id, None)

    def verify_client_services(self, session_id):
        def request(method, session=session_id, **params):
            response = self.send_client_request(method, {"sessionId": session, **params})
            assert response is not None, method
            self.record_receipt(method, {"error": response.get("error"), "result": response.get("result")})
            return response

        path = str(pathlib.Path.cwd().resolve() / "fixture.txt")
        assert request("fs/write_text_file", path=path, content="first\r\nsecond\n")["result"] == {}
        assert request("fs/read_text_file", path=path, line=2, limit=1)["result"] == {"content": "second\n"}
        assert "error" in request("fs/read_text_file", session="unrelated", path=path)
        assert "error" in request("fs/read_text_file", path=str(pathlib.Path.cwd().resolve() / "escape" / "outside.txt"))
        config = str(pathlib.Path.cwd().resolve() / "AGENTS.md")
        assert request("fs/write_text_file", path=config, content="# Fixture rules")["result"] == {}
        assert request("fs/read_text_file", path=config)["result"]["content"] == "# Fixture rules"
        terminal = request("terminal/create", command="/usr/bin/printf", args=["åååEND"], outputByteLimit=4)
        terminal_id = terminal["result"]["terminalId"]
        assert request("terminal/wait_for_exit", terminalId=terminal_id)["result"]["exitCode"] == 0
        output = request("terminal/output", terminalId=terminal_id)["result"]
        assert output["output"] == "END" and output["truncated"], output
        assert request("terminal/release", terminalId=terminal_id)["result"] == {}
        assert "error" in request("terminal/output", terminalId=terminal_id)
        long_running = request("terminal/create", command="/bin/sleep", args=["100"])["result"]["terminalId"]
        assert request("terminal/kill", terminalId=long_running)["result"] == {}
        assert request("terminal/output", terminalId=long_running)["result"]["exitStatus"] is not None
        assert request("terminal/release", terminalId=long_running)["result"] == {}
        self.start_leftover_terminal(session_id)

    def start_leftover_terminal(self, session_id):
        params = {"sessionId": session_id, "command": "/bin/sh",
                  "args": ["-c", 'printf "%s" "$$" > terminal.pid; exec /bin/sleep 100']}
        reply = self.send_client_request("terminal/create", params)
        assert reply is not None and "terminalId" in reply["result"]

    def verify_client_read_only(self, session_id):
        path = str(pathlib.Path.cwd().resolve() / "fixture.txt")
        def request(method, **params):
            reply = self.send_client_request(method, {"sessionId": session_id, **params})
            assert reply is not None, method
            return reply
        assert "content" in request("fs/read_text_file", path=path)["result"]
        assert request("fs/write_text_file", path=path, content="not written")["error"]["code"] == -32601
        assert request("terminal/create", command="/bin/echo")["error"]["code"] == -32601

    def _append_history(self, session_id, user_text, assistant_text):
        with self.state_lock:
            session = self.sessions.get(session_id)
            if session is None:
                return
            session["history"].append({"role": "user", "text": user_text})
            session["history"].append({"role": "assistant", "text": assistant_text})
            self.save_persisted_state()

    def handle_session_cancel(self, params):
        if self.args.ignore_cancel:
            return
        session_id = params.get("sessionId")
        with self.state_lock:
            event = self.active_cancel_events.get(session_id)
        if event is not None:
            event.set()

    def handle_client_response(self, message):
        req_id = message.get("id")
        id_key = (type(req_id).__name__, req_id)
        with self.state_lock:
            entry = self.pending_client_responses.get(id_key)
        if entry is not None:
            done, box = entry
            box["response"] = message
            done.set()

    def serve(self):
        for raw_line in sys.stdin:
            line = raw_line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                self.send_error(None, -32700, "Parse error")
                continue

            if not isinstance(message, dict):
                self.send_error(None, -32600, "Invalid Request")
                continue

            has_method = "method" in message
            has_id = "id" in message

            # Response to an Agent -> Client request (e.g., session/request_permission)
            if has_id and not has_method:
                self.handle_client_response(message)
                continue

            method = message.get("method")
            params = message.get("params") or {}
            if not isinstance(params, dict):
                if has_id:
                    self.send_error(message["id"], -32602, "Invalid params")
                continue

            # Notification (no id)
            if not has_id:
                if method == "session/cancel":
                    self.handle_session_cancel(params)
                elif method == "$/cancel_request":
                    target = params.get("requestId")
                    self.record_receipt("$/cancel_request", {"requestId": target})
                    if target in self.pending_authentication:
                        self.pending_authentication.remove(target)
                        self.send_error(target, -32800, "Cancelled")
                continue

            req_id = message["id"]
            if method == "initialize":
                self.handle_initialize(req_id, params)
            elif method == "authenticate":
                self.handle_authenticate(req_id, params)
            elif self.args.v1_extended and method == "logout":
                self.authenticated = False
                self.send_result(req_id, {})
            elif self.args.v1_extended and method in ("session/list", "session/resume", "session/delete", "session/close"):
                self.handle_session_management(method, req_id, params)
            elif method == "session/new":
                self.handle_session_new(req_id, params)
            elif method == "session/load":
                self.handle_session_load(req_id, params)
            elif method == "session/prompt":
                self.handle_session_prompt(req_id, params)
            elif method == "session/set_mode":
                self.handle_set_mode(req_id, params)
            elif method == "session/set_model":
                self.handle_set_model(req_id, params)
            elif method == "session/set_config_option":
                self.handle_set_config_option(req_id, params)
            else:
                self.send_error(req_id, -32601, f"Method not found: {method}")



def terminal_login(marker):
    if (
        os.environ.get("FAKE_LOGIN_FLAG") != "terminal"
        or os.environ.get("FAKE_ISOLATION_FLAG") != "agent"
        or not all(os.isatty(fd) for fd in (0, 1, 2))
    ):
        return 2
    # /dev/tty requires a controlling terminal, not just redirected slave fds.
    with open("/dev/tty", "r", encoding="utf-8") as tty:
        print("Fixture login ready", flush=True)
        if tty.readline().strip() != "synthetic-login":
            return 3
    pathlib.Path(marker).write_text("authenticated", encoding="utf-8")
    return 0


def verify_login_supervisor(helper):
    import errno
    import pty
    import select
    import signal
    import tempfile
    import uuid

    for cancel in (False, True):
        with tempfile.TemporaryDirectory(prefix="pikachu-login-probe-") as temp:
            status = pathlib.Path(temp) / "status.json"
            marker = pathlib.Path(temp) / "state"
            pipe = pathlib.Path(temp) / "agent-environment"
            os.mkfifo(pipe, 0o600)
            parent = os.getpid()
            pid, master = pty.fork()
            if pid == 0:
                args = [helper, str(status), str(uuid.uuid4()), str(parent), "--terminal-login",
                        sys.executable, __file__, "--terminal-auth-state", str(marker), "--terminal-login"]
                os.execve(helper, args, {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color",
                                         "FAKE_ISOLATION_FLAG": "supervisor"})
            try:
                payload = json.dumps({"FAKE_LOGIN_FLAG": "terminal", "FAKE_ISOLATION_FLAG": "agent"}).encode()
                deadline = time.monotonic() + 5
                while True:
                    try:
                        descriptor = os.open(pipe, os.O_WRONLY | os.O_NONBLOCK)
                        break
                    except OSError as error:
                        if error.errno != errno.ENXIO or time.monotonic() >= deadline:
                            raise
                        time.sleep(0.01)
                with os.fdopen(descriptor, "wb") as writer:
                    writer.write(len(payload).to_bytes(4, "big") + payload)
                output = b""
                deadline = time.monotonic() + 10
                while b"Fixture login ready" not in output:
                    ready, _, _ = select.select([master], [], [], max(0, deadline - time.monotonic()))
                    if not ready:
                        raise RuntimeError("PTY login prompt timed out")
                    output += os.read(master, 4096)
                supervisor_env = subprocess.check_output(["/bin/ps", "eww", "-p", str(pid)], text=True)
                assert "FAKE_ISOLATION_FLAG=supervisor" in supervisor_env
                assert "FAKE_LOGIN_FLAG=terminal" not in supervisor_env
                if cancel:
                    os.kill(pid, signal.SIGTERM)
                else:
                    os.write(master, b"synthetic-login\n")
                result = None
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    waited, exit_status = os.waitpid(pid, os.WNOHANG)
                    if waited:
                        result = os.waitstatus_to_exitcode(exit_status)
                        break
                    available, _, _ = select.select([master], [], [], 0.02)
                    if available:
                        try:
                            os.read(master, 4096)
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                assert result == 0, (cancel, result, marker.exists(), status.read_text() if status.exists() else "")
                report = json.loads(status.read_text())
                assert report["state"] == "clean" and report["remaining"] == 0, report
                assert marker.exists() != cancel, report
                if cancel:
                    assert report["reason"] == "supervisorStopRequested", report
                else:
                    assert report["runtimeExitStatus"] == 0 and not report["runtimeExitBySignal"], report
                try:
                    os.kill(report["runtimePID"], 0)
                except OSError as error:
                    assert error.errno == errno.ESRCH
                else:
                    raise RuntimeError("PTY child remained after supervisor completion")
            finally:
                os.close(master)
                try:
                    waited, _ = os.waitpid(pid, os.WNOHANG)
                    if not waited:
                        try:
                            os.killpg(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        os.waitpid(pid, 0)
                except ChildProcessError:
                    pass



def main():
    args = parse_args()
    if args.terminal_supervisor_test:
        verify_login_supervisor(args.terminal_supervisor_test)
        return
    if args.terminal_login:
        sys.exit(terminal_login(args.terminal_auth_state))
    if args.worker:
        run_worker()
        return
    FakeACPServer(args).serve()


if __name__ == "__main__":
    main()
