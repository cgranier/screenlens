#!/usr/bin/env python3
"""Capture the focused Hyprland monitor into a private temp PNG and emit metadata JSON."""

import glob
import json
import os
import struct
import subprocess
import sys
import time

TMP_PREFIX = "/tmp/omarchy-screenlens-"
STALE_SECONDS = 900  # Keep captures for 15 minutes so agent handoffs can read them.


def cleanup_stale() -> None:
    now = time.time()
    for path in glob.glob(f"{TMP_PREFIX}*.png") + glob.glob(f"{TMP_PREFIX}*.json") + glob.glob(f"{TMP_PREFIX}*.md"):
        try:
            if now - os.path.getmtime(path) > STALE_SECONDS:
                os.unlink(path)
        except OSError:
            pass


def run_json(cmd: list[str]) -> object:
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def focused_monitor() -> dict:
    monitors = run_json(["hyprctl", "monitors", "-j"])
    if isinstance(monitors, list):
        for mon in monitors:
            if isinstance(mon, dict) and mon.get("focused"):
                return mon
        if monitors and isinstance(monitors[0], dict):
            return monitors[0]
    return {}


def active_window() -> dict:
    win = run_json(["hyprctl", "activewindow", "-j"])
    if not isinstance(win, dict):
        return {"class": "", "title": ""}
    return {
        "class": str(win.get("class") or "")[:120],
        "title": str(win.get("title") or "")[:240],
    }


def read_png_dimensions(path: str) -> tuple[int, int]:
    with open(path, "rb") as f:
        header = f.read(24)
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        return 0, 0
    width, height = struct.unpack(">II", header[16:24])
    return int(width), int(height)


def make_private_path(suffix: str) -> str:
    uid = os.getuid()
    ts_ms = int(time.time() * 1000)
    path = f"{TMP_PREFIX}{uid}-{ts_ms}-{os.getpid()}{suffix}"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.close(fd)
    return path


def main() -> int:
    cleanup_stale()
    mon = focused_monitor()
    win = active_window()

    mon_name = str(mon.get("name") or "")
    scale = float(mon.get("scale") or 1.0)
    if scale <= 0:
        scale = 1.0
    transform = int(mon.get("transform") or 0)
    raw_w = int(mon.get("width") or 0)
    raw_h = int(mon.get("height") or 0)
    if transform in (1, 3, 5, 7):
        raw_w, raw_h = raw_h, raw_w

    image_path = make_private_path(".png")
    grim_cmd = ["grim"]
    if mon_name:
        grim_cmd.extend(["-o", mon_name])
    grim_cmd.append(image_path)

    proc = subprocess.run(grim_cmd, capture_output=True, text=True, timeout=10)
    if proc.returncode != 0:
        try:
            os.unlink(image_path)
        except OSError:
            pass
        err = (proc.stderr or proc.stdout or "grim failed").strip()
        print(json.dumps({"ok": False, "error": err}), flush=True)
        return 1

    img_w, img_h = read_png_dimensions(image_path)
    logical_w = int(round(raw_w / scale)) if raw_w else int(round(img_w / scale))
    logical_h = int(round(raw_h / scale)) if raw_h else int(round(img_h / scale))

    print(
        json.dumps(
            {
                "ok": True,
                "imagePath": image_path,
                "monitor": mon_name,
                "scale": scale,
                "logicalWidth": logical_w,
                "logicalHeight": logical_h,
                "imageWidth": img_w,
                "imageHeight": img_h,
                "windowClass": win["class"],
                "windowTitle": win["title"],
            }
        ),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
