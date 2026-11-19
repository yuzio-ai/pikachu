"""Generate deterministic UI benchmark inputs without calling Pi or a model."""
import json
import pathlib
import sys

destination = pathlib.Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
for count, name in [(100, "ordinary"), (5000, "long")]:
    path = destination / f"{name}.jsonl"
    with path.open("w") as stream:
        stream.write(json.dumps({"type": "session", "version": 3, "id": f"m0-{name}",
                                 "timestamp": "2026-11-18T00:00:00Z", "cwd": "/m0-fixture"}) + "\n")
        for index in range(count):
            mode = index % 3
            if mode == 0:
                message = {"role": "user", "content": f"Fixture question {index}: 猫 😺", "timestamp": index}
            elif mode == 1:
                message = {"role": "assistant", "content": [{"type": "text", "text": "```swift\nlet value = 1\n```\n" + "Fixture response. " * 20}, {"type": "toolCall", "id": f"call-{index}", "name": "read", "arguments": {"path": "fixture.txt"}}],
                           "api": "openai-responses", "provider": "fixture", "model": "fixture",
                           "stopReason": "toolUse", "timestamp": index}
            else:
                message = {"role": "toolResult", "toolCallId": f"call-{index-1}", "toolName": "read", "content": [{"type": "text", "text": "Fixture output.\n" * 30}], "isError": False, "timestamp": index}
            stream.write(json.dumps({"type": "message", "id": str(index), "parentId": str(index-1) if index else None,
                                     "timestamp": "2026-11-18T00:00:00Z", "message": message}, ensure_ascii=False) + "\n")
(destination / "large-output.txt").write_bytes(b"x" * (10 * 1024 * 1024))
print("Generated 100/5000-message histories and 10 MiB output fixture.")
