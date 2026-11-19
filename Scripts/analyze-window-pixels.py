#!/usr/bin/env python3
"""Reduce Pikachu's own-window pixel stream to reproducible acceptance samples."""
import argparse
import itertools
import json
import math
from pathlib import Path
from statistics import median


def read_jsonl(path):
    with path.open() as source:
        return [json.loads(line) for line in source]


def milliseconds(start, end):
    return (end - start) * 1000


def summarize(values):
    ordered = sorted(values)
    return {
        "count": len(values),
        "p95MS": ordered[math.ceil(len(ordered) * .95) - 1] if ordered else None,
        "maxMS": ordered[-1] if ordered else None,
    }


def pixel_frames(frames, pid, start=-math.inf, end=math.inf):
    return [
        frame for frame in frames
        if frame["pid"] == pid and "transcriptHash" in frame.get("pixelStats", {})
        and start <= frame["displayTime"] < end
    ]


def fingerprint(frame):
    return frame["pixelStats"]["transcriptHash"]


def scroll_samples(events, frames, pid):
    marks = [event for event in events if event["pid"] == pid and event["name"].startswith("scroll-motion-")]
    if len(marks) % 2:
        raise ValueError("Incomplete continuous scroll interval")
    trials = []
    for begin, end in zip(marks[::2], marks[1::2]):
        if begin["name"] != "scroll-motion-start" or end["name"] != "scroll-motion-end":
            raise ValueError("Unpaired continuous scroll marks")
        captured = pixel_frames(frames, pid, begin["uptime"], end["uptime"])
        changes = [next(group) for _, group in itertools.groupby(captured, key=fingerprint)]
        timestamps = [frame["displayTime"] for frame in changes]
        intervals = [milliseconds(a, b) for a, b in zip(timestamps, timestamps[1:])]
        trials.append({
            **summarize(intervals), "pid": pid, "speedPointsPerSecond": int(begin["tag"]),
            "start": begin["uptime"], "end": end["uptime"],
            "completeFrames": len(captured), "presentedChanges": len(changes),
            "above20ms": sum(value > 20 for value in intervals),
            "captureDeliveryMaxMS": max(
                (milliseconds(frame["displayTime"], frame["deliveryUptime"]) for frame in captured),
                default=None,
            ),
            "changeTimes": timestamps,
        })
    return trials


def key_samples(events, frames, pid):
    keys = [event for event in events if event["pid"] == pid and event["name"] == "key-event"]
    if not keys:
        raise ValueError("No key events for input sample")
    captured = pixel_frames(frames, pid, keys[0]["uptime"], keys[-1]["uptime"] + .75)
    # Final, visually verified canonical transcript has a stable fingerprint.
    # Keep the entire key sequence, including any keys after that result.
    final_hash = fingerprint(captured[-1])
    stable = next(
        frame for frame in reversed(captured)
        if fingerprint(frame) != final_hash
    )
    first_final = next(frame["displayTime"] for frame in captured if frame["displayTime"] > stable["displayTime"])
    result = []
    for number, event in enumerate(keys, 1):
        # Reference run uses repeated ASCII m, dark appearance, SF default font
        # and 2x pixels. Right edge advances ~22.47 px per glyph. Minimum
        # neutral stroke ink prevents matching the caret or tinted focus effects.
        expected_right = number * 22.47 - 3
        following = keys[number]["uptime"] if number < len(keys) else event["uptime"] + .25
        match = next((
            frame for frame in captured
            if event["uptime"] <= frame["displayTime"] < following
            and abs(frame["pixelStats"].get("glyphRight", -100) - expected_right) <= 2
            and frame["pixelStats"].get("glyphInk", 0) > (number - 1) * 110 + 60
        ), None)
        result.append({
            "key": number, "eventTime": event["uptime"],
            "glyphDisplayTime": match["displayTime"] if match else None,
            "rightmostGlyphPixel": match["pixelStats"]["glyphRight"] if match else None,
            "latencyMS": milliseconds(event["uptime"], match["displayTime"]) if match else None,
            "beforeVisibleFinalOutput": event["uptime"] < first_final,
        })
    return {
        "pid": pid, "visibleFinalOutputTime": first_final,
        "keys": len(keys), "unmatched": sum(row["latencyMS"] is None for row in result),
        "all": summarize([row["latencyMS"] for row in result if row["latencyMS"] is not None]),
        "beforeFinalOutput": summarize([
            row["latencyMS"] for row in result if row["latencyMS"] is not None and row["beforeVisibleFinalOutput"]
        ]),
        "samples": result,
    }


