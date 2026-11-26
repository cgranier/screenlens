#!/usr/bin/env python3
"""Secure configuration backend (0600 screenlens.json) and managed Hyprland keybind updater."""

import argparse
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

CONFIG_PATH = os.path.expanduser("~/.config/omarchy/screenlens.json")
BINDINGS_PATH = os.path.expanduser("~/.config/hypr/bindings.lua")
PLUGIN_ID = "carlos.screenlens"

BLOCK_BEGIN = "-- ScreenLens: begin. Managed by ScreenLens settings; delete block to remove."
BLOCK_END = "-- ScreenLens: end."
LEGACY_MARKER_RE = re.compile(
    r"(?m)^-- ScreenLens:[^\n]*\n(?:o\.(?:re)?bind\([^\n]*carlos\.screenlens[^\n]*\)\n?)"
)

ALLOWED_MODS = {"SUPER", "CTRL", "ALT", "SHIFT"}
KEY_TOKEN_RE = re.compile(r"^(?:[A-Za-z0-9_]+|code:[0-9]+)$")

PROVIDER_CATALOG = {
    "gemini": {
        "name": "Google Gemini",
        "requiresKey": True,
        "keyUrl": "https://aistudio.google.com/apikey",
        "envVars": ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
        "models": [
            "gemini-2.5-flash",
            "gemini-2.5-flash-lite",
            "gemini-2.5-pro",
        ],
        "defaultModel": "gemini-2.5-flash",
    },
    "anthropic": {
        "name": "Anthropic Claude",
        "requiresKey": True,
        "keyUrl": "https://console.anthropic.com/settings/keys",
        "envVars": ["ANTHROPIC_API_KEY"],
        "models": [
            "claude-haiku-4-5-20251001",
            "claude-sonnet-4-5-20250929",
        ],
        "defaultModel": "claude-haiku-4-5-20251001",
    },
    "openai": {
        "name": "OpenAI",
        "requiresKey": True,
        "keyUrl": "https://platform.openai.com/api-keys",
        "envVars": ["OPENAI_API_KEY"],
        "models": [
            "gpt-4.1-mini",
            "gpt-4.1",
            "gpt-4o-mini",
        ],
        "defaultModel": "gpt-4.1-mini",
    },
    "ollama": {
        "name": "Ollama (Local)",
        "requiresKey": False,
        "keyUrl": "https://ollama.com/library",
        "envVars": ["OLLAMA_HOST"],
        "models": [
            "llama3.2-vision",
            "qwen2.5vl",
            "llava",
        ],
        "defaultModel": "llama3.2-vision",
    },
    "agent": {
        "name": "Omarchy CLI Agent",
        "requiresKey": False,
        "keyUrl": "",
        "envVars": [],
        "models": [
            "haiku",
            "sonnet",
            "opus",
        ],
        "defaultModel": "haiku",
        "clis": ["default", "claude", "codex", "agy", "opencode", "grok", "gemini"],
    },
}

DEFAULT_CONFIG = {
    "schemaVersion": 2,
    "keybind": "SUPER + ALT + A",
    "theme": "system",
    "defaultMode": "lasso",
    "maxImageDim": 1920,
    "translateLanguage": "English",
    "ocrLanguages": ["eng"],
    "defaultProvider": "auto",
    "providers": {
        "gemini": {"apiKey": "", "model": "gemini-2.5-flash"},
        "anthropic": {"apiKey": "", "model": "claude-haiku-4-5-20251001"},
        "openai": {"apiKey": "", "model": "gpt-4.1-mini"},
        "ollama": {"host": "http://127.0.0.1:11434", "model": "llama3.2-vision"},
        "agent": {"cli": "default", "model": "haiku"},
    },
    "taskRouting": {
        "enabled": False,
        "general": {"provider": "", "model": ""},
        "vision": {"provider": "", "model": ""},
        "text": {"provider": "", "model": ""},
        "translate": {"provider": "", "model": ""},
        "handoffAgent": "default",
    },
}


def deep_merge(base: dict, override: dict) -> dict:
    out = copy.deepcopy(base)
    if not isinstance(override, dict):
        return out
    for key, val in override.items():
        if key in out and isinstance(out[key], dict) and isinstance(val, dict):
            out[key] = deep_merge(out[key], val)
        else:
            out[key] = copy.deepcopy(val)
    return out


