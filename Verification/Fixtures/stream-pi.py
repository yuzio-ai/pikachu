#!/usr/bin/python3
"""Bounded transport/load peer; private generated data, no model/provider."""
import json, os, sys, threading, time
if "--version" in sys.argv:
    print("1.5.2"); raise SystemExit(0)
lock = threading.Lock()
running = False
stopped = threading.Event()
def emit(record):
    with lock:
        sys.stdout.write(json.dumps(record, ensure_ascii=False) + "\n"); sys.stdout.flush()
def load():
    global running
    emit({"type":"agent_start"})
    emit({"type":"message_start","message":{"role":"assistant"}})
    emit({"type":"tool_execution_start","toolCallId":"large","toolName":"bash","args":{"command":"generated 10 MiB fixture"}})
    # Exactly 10 MiB of cumulative tool text, 64 KiB snapshots at the wire.
    total = 10 * 1024 * 1024
    for offset in range(0, total, 65536):
        if stopped.is_set(): break
        emit({"type":"tool_execution_update","toolCallId":"large","toolName":"bash","partialResult":{"content":[{"type":"text","text":"x" * 65536}]}})
        for _ in range(20):
            emit({"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"stream "}})
        time.sleep(.04)
    emit({"type":"tool_execution_end","toolCallId":"large","toolName":"bash","result":{"content":[{"type":"text","text":"x" * total}]},"isError":False})
    emit({"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"canonical load result"}]}})
    running = False
    emit({"type":"agent_settled","aborted":stopped.is_set()})
for line in sys.stdin:
    c = json.loads(line); kind = c["type"]; data = {}
    if kind == "get_state":
        data = {"sessionId":"load-stream","model":{"id":"fixture","name":"Load Fixture","provider":"fixture"},"isStreaming":running,"pendingMessageCount":0,"thinkingLevel":"off"}
    elif kind == "get_session_stats":
        data = {"sessionId":"load-stream","tokens":{"input":100,"output":200,"cacheRead":50,"cacheWrite":0,"total":350},"cost":0,"contextUsage":{"tokens":None,"contextWindow":200000,"percent":None}}
    elif kind == "get_available_models": data = {"models":[]}
    elif kind == "get_available_thinking_levels": data = {"levels":["off"]}
    elif kind == "prompt":
        if running: data = {"disposition":"queued"}
        else:
            running = True; stopped.clear(); data = {"disposition":"started"}
            emit({"type":"response","id":c["id"],"success":True,"data":data})
            threading.Thread(target=load, daemon=True).start(); continue
    elif kind == "clear_queue": data = {"steering":[],"followUp":[]}
    elif kind == "abort": stopped.set(); running = False
    emit({"type":"response","id":c.get("id"),"success":True,"data":data})
