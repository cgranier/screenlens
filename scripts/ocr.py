#!/usr/bin/env python3
"""Run Tesseract OCR on a screenshot or cropped region and emit word boxes or plain text."""

import argparse
import json
import os
import subprocess
import sys

MAX_WORDS = 3000
MAX_TEXT_CHARS = 32000
MIN_CONF = 20.0


def parse_crop(spec: str) -> tuple[int, int, int, int]:
    parts = [int(p.strip()) for p in spec.split(",")]
    if len(parts) != 4 or parts[2] <= 0 or parts[3] <= 0:
        raise ValueError(f"invalid crop spec: {spec}")
    return parts[0], parts[1], parts[2], parts[3]


def parse_tsv(tsv_text: str) -> list[dict]:
    words: list[dict] = []
    lines = tsv_text.splitlines()
    if len(lines) <= 1:
        return words

    for line in lines[1:]:
        cols = line.split("\t")
        if len(cols) < 12:
            continue
        if cols[0] != "5":  # Word level only.
            continue
        text = cols[11].strip()
        if not text:
            continue
        try:
            conf = float(cols[10])
            x = int(cols[6])
            y = int(cols[7])
            w = int(cols[8])
            h = int(cols[9])
            block = int(cols[2])
            par = int(cols[3])
            line_num = int(cols[4])
        except ValueError:
            continue
        if conf < MIN_CONF or w <= 0 or h <= 0:
            continue
        words.append(
            {
                "text": text[:200],
                "x": x,
                "y": y,
                "w": w,
                "h": h,
                "block": block,
                "par": par,
                "line": line_num,
                "conf": round(conf, 1),
            }
        )
        if len(words) >= MAX_WORDS:
            break
    return words


def cropped_png_bytes(image_path: str, crop: tuple[int, int, int, int], upscale: bool = False) -> bytes:
    x, y, w, h = crop
    geometry = f"{w}x{h}+{x}+{y}"
    cmd = ["magick", image_path, "-crop", geometry, "+repage"]
    if upscale:
        cmd.extend(["-resize", "200%"])
    cmd.append("png:-")
    proc = subprocess.run(cmd, capture_output=True, timeout=10)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", "replace").strip() or "magick crop failed")
    return proc.stdout


def run_tesseract_text(tess_input: str, input_bytes: bytes | None, langs: str, psm: str) -> str:
    cmd = [
        "tesseract",
        tess_input,
        "stdout",
        "--oem",
        "1",
        "--psm",
        psm,
        "-l",
        langs,
        "--dpi",
        "300",
        "-c",
        "preserve_interword_spaces=1",
    ]
    proc = subprocess.run(cmd, input=input_bytes, capture_output=True, timeout=20)
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip() or "tesseract failed"
        raise RuntimeError(err)
    return proc.stdout.decode("utf-8", "replace").strip()[:MAX_TEXT_CHARS]


def extract_text_with_fallbacks(
    image_path: str,
    crop_tuple: tuple[int, int, int, int] | None,
    langs: str,
) -> str:
    if crop_tuple is None:
        return run_tesseract_text(image_path, None, langs, "3")

    raw_bytes = cropped_png_bytes(image_path, crop_tuple, upscale=False)
    for psm in ("6", "3", "11"):
        text = run_tesseract_text("stdin", raw_bytes, langs, psm)
        if text:
            return text

    # Fallback pass: 2x upscale helps Tesseract read small or tightly cropped UI text.
    up_bytes = cropped_png_bytes(image_path, crop_tuple, upscale=True)
    for psm in ("6", "11"):
        text = run_tesseract_text("stdin", up_bytes, langs, psm)
        if text:
            return text
    return ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("--crop", default="", help="x,y,w,h in image pixels")
    parser.add_argument("--text-only", action="store_true")
    parser.add_argument("--copy", action="store_true")
    args = parser.parse_args()

    if not os.path.isfile(args.image):
        print(json.dumps({"ok": False, "error": "image file not found"}), flush=True)
        return 1

    langs = os.environ.get("OMARCHY_OCR_LANGS", "")
    if not langs:
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            from config import load_config as load_sl_config

            cfg_langs = load_sl_config().get("ocrLanguages") or ["eng"]
            langs = "+".join(cfg_langs)
        except Exception:
            langs = "eng"
    langs = langs or "eng"

    try:
        crop_tuple = parse_crop(args.crop) if args.crop else None

        if args.text_only:
            text = extract_text_with_fallbacks(args.image, crop_tuple, langs)
            if args.copy and text:
                try:
                    # Detach stdio so wl-copy's forked Wayland clipboard daemon
                    # never holds stdout open or fails JSON extraction output.
                    subprocess.run(
                        ["wl-copy"],
                        input=text.encode("utf-8"),
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=5,
                        check=False,
                    )
                except Exception:
                    pass
            print(json.dumps({"ok": True, "text": text}), flush=True)
            return 0

        input_bytes = cropped_png_bytes(args.image, crop_tuple) if crop_tuple else None
        tess_input = "stdin" if crop_tuple else args.image

        cmd = [
            "tesseract",
            tess_input,
            "stdout",
            "--oem",
            "1",
            "--psm",
            "3",
            "-l",
            langs,
            "tsv",
        ]
        proc = subprocess.run(cmd, input=input_bytes, capture_output=True, timeout=20)
        if proc.returncode != 0:
            err = proc.stderr.decode("utf-8", "replace").strip() or "tesseract failed"
            print(json.dumps({"ok": False, "error": err}), flush=True)
            return 1
        tsv = proc.stdout.decode("utf-8", "replace")
        words = parse_tsv(tsv)
        print(json.dumps({"ok": True, "words": words}), flush=True)
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
