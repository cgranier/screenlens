#!/usr/bin/env python3
"""Superwhisper CLI bridge for ScreenLens voice dictation."""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time


def find_superwhisper() -> str:
    local_bin = os.path.expanduser("~/.local/bin/superwhisper")
    if os.path.isfile(local_bin) and os.access(local_bin, os.X_OK):
        return local_bin
    found = shutil.which("superwhisper")
    return found or ""


def run_sw(binary: str, subargs: list[str], timeout: float = 10.0) -> tuple[int, dict, str]:
    proc = subprocess.run([binary, *subargs], capture_output=True, text=True, timeout=timeout)
    raw = (proc.stdout or "").strip()
    parsed = {}
    if raw:
        try:
            obj = json.loads(raw)
            if isinstance(obj, dict):
                parsed = obj
        except json.JSONDecodeError:
            parsed = {"raw": raw}
    err = (proc.stderr or "").strip()
    return proc.returncode, parsed, err


def extract_text(payload: dict) -> str:
    if not isinstance(payload, dict):
        return ""
    for key in ("text", "result", "transcript", "transcription", "content"):
        val = payload.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    for nested_key in ("lastDictation", "dictation", "data", "entry"):
        nested = payload.get(nested_key)
        if isinstance(nested, dict):
            found = extract_text(nested)
            if found:
                return found
    raw = payload.get("raw")
    return raw.strip() if isinstance(raw, str) else ""


def extract_signature(payload: dict) -> str:
    if not isinstance(payload, dict):
        return ""
    for key in ("timestamp", "id", "createdAt", "completedAt"):
        val = payload.get(key)
        if val is not None:
            return f"{key}:{val}"
    for nested_key in ("lastDictation", "dictation", "data", "entry"):
        nested = payload.get(nested_key)
        if isinstance(nested, dict):
            sig = extract_signature(nested)
            if sig:
                return sig
    return extract_text(payload)[:120]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["start", "stop", "cancel", "status"])
    parser.add_argument("--baseline", default="")
    args = parser.parse_args()

    binary = find_superwhisper()
    if not binary:
        print(json.dumps({"ok": False, "error": "superwhisper CLI not found"}), flush=True)
        return 1

    try:
        if args.action == "status":
            code, data, err = run_sw(binary, ["status"])
            if code != 0:
                print(json.dumps({"ok": False, "error": err or "status failed"}), flush=True)
                return 1
            print(json.dumps({"ok": True, "status": data}), flush=True)
            return 0

        if args.action == "cancel":
            run_sw(binary, ["cancel"])
            print(json.dumps({"ok": True, "phase": "idle"}), flush=True)
            return 0

        if args.action == "start":
            _, prev_read, _ = run_sw(binary, ["read"])
            baseline = extract_signature(prev_read)
            code, data, err = run_sw(binary, ["start"])
            if code != 0:
                msg = err or str(data.get("error") or data.get("message") or "could not start recording")
                print(json.dumps({"ok": False, "error": msg}), flush=True)
                return 1
            print(json.dumps({"ok": True, "phase": "recording", "baseline": baseline}), flush=True)
            return 0

        if args.action == "stop":
            code, data, err = run_sw(binary, ["stop"])
            if code != 0:
                msg = err or str(data.get("error") or data.get("message") or "could not stop recording")
                print(json.dumps({"ok": False, "error": msg}), flush=True)
                return 1

            deadline = time.monotonic() + 12.0
            final_text = ""
            settle_deadline = 0.0
            while time.monotonic() < deadline:
                _, st, _ = run_sw(binary, ["status"])
                phase = str(st.get("phase") or st.get("state") or "").lower()
                _, rd, _ = run_sw(binary, ["read"])
                sig = extract_signature(rd)
                txt = extract_text(rd)
                if txt and (not args.baseline or sig != args.baseline):
                    final_text = txt
                    if phase in ("idle", "ready", ""):
                        # Give Superwhisper's Wayland auto-paste / text-commit a brief
                        # moment to land in the focused field before we return.
                        time.sleep(0.15)
                        break
                    if settle_deadline == 0.0:
                        settle_deadline = time.monotonic() + 1.5
                    elif time.monotonic() >= settle_deadline:
                        break
                elif phase in ("idle", "ready", "") and time.monotonic() > deadline - 10.5:
                    if txt and (not args.baseline or sig != args.baseline):
                        final_text = txt
                    break
                time.sleep(0.15)

            if not final_text:
                _, rd, _ = run_sw(binary, ["read"])
                sig = extract_signature(rd)
                txt = extract_text(rd)
                if txt and (not args.baseline or sig != args.baseline):
                    final_text = txt

            print(json.dumps({"ok": True, "text": final_text[:4000]}), flush=True)
            return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), flush=True)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