def normalize_config(raw: dict | None) -> dict:
    """Merge defaults and transparently migrate v1 flat fields to v2 schema."""
    cfg = copy.deepcopy(DEFAULT_CONFIG)
    if not isinstance(raw, dict):
        return cfg

    # Migrate v1 flat keys if present before merging nested v2 sections.
    legacy_provider = str(raw.get("provider") or "").strip().lower()
    legacy_model = str(raw.get("model") or "").strip()
    legacy_key = str(raw.get("apiKey") or "").strip()
    if legacy_provider and "defaultProvider" not in raw:
        cfg["defaultProvider"] = legacy_provider
    if legacy_provider in cfg["providers"]:
        if legacy_model:
            cfg["providers"][legacy_provider]["model"] = legacy_model
        if legacy_key and "apiKey" in cfg["providers"][legacy_provider]:
            cfg["providers"][legacy_provider]["apiKey"] = legacy_key

    if raw.get("geminiApiKey"):
        cfg["providers"]["gemini"]["apiKey"] = str(raw["geminiApiKey"]).strip()
    if raw.get("anthropicApiKey"):
        cfg["providers"]["anthropic"]["apiKey"] = str(raw["anthropicApiKey"]).strip()
    if raw.get("openaiApiKey"):
        cfg["providers"]["openai"]["apiKey"] = str(raw["openaiApiKey"]).strip()
    if raw.get("ollamaHost"):
        cfg["providers"]["ollama"]["host"] = str(raw["ollamaHost"]).strip()
    if raw.get("ollamaModel"):
        cfg["providers"]["ollama"]["model"] = str(raw["ollamaModel"]).strip()

    # Overlay structured v2 fields.
    known_top = set(DEFAULT_CONFIG.keys())
    structured = {k: v for k, v in raw.items() if k in known_top}
    cfg = deep_merge(cfg, structured)
    cfg["schemaVersion"] = 2

    # Clamp & validate enum/numeric fields.
    if cfg["theme"] not in ("system", "dark", "light"):
        cfg["theme"] = "system"
    if cfg["defaultMode"] not in ("lasso", "text"):
        cfg["defaultMode"] = "lasso"
    try:
        dim = int(cfg.get("maxImageDim") or 1920)
    except (TypeError, ValueError):
        dim = 1920
    cfg["maxImageDim"] = max(512, min(3840, dim))

    langs = cfg.get("ocrLanguages")
    if not isinstance(langs, list) or not langs:
        cfg["ocrLanguages"] = ["eng"]
    else:
        cleaned = [re.sub(r"[^A-Za-z0-9_-]", "", str(x)) for x in langs]
        cfg["ocrLanguages"] = [x for x in cleaned if x] or ["eng"]

    if not str(cfg.get("translateLanguage") or "").strip():
        cfg["translateLanguage"] = "English"

    return cfg


def load_config(path: str = CONFIG_PATH) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError):
        raw = None
    return normalize_config(raw)


