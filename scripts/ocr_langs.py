#!/usr/bin/env python3
"""Inspect and install Arch Tesseract OCR language packs for ScreenLens."""

import argparse
import json
import os
import shutil
import subprocess
import sys

_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from config import CONFIG_PATH, load_config, save_config

TESSERACT_CATALOG = [
    {"code": "eng", "name": "English", "pkg": "tesseract-data-eng"},
    {"code": "spa", "name": "Spanish", "pkg": "tesseract-data-spa"},
    {"code": "fra", "name": "French", "pkg": "tesseract-data-fra"},
    {"code": "deu", "name": "German", "pkg": "tesseract-data-deu"},
    {"code": "por", "name": "Portuguese", "pkg": "tesseract-data-por"},
    {"code": "ita", "name": "Italian", "pkg": "tesseract-data-ita"},
    {"code": "nld", "name": "Dutch", "pkg": "tesseract-data-nld"},
    {"code": "pol", "name": "Polish", "pkg": "tesseract-data-pol"},
    {"code": "rus", "name": "Russian", "pkg": "tesseract-data-rus"},
    {"code": "jpn", "name": "Japanese", "pkg": "tesseract-data-jpn"},
    {"code": "chi_sim", "name": "Chinese (Simplified)", "pkg": "tesseract-data-chi_sim"},
    {"code": "kor", "name": "Korean", "pkg": "tesseract-data-kor"},
    {"code": "ara", "name": "Arabic", "pkg": "tesseract-data-ara"},
]

CATALOG_BY_CODE = {entry["code"]: entry for entry in TESSERACT_CATALOG}


def parse_tesseract_langs(raw: str) -> list[str]:
    langs: list[str] = []
    for line in raw.splitlines():
        token = line.strip()
        if not token or token.lower().startswith("list of available"):
            continue
        if token in ("osd", "equ"):
            continue
        if token not in langs:
            langs.append(token)
    return langs


def detect_installed_langs() -> list[str]:
    if not shutil.which("tesseract"):
        return []
    proc = subprocess.run(["tesseract", "--list-langs"], capture_output=True, text=True, timeout=10)
    combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
    return parse_tesseract_langs(combined)


def build_status(config_path: str = CONFIG_PATH, installed_override: list[str] | None = None) -> dict:
    installed = detect_installed_langs() if installed_override is None else list(installed_override)
    installed_set = set(installed)
    cfg = load_config(config_path)
    active = [c for c in (cfg.get("ocrLanguages") or ["eng"]) if c in installed_set] or (installed[:1] if installed else ["eng"])

    installed_items = []
    for code in installed:
        meta = CATALOG_BY_CODE.get(code)
        installed_items.append(
            {
                "code": code,
                "name": meta["name"] if meta else code,
                "pkg": meta["pkg"] if meta else f"tesseract-data-{code}",
                "active": code in active,
            }
        )

    available_items = [
        {
            "code": entry["code"],
            "name": entry["name"],
            "pkg": entry["pkg"],
            "installCmd": f"omarchy pkg add {entry['pkg']}",
        }
        for entry in TESSERACT_CATALOG
        if entry["code"] not in installed_set
    ]

    return {
        "ok": True,
        "installed": installed_items,
        "available": available_items,
        "active": active,
    }


def validate_install_code(code: str) -> dict:
    clean = str(code or "").strip().lower()
    if clean not in CATALOG_BY_CODE:
        raise ValueError(f"Unsupported Tesseract language pack '{code}'")
    return CATALOG_BY_CODE[clean]


def install_pack(code: str, config_path: str = CONFIG_PATH) -> dict:
    entry = validate_install_code(code)
    pkg = entry["pkg"]
    installer = "/usr/share/omarchy/bin/omarchy-pkg-add"
    if not os.path.isfile(installer):
        raise RuntimeError("omarchy-pkg-add not found")

    proc = subprocess.run(["pkexec", installer, pkg], capture_output=True, text=True, timeout=180)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or f"failed to install {pkg}").strip()
        raise RuntimeError(err[:220])

    # Auto-enable the newly installed language in ScreenLens config.
    cfg = load_config(config_path)
    langs = list(cfg.get("ocrLanguages") or ["eng"])
    if entry["code"] not in langs:
        langs.append(entry["code"])
        cfg["ocrLanguages"] = langs
        save_config(cfg, config_path)

    status = build_status(config_path)
    status["installedCode"] = entry["code"]
    status["installedPkg"] = pkg
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect and install Tesseract OCR packs.")
    parser.add_argument("--config", default=CONFIG_PATH)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status")

    p_inst = sub.add_parser("install")
    p_inst.add_argument("code")

    args = parser.parse_args()
    try:
        if args.cmd == "status":
            print(json.dumps(build_status(args.config)), flush=True)
            return 0
        if args.cmd == "install":
            print(json.dumps(install_pack(args.code, args.config)), flush=True)
            return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