def history_samples(events, frames, pid, sessions, allow_missing_pixels):
    marks = [event for event in events if event["pid"] == pid and event["name"] == "history-select"]
    trials = []
    missing = []
    for index, mark in enumerate(marks):
        if sessions and mark["tag"] not in sessions:
            continue
        start = mark["uptime"]
        end = min(start + .65, marks[index + 1]["uptime"]) if index + 1 < len(marks) else start + .65
        captured = pixel_frames(frames, pid, start, end)
        if not captured and allow_missing_pixels:
            missing.append({"pid": pid, "session": mark["tag"], "selectTime": start})
            continue
        tag = "history:" + mark["tag"] + ":false:"
        drawn = next((
            draw for draw in events if draw["pid"] == pid and draw["tag"].startswith(tag)
            and start <= draw["uptime"] < end and not draw["tag"].endswith(":0")
        ), None)
        if not captured or not drawn:
            raise ValueError("Missing history presentation or full model projection")
        expected_hash = fingerprint(captured[-1])
        # Find the beginning of the stable suffix rather than any accidental
        # occurrence of the same hash while the previous history was visible.
        first = captured[-1]
        for frame in reversed(captured):
            if fingerprint(frame) != expected_hash:
                break
            first = frame
        trials.append({
            "pid": pid, "session": mark["tag"], "rows": int(drawn["tag"].split(":")[-1]),
            "selectTime": start, "fullModelClientDrawMS": milliseconds(start, drawn["uptime"]),
            "stableReadablePixelUpperMS": milliseconds(start, first["displayTime"]),
            "stableFingerprint": expected_hash,
        })
    return trials, missing


def summarize_history(trials):
    output = {}
    for rows in sorted({entry["rows"] for entry in trials}):
        cohort = [entry for entry in trials if entry["rows"] == rows]
        output[str(rows)] = {
            "stableReadableUpper": summarize([entry["stableReadablePixelUpperMS"] for entry in cohort]),
            "fullModelClientDraw": summarize([entry["fullModelClientDrawMS"] for entry in cohort]),
            "samples": cohort,
        }
    return output


def cold_samples(events, frames, pids):
    trials = []
    for pid in pids:
        editor = next(event for event in events if event["pid"] == pid and event["name"] == "first-editor-client-draw")
        rendered = next(frame for frame in pixel_frames(frames, pid, editor["uptime"])
                        if frame["pixelStats"].get("glyphInk", 0) > 200)
        trials.append({
            "pid": pid, "firstEditorPixelTime": rendered["displayTime"],
            "firstEditorPixelUpperMS": editor["processToClientDrawMS"] +
            milliseconds(editor["uptime"], rendered["displayTime"]),
        })
    return {**summarize([trial["firstEditorPixelUpperMS"] for trial in trials]), "samples": trials}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--scroll-pid", type=int)
    parser.add_argument("--input-pid", type=int)
    parser.add_argument("--history-pid", type=int, action="append")
    parser.add_argument("--history-session", action="append", help="Limit history evaluation to these fixture session IDs")
    parser.add_argument("--history-allow-missing-pixels", action="store_true",
                        help="Report uncaptured selections separately, for example after the capture cap")
    parser.add_argument("--cold-pids", nargs="+", type=int)
    args = parser.parse_args()
    events = read_jsonl(args.root / "events.jsonl")
    frames = read_jsonl(args.root / "pixels.jsonl")
    result = {"captureConfigurations": [frame for frame in frames if frame["kind"] == "start"]}
    capture_errors = [frame for frame in frames if frame["kind"] == "error"]
    if capture_errors:
        result["captureErrors"] = capture_errors
    if args.scroll_pid:
        result["scroll"] = scroll_samples(events, frames, args.scroll_pid)
    if args.input_pid:
        result["input"] = key_samples(events, frames, args.input_pid)
    if args.history_pid:
        trials, missing = [], []
        for pid in args.history_pid:
            captured, uncaptured = history_samples(events, frames, pid, args.history_session,
                                                   args.history_allow_missing_pixels)
            trials.extend(captured)
            missing.extend(uncaptured)
        result["history"] = summarize_history(trials)
        if missing:
            result["historyMissingPixels"] = missing
    if args.cold_pids:
        result["cold"] = cold_samples(events, frames, args.cold_pids)
    rss_path = args.root / "rss.jsonl"
    if rss_path.exists():
        rss = read_jsonl(rss_path)
        baseline = median(row["rssBytes"] for row in rss[:5])
        result["rss"] = {
            "pid": rss[0]["pid"], "count": len(rss), "baselineBytes": baseline,
            "peakDeltaBytes": max(row["rssBytes"] for row in rss) - baseline,
            "retainedDeltaBytes": median(row["rssBytes"] for row in rss[-10:]) - baseline,
        }
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
