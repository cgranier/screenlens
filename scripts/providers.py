#!/usr/bin/env python3
"""Provider model discovery, connection testing, and allowlisted API-key console launcher."""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from ask import validate_ollama_host
from config import CONFIG_PATH, PROVIDER_CATALOG, load_config

HTTP_TIMEOUT = 10
MAX_MODELS = 40
MAX_BODY_BYTES = 262144


def dedupe_preserve(items: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for item in items:
        s = str(item or "").strip()
        if not s or s in seen:
            continue
        seen.add(s)
        out.append(s)
        if len(out) >= MAX_MODELS:
            break
    return out


def effective_key(cfg: dict, provider: str, env: dict | None = None) -> str:
    env_map = os.environ if env is None else env
    prov = (cfg.get("providers") or {}).get(provider) or {}
    saved = str(prov.get("apiKey") or "").strip()
    if saved:
        return saved
    for var in PROVIDER_CATALOG.get(provider, {}).get("envVars", []):
        val = str(env_map.get(var) or "").strip()
        if val:
            return val
    return ""


def fetch_json(url: str, headers: dict | None = None, body: dict | None = None) -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req_headers = {"Accept": "application/json"}
    if body is not None:
        req_headers["Content-Type"] = "application/json"
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, data=data, headers=req_headers, method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        raw = resp.read(MAX_BODY_BYTES).decode("utf-8", "replace")
        return json.loads(raw) if raw.strip() else {}


def list_installed_clis() -> list[str]:
    found = ["default"]
    for cli in PROVIDER_CATALOG["agent"]["clis"]:
        if cli == "default":
            continue
        if shutil.which(cli):
            found.append(cli)
    return found


def discover_models(provider: str, cfg: dict, live: bool = True, env: dict | None = None) -> dict:
    meta = PROVIDER_CATALOG.get(provider)
    if not meta:
        return {"ok": False, "error": f"Unknown provider: {provider}"}

    curated = list(meta.get("models") or [])
    discovered: list[str] = []
    note = ""

    if provider == "agent":
        return {
            "ok": True,
            "provider": provider,
            "models": curated,
            "clis": PROVIDER_CATALOG["agent"]["clis"],
            "installedClis": list_installed_clis(),
            "source": "local",
        }

    if not live:
        return {"ok": True, "provider": provider, "models": curated, "source": "curated"}

    try:
        if provider == "ollama":
            prov_cfg = (cfg.get("providers") or {}).get("ollama") or {}
            host = validate_ollama_host(str(prov_cfg.get("host") or "http://127.0.0.1:11434"))
            data = fetch_json(f"{host}/api/tags")
            for entry in data.get("models") or []:
                name = str((entry or {}).get("name") or "").strip()
                if name:
                    discovered.append(name)
            source = "live" if discovered else "curated"
            return {"ok": True, "provider": provider, "models": dedupe_preserve(discovered + curated), "source": source}

        api_key = effective_key(cfg, provider, env=env)
        if not api_key:
            return {
                "ok": True,
                "provider": provider,
                "models": curated,
                "source": "curated",
                "note": "Add an API key to fetch live models",
            }

        if provider == "gemini":
            data = fetch_json(
                "https://generativelanguage.googleapis.com/v1beta/models?pageSize=50",
                headers={"x-goog-api-key": api_key},
            )
            for entry in data.get("models") or []:
                methods = entry.get("supportedGenerationMethods") or []
                name = str(entry.get("name") or "").removeprefix("models/")
                if "generateContent" in methods and name.startswith("gemini"):
                    discovered.append(name)
        elif provider == "anthropic":
            data = fetch_json(
                "https://api.anthropic.com/v1/models?limit=50",
                headers={"x-api-key": api_key, "anthropic-version": "2023-06-01"},
            )
            for entry in data.get("data") or []:
                mid = str((entry or {}).get("id") or "").strip()
                if mid.startswith("claude"):
                    discovered.append(mid)
        elif provider == "openai":
            data = fetch_json(
                "https://api.openai.com/v1/models",
                headers={"Authorization": f"Bearer {api_key}"},
            )
            for entry in data.get("data") or []:
                mid = str((entry or {}).get("id") or "").strip()
                if mid.startswith(("gpt-4", "gpt-5", "o3", "o4")):
                    discovered.append(mid)
    except urllib.error.HTTPError as exc:
        note = f"HTTP {exc.code} fetching models; showing curated list"
    except Exception as exc:
        note = f"{exc}; showing curated list"

    merged = dedupe_preserve(curated + discovered)
    out = {"ok": True, "provider": provider, "models": merged, "source": "live" if discovered else "curated"}
    if note:
        out["note"] = note
    return out


def test_provider(provider: str, cfg: dict, env: dict | None = None) -> dict:
    meta = PROVIDER_CATALOG.get(provider)
    if not meta:
        return {"ok": False, "error": f"Unknown provider: {provider}"}

    prov_cfg = (cfg.get("providers") or {}).get(provider) or {}
    model = str(prov_cfg.get("model") or meta.get("defaultModel") or "").strip()
    start = time.monotonic()

    try:
        if provider == "agent":
            cli = str(prov_cfg.get("cli") or "default").strip()
            if cli == "default":
                default_bin = shutil.which("omarchy-default-agent")
                if default_bin:
                    p = subprocess.run([default_bin], capture_output=True, text=True, timeout=5)
                    cli = p.stdout.strip()
            if not cli:
                return {"ok": False, "error": "No Omarchy default agent set (run `omarchy default agent`)"}
            if not shutil.which(cli):
                return {"ok": False, "error": f"CLI '{cli}' is not installed on PATH"}
            ms = int((time.monotonic() - start) * 1000)
            return {"ok": True, "provider": provider, "model": f"{cli} ({model})", "latencyMs": ms, "detail": f"{cli} ready"}

        if provider == "ollama":
            host = validate_ollama_host(str(prov_cfg.get("host") or "http://127.0.0.1:11434"))
            data = fetch_json(f"{host}/api/tags")
            count = len(data.get("models") or [])
            ms = int((time.monotonic() - start) * 1000)
            return {"ok": True, "provider": provider, "model": model, "latencyMs": ms, "detail": f"{count} local model(s)"}

        api_key = effective_key(cfg, provider, env=env)
        if not api_key:
            return {"ok": False, "error": f"Missing API key for {meta['name']}"}

        if provider == "gemini":
            safe_model = urllib.parse.quote(model, safe=".-_")
            fetch_json(
                f"https://generativelanguage.googleapis.com/v1beta/models/{safe_model}",
                headers={"x-goog-api-key": api_key},
            )
        elif provider == "anthropic":
            fetch_json(
                "https://api.anthropic.com/v1/models?limit=1",
                headers={"x-api-key": api_key, "anthropic-version": "2023-06-01"},
            )
        elif provider == "openai":
            safe_model = urllib.parse.quote(model, safe=".-_")
            fetch_json(
                f"https://api.openai.com/v1/models/{safe_model}",
                headers={"Authorization": f"Bearer {api_key}"},
            )

        ms = int((time.monotonic() - start) * 1000)
        return {"ok": True, "provider": provider, "model": model, "latencyMs": ms, "detail": "Connected"}
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            err_body = exc.read(512).decode("utf-8", "replace")
            parsed = json.loads(err_body)
            if isinstance(parsed, dict):
                err_obj = parsed.get("error")
                if isinstance(err_obj, dict) and err_obj.get("message"):
                    detail = str(err_obj["message"])[:140]
                elif isinstance(err_obj, str):
                    detail = err_obj[:140]
        except Exception:
            pass
        msg = f"HTTP {exc.code}" + (f": {detail}" if detail else "")
        return {"ok": False, "error": msg}
    except Exception as exc:
        return {"ok": False, "error": str(exc)[:180]}


def get_key_url(provider: str) -> str:
    meta = PROVIDER_CATALOG.get(provider)
    if not meta:
        raise ValueError(f"Unknown provider: {provider}")
    url = str(meta.get("keyUrl") or "").strip()
    if not url.startswith("https://"):
        raise ValueError(f"Provider '{provider}' has no console URL")
    return url


def main() -> int:
    parser = argparse.ArgumentParser(description="ScreenLens provider discovery and testing.")
    parser.add_argument("--config", default=CONFIG_PATH)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list-models")
    p_list.add_argument("provider")
    p_list.add_argument("--offline", action="store_true")

    p_test = sub.add_parser("test")
    p_test.add_argument("provider")

    p_open = sub.add_parser("open-key-url")
    p_open.add_argument("provider")

    args = parser.parse_args()
    cfg = load_config(args.config)

    try:
        if args.cmd == "list-models":
            print(json.dumps(discover_models(args.provider, cfg, live=not args.offline)), flush=True)
            return 0
        if args.cmd == "test":
            res = test_provider(args.provider, cfg)
            print(json.dumps(res), flush=True)
            return 0 if res.get("ok") else 1
        if args.cmd == "open-key-url":
            url = get_key_url(args.provider)
            subprocess.Popen(
                ["xdg-open", url],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                close_fds=True,
            )
            print(json.dumps({"ok": True, "url": url}), flush=True)
            return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), flush=True)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