def save_config(cfg: dict, path: str = CONFIG_PATH) -> dict:
    normalized = normalize_config(cfg)
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, mode=0o700, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".screenlens.", suffix=".tmp", dir=parent)
    try:
        os.chmod(tmp_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(normalized, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, path)
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return normalized


def mask_secret(value: str) -> str:
    s = str(value or "").strip()
    if not s:
        return ""
    if len(s) <= 6:
        return "••••"
    return f"••••{s[-4:]}"


def redact_config(cfg: dict) -> dict:
    out = copy.deepcopy(cfg)
    for prov_id, prov in out.get("providers", {}).items():
        if isinstance(prov, dict) and "apiKey" in prov:
            raw = str(prov.get("apiKey") or "")
            prov["hasKey"] = bool(raw.strip())
            prov["maskedKey"] = mask_secret(raw)
            prov["apiKey"] = ""
    return out


def normalize_keybind(chord: str) -> str:
    raw = str(chord or "").strip()
    if not raw or "\n" in raw or "\r" in raw:
        raise ValueError("Keybind must be a single non-empty line")
    parts = [p.strip() for p in raw.split("+") if p.strip()]
    if not parts:
        raise ValueError("Keybind is empty")

    mods = []
    key = parts[-1]
    for mod in parts[:-1]:
        up = mod.upper()
        if up not in ALLOWED_MODS:
            raise ValueError(f"Unsupported modifier '{mod}'. Allowed: SUPER, CTRL, ALT, SHIFT")
        if up not in mods:
            mods.append(up)

    if not KEY_TOKEN_RE.match(key):
        raise ValueError(f"Invalid key token '{key}'")
    if len(key) == 1:
        key = key.upper()

    return " + ".join([*mods, key])


def render_bindings_block(chord: str, rebind: bool = False) -> str:
    fn = "o.rebind" if rebind else "o.bind"
    return "\n".join(
        [
            BLOCK_BEGIN,
            f'{fn}("{chord}", "ScreenLens (AI screen overlay)", {{ panel = "{PLUGIN_ID}" }})',
            BLOCK_END,
        ]
    )


def apply_bindings_text(existing: str, chord: str, rebind: bool = False) -> str:
    block = render_bindings_block(chord, rebind=rebind)
    begin_idx = existing.find(BLOCK_BEGIN)
    end_idx = existing.find(BLOCK_END)
    if begin_idx != -1 and end_idx != -1 and end_idx > begin_idx:
        after_end = end_idx + len(BLOCK_END)
        return existing[:begin_idx] + block + existing[after_end:]

    cleaned = LEGACY_MARKER_RE.sub("", existing).rstrip()
    if not cleaned:
        return block + "\n"
    return cleaned + "\n\n" + block + "\n"


def read_keybind_from_bindings(bindings_path: str = BINDINGS_PATH) -> str:
    try:
        with open(bindings_path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ""
    match = re.search(
        r'o\.(?:re)?bind\(\s*"([^"]+)"\s*,\s*"[^"]*"\s*,\s*\{\s*panel\s*=\s*"carlos\.screenlens"\s*\}\s*\)',
        text,
    )
    return match.group(1) if match else ""


def validate_hyprland() -> tuple[bool, str]:
    rel = subprocess.run(["hyprctl", "reload"], capture_output=True, text=True, timeout=10)
    if rel.returncode != 0:
        return False, (rel.stderr or rel.stdout or "hyprctl reload failed").strip()
    err_proc = subprocess.run(["hyprctl", "configerrors"], capture_output=True, text=True, timeout=10)
    errors = (err_proc.stdout or "").strip()
    if err_proc.returncode != 0:
        return False, (err_proc.stderr or errors or "hyprctl configerrors failed").strip()
    if errors:
        return False, errors
    return True, ""


def set_keybind(
    chord: str,
    rebind: bool = False,
    bindings_path: str = BINDINGS_PATH,
    config_path: str = CONFIG_PATH,
    reload_hyprland: bool = True,
) -> dict:
    normalized = normalize_keybind(chord)
    existing = ""
    had_file = os.path.isfile(bindings_path)
    if had_file:
        with open(bindings_path, "r", encoding="utf-8") as f:
            existing = f.read()

    backup_path = ""
    if had_file:
        backup_path = f"{bindings_path}.bak.{int(time.time())}"
        shutil.copy2(bindings_path, backup_path)

    updated = apply_bindings_text(existing, normalized, rebind=rebind)
    parent = os.path.dirname(os.path.abspath(bindings_path))
    os.makedirs(parent, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".bindings.", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(updated)
        os.replace(tmp_path, bindings_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    if reload_hyprland:
        ok, err_msg = validate_hyprland()
        if not ok:
            if had_file and backup_path and os.path.isfile(backup_path):
                shutil.copy2(backup_path, bindings_path)
                subprocess.run(["hyprctl", "reload"], capture_output=True, timeout=10)
            raise RuntimeError(f"Hyprland rejected keybind (rolled back): {err_msg}")

    cfg = load_config(config_path)
    cfg["keybind"] = normalized
    save_config(cfg, config_path)
    return {"ok": True, "keybind": normalized, "backup": backup_path}


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage ScreenLens config and Hyprland keybind.")
    parser.add_argument("--config", default=CONFIG_PATH)
    parser.add_argument("--bindings", default=BINDINGS_PATH)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_get = sub.add_parser("get")
    p_get.add_argument("--redact", action="store_true")

    sub.add_parser("catalog")

    p_patch = sub.add_parser("patch")
    p_patch.add_argument("json_patch", nargs="?", default="")

    p_kb = sub.add_parser("set-keybind")
    p_kb.add_argument("chord")
    p_kb.add_argument("--rebind", action="store_true")
    p_kb.add_argument("--no-reload", action="store_true")

    sub.add_parser("get-keybind")

    args = parser.parse_args()

    try:
        if args.cmd == "get":
            cfg = load_config(args.config)
            live_kb = read_keybind_from_bindings(args.bindings)
            if live_kb:
                cfg["keybind"] = live_kb
            out = redact_config(cfg) if args.redact else cfg
            print(json.dumps({"ok": True, "config": out}), flush=True)
            return 0

        if args.cmd == "catalog":
            print(json.dumps({"ok": True, "providers": PROVIDER_CATALOG}), flush=True)
            return 0

        if args.cmd == "patch":
            raw = args.json_patch if args.json_patch else sys.stdin.read()
            patch_obj = json.loads(raw)
            if not isinstance(patch_obj, dict):
                raise ValueError("patch must be a JSON object")
            current = load_config(args.config)
            merged = deep_merge(current, patch_obj)
            saved = save_config(merged, args.config)
            print(json.dumps({"ok": True, "config": redact_config(saved)}), flush=True)
            return 0

        if args.cmd == "set-keybind":
            res = set_keybind(
                args.chord,
                rebind=args.rebind,
                bindings_path=args.bindings,
                config_path=args.config,
                reload_hyprland=not args.no_reload,
            )
            print(json.dumps(res), flush=True)
            return 0

        if args.cmd == "get-keybind":
            live_kb = read_keybind_from_bindings(args.bindings)
            cfg_kb = load_config(args.config).get("keybind", DEFAULT_CONFIG["keybind"])
            print(json.dumps({"ok": True, "keybind": live_kb or cfg_kb}), flush=True)
            return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), flush=True)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
