#!/usr/bin/env python3
"""Hybrid Vision streaming backend for ScreenLens.

Supports direct streaming Vision APIs (Gemini, Anthropic, OpenAI, Ollama) for
1-2s responses, with automatic fallback to Omarchy's default CLI agent when no
direct API key is configured. Emits NDJSON events to stdout.
"""

import argparse
import base64
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

from config import CONFIG_PATH, DEFAULT_CONFIG, load_config as load_v2_config

MAX_RESPONSE_CHARS = 65536
MAX_HISTORY_TURNS = 10
SOCKET_TIMEOUT = 45

SYSTEM_PROMPT = (
    "You are ScreenLens, a fast on-screen desktop assistant for Omarchy Linux. "
    "Answer concisely, accurately, and directly about what is shown in the screenshot "
    "or selected text. Use plain, readable formatting without unnecessary preamble."
)

DEFAULT_MODELS = {
    "gemini": "gemini-2.5-flash",
    "anthropic": "claude-haiku-4-5-20251001",
    "openai": "gpt-4.1-mini",
    "ollama": "llama3.2-vision",
}


def emit(event: dict) -> None:
    print(json.dumps(event, ensure_ascii=False), flush=True)


def load_config(path: str = CONFIG_PATH) -> dict:
    return load_v2_config(path)


def validate_ollama_host(host: str) -> str:
    parsed = urllib.parse.urlparse(host.strip())
    if parsed.scheme not in ("http", "https"):
        raise ValueError("ollamaHost must use http or https")
    if parsed.scheme == "http" and parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("http ollamaHost is restricted to localhost; use https for remote hosts")
    return host.rstrip("/")


def resolve_provider(config: dict, env: dict | None = None, task: str = "") -> dict:
    env_map = os.environ if env is None else env
    from config import normalize_config

    cfg = normalize_config(config)
    providers = cfg.get("providers") or {}
    preferred = str(cfg.get("defaultProvider") or "auto").strip().lower()
    explicit_model = ""

    # Honor optional per-task routing overrides when enabled (Issue #4).
    routing = cfg.get("taskRouting") or {}
    if task and routing.get("enabled") and isinstance(routing.get(task), dict):
        task_prov = str(routing[task].get("provider") or "").strip().lower()
        task_model = str(routing[task].get("model") or "").strip()
        if task_prov:
            preferred = task_prov
        if task_model:
            explicit_model = task_model

    gemini_cfg = providers.get("gemini") or {}
    anthropic_cfg = providers.get("anthropic") or {}
    openai_cfg = providers.get("openai") or {}
    ollama_cfg = providers.get("ollama") or {}
    agent_cfg = providers.get("agent") or {}

    gemini_key = str(gemini_cfg.get("apiKey") or env_map.get("GEMINI_API_KEY") or env_map.get("GOOGLE_API_KEY") or "").strip()
    anthropic_key = str(anthropic_cfg.get("apiKey") or env_map.get("ANTHROPIC_API_KEY") or "").strip()
    openai_key = str(openai_cfg.get("apiKey") or env_map.get("OPENAI_API_KEY") or "").strip()
    ollama_host = str(env_map.get("OLLAMA_HOST") or "").strip()
    configured_ollama_host = str(ollama_cfg.get("host") or "http://127.0.0.1:11434").strip()

    if preferred == "gemini":
        return {"provider": "gemini", "model": explicit_model or str(gemini_cfg.get("model") or DEFAULT_MODELS["gemini"]), "apiKey": gemini_key}
    if preferred == "anthropic":
        return {"provider": "anthropic", "model": explicit_model or str(anthropic_cfg.get("model") or DEFAULT_MODELS["anthropic"]), "apiKey": anthropic_key}
    if preferred == "openai":
        return {"provider": "openai", "model": explicit_model or str(openai_cfg.get("model") or DEFAULT_MODELS["openai"]), "apiKey": openai_key}
    if preferred == "ollama":
        host = validate_ollama_host(ollama_host or configured_ollama_host)
        return {"provider": "ollama", "model": explicit_model or str(ollama_cfg.get("model") or DEFAULT_MODELS["ollama"]), "host": host}
    if preferred == "agent":
        return {"provider": "agent", "model": explicit_model or str(agent_cfg.get("model") or ""), "cli": str(agent_cfg.get("cli") or "default")}

    # Auto-detection order: fastest direct Vision APIs first, then Ollama, then Omarchy default agent.
    if gemini_key:
        return {"provider": "gemini", "model": explicit_model or str(gemini_cfg.get("model") or DEFAULT_MODELS["gemini"]), "apiKey": gemini_key}
    if anthropic_key:
        return {"provider": "anthropic", "model": explicit_model or str(anthropic_cfg.get("model") or DEFAULT_MODELS["anthropic"]), "apiKey": anthropic_key}
    if openai_key:
        return {"provider": "openai", "model": explicit_model or str(openai_cfg.get("model") or DEFAULT_MODELS["openai"]), "apiKey": openai_key}
    if ollama_host:
        return {"provider": "ollama", "model": explicit_model or str(ollama_cfg.get("model") or DEFAULT_MODELS["ollama"]), "host": validate_ollama_host(ollama_host)}
    return {"provider": "agent", "model": explicit_model or str(agent_cfg.get("model") or ""), "cli": str(agent_cfg.get("cli") or "default")}


def prepare_image(image_path: str, crop: dict | None, max_dim: int = 1920) -> tuple[bytes, str, str]:
    """Return (image_bytes, mime_type, saved_path_for_agent)."""
    if not image_path or not os.path.isfile(image_path):
        return b"", "", ""

    saved_path = image_path
    use_crop = (
        isinstance(crop, dict)
        and int(crop.get("w", 0)) > 0
        and int(crop.get("h", 0)) > 0
    )

    if use_crop:
        x = max(0, int(crop["x"]))
        y = max(0, int(crop["y"]))
        w = max(1, int(crop["w"]))
        h = max(1, int(crop["h"]))
        saved_path = f"/tmp/omarchy-screenlens-crop-{os.getuid()}-{int(time.time() * 1000)}-{os.getpid()}.png"
        fd = os.open(saved_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.close(fd)
        cmd = ["magick", image_path, "-crop", f"{w}x{h}+{x}+{y}", "+repage"]
        if max(w, h) > max_dim:
            cmd.extend(["-resize", f"{max_dim}x{max_dim}>"])
        cmd.append(saved_path)
        proc = subprocess.run(cmd, capture_output=True, timeout=15)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode("utf-8", "replace").strip() or "failed to crop image")
        with open(saved_path, "rb") as f:
            return f.read(), "image/png", saved_path

    # Full-screen capture: downscale & JPEG-compress in memory for low-latency Vision uploads.
    cmd = ["magick", image_path, "-resize", f"{max_dim}x{max_dim}>", "-quality", "86", "jpeg:-"]
    proc = subprocess.run(cmd, capture_output=True, timeout=15)
    if proc.returncode == 0 and proc.stdout:
        return proc.stdout, "image/jpeg", saved_path

    with open(image_path, "rb") as f:
        return f.read(), "image/png", saved_path


def compose_user_text(
    prompt: str,
    selected_text: str,
    window_info: dict | None,
    has_crop: bool,
    image_updated: bool = False,
    frame_number: int = 1,
) -> str:
    parts = []
    if isinstance(window_info, dict):
        cls = str(window_info.get("class") or "").strip()
        title = str(window_info.get("title") or "").strip()
        if cls or title:
            label = f"{cls} — {title}" if cls and title else (cls or title)
            parts.append(f"[Active window: {label}]")
    if image_updated:
        if has_crop:
            parts.append(f"[Attached image: cropped region from updated screen capture (frame #{frame_number})]")
        else:
            parts.append(f"[Attached image: updated screen capture (frame #{frame_number}) — user recaptured the screen]")
    elif has_crop:
        parts.append("[Attached image: cropped region selected by the user]")
    if selected_text:
        parts.append(f"[User highlighted text on screen:]\n{selected_text[:6000]}")
    parts.append(prompt.strip())
    return "\n\n".join(parts)


def build_gemini_payload(
    user_text: str,
    image_b64: str,
    mime: str,
    history: list[dict],
    web_search: bool = False,
    image_updated: bool = False,
    prev_image_b64: str = "",
    prev_mime: str = "",
) -> dict:
    contents = []
    user_seen = False
    for turn in history[-MAX_HISTORY_TURNS:]:
        role = "model" if turn.get("role") == "assistant" else "user"
        text = str(turn.get("text") or "").strip()
        if not text:
            continue
        parts = [{"text": text}]
        if not user_seen and role == "user":
            user_seen = True
            hist_b64 = prev_image_b64 if image_updated else image_b64
            hist_mime = prev_mime if image_updated else mime
            if hist_b64:
                parts.insert(0, {"inline_data": {"mime_type": hist_mime or mime, "data": hist_b64}})
        contents.append({"role": role, "parts": parts})

    current_parts = [{"text": user_text}]
    if image_b64 and (image_updated or not user_seen):
        current_parts.insert(0, {"inline_data": {"mime_type": mime, "data": image_b64}})
    contents.append({"role": "user", "parts": current_parts})

    payload: dict = {
        "system_instruction": {"parts": [{"text": SYSTEM_PROMPT}]},
        "contents": contents,
        "generationConfig": {"temperature": 0.3, "maxOutputTokens": 2048},
    }
    if web_search:
        payload["tools"] = [{"google_search": {}}]
    return payload


def parse_gemini_sse_line(line: str) -> str:
    if not line.startswith("data:"):
        return ""
    raw = line[5:].strip()
    if not raw or raw == "[DONE]":
        return ""
    obj = json.loads(raw)
    chunks = []
    for cand in obj.get("candidates") or []:
        content = cand.get("content") or {}
        for part in content.get("parts") or []:
            txt = part.get("text")
            if isinstance(txt, str):
                chunks.append(txt)
    return "".join(chunks)


def build_anthropic_payload(
    model: str,
    user_text: str,
    image_b64: str,
    mime: str,
    history: list[dict],
    web_search: bool = False,
    image_updated: bool = False,
    prev_image_b64: str = "",
    prev_mime: str = "",
) -> dict:
    messages = []
    user_seen = False
    for turn in history[-MAX_HISTORY_TURNS:]:
        role = "assistant" if turn.get("role") == "assistant" else "user"
        text = str(turn.get("text") or "").strip()
        if not text:
            continue
        if not user_seen and role == "user":
            user_seen = True
            hist_b64 = prev_image_b64 if image_updated else image_b64
            hist_mime = prev_mime if image_updated else mime
            if hist_b64:
                messages.append(
                    {
                        "role": "user",
                        "content": [
                            {"type": "image", "source": {"type": "base64", "media_type": hist_mime or mime, "data": hist_b64}},
                            {"type": "text", "text": text},
                        ],
                    }
                )
            else:
                messages.append({"role": role, "content": text})
        else:
            messages.append({"role": role, "content": text})

    if image_b64 and (image_updated or not user_seen):
        messages.append(
            {
                "role": "user",
                "content": [
                    {"type": "image", "source": {"type": "base64", "media_type": mime, "data": image_b64}},
                    {"type": "text", "text": user_text},
                ],
            }
        )
    else:
        messages.append({"role": "user", "content": user_text})

    payload: dict = {
        "model": model,
        "max_tokens": 2048,
        "stream": True,
        "system": SYSTEM_PROMPT,
        "messages": messages,
    }
    if web_search:
        payload["tools"] = [{"type": "web_search_20250305", "name": "web_search", "max_uses": 3}]
    return payload


def parse_anthropic_sse_line(line: str) -> str:
    if not line.startswith("data:"):
        return ""
    raw = line[5:].strip()
    if not raw:
        return ""
    obj = json.loads(raw)
    if obj.get("type") == "content_block_delta":
        delta = obj.get("delta") or {}
        if delta.get("type") == "text_delta":
            return str(delta.get("text") or "")
    return ""


def build_openai_payload(
    model: str,
    user_text: str,
    image_b64: str,
    mime: str,
    history: list[dict],
    image_updated: bool = False,
    prev_image_b64: str = "",
    prev_mime: str = "",
) -> dict:
    messages: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]
    user_seen = False
    for turn in history[-MAX_HISTORY_TURNS:]:
        role = "assistant" if turn.get("role") == "assistant" else "user"
        text = str(turn.get("text") or "").strip()
        if not text:
            continue
        if not user_seen and role == "user":
            user_seen = True
            hist_b64 = prev_image_b64 if image_updated else image_b64
            hist_mime = prev_mime if image_updated else mime
            if hist_b64:
                messages.append(
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": text},
                            {"type": "image_url", "image_url": {"url": f"data:{hist_mime or mime};base64,{hist_b64}"}},
                        ],
                    }
                )
            else:
                messages.append({"role": role, "content": text})
        else:
            messages.append({"role": role, "content": text})

    if image_b64 and (image_updated or not user_seen):
        messages.append(
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": user_text},
                    {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{image_b64}"}},
                ],
            }
        )
    else:
        messages.append({"role": "user", "content": user_text})

    return {"model": model, "stream": True, "max_tokens": 2048, "messages": messages}


def parse_openai_sse_line(line: str) -> str:
    if not line.startswith("data:"):
        return ""
    raw = line[5:].strip()
    if not raw or raw == "[DONE]":
        return ""
    obj = json.loads(raw)
    chunks = []
    for choice in obj.get("choices") or []:
        delta = choice.get("delta") or {}
        txt = delta.get("content")
        if isinstance(txt, str):
            chunks.append(txt)
    return "".join(chunks)


def build_openai_responses_payload(
    model: str,
    user_text: str,
    image_b64: str,
    mime: str,
    history: list[dict],
    web_search: bool = True,
    image_updated: bool = False,
    prev_image_b64: str = "",
    prev_mime: str = "",
) -> dict:
    items: list[dict] = []
    user_seen = False
    for turn in history[-MAX_HISTORY_TURNS:]:
        role = "assistant" if turn.get("role") == "assistant" else "user"
        text = str(turn.get("text") or "").strip()
        if not text:
            continue
        if not user_seen and role == "user":
            user_seen = True
            hist_b64 = prev_image_b64 if image_updated else image_b64
            hist_mime = prev_mime if image_updated else mime
            if hist_b64:
                items.append(
                    {
                        "role": "user",
                        "content": [
                            {"type": "input_text", "text": text},
                            {"type": "input_image", "image_url": f"data:{hist_mime or mime};base64,{hist_b64}"},
                        ],
                    }
                )
            else:
                items.append({"role": role, "content": [{"type": "input_text", "text": text}]})
        else:
            content_type = "output_text" if role == "assistant" else "input_text"
            items.append({"role": role, "content": [{"type": content_type, "text": text}]})

    if image_b64 and (image_updated or not user_seen):
        items.append(
            {
                "role": "user",
                "content": [
                    {"type": "input_text", "text": user_text},
                    {"type": "input_image", "image_url": f"data:{mime};base64,{image_b64}"},
                ],
            }
        )
    else:
        items.append({"role": "user", "content": [{"type": "input_text", "text": user_text}]})

    payload: dict = {
        "model": model,
        "instructions": SYSTEM_PROMPT,
        "input": items,
        "stream": True,
        "max_output_tokens": 2048,
    }
    if web_search:
        payload["tools"] = [{"type": "web_search_preview"}]
    return payload


def parse_openai_responses_sse_line(line: str) -> str:
    if not line.startswith("data:"):
        return ""
    raw = line[5:].strip()
    if not raw or raw == "[DONE]":
        return ""
    obj = json.loads(raw)
    if obj.get("type") == "response.output_text.delta":
        delta = obj.get("delta")
        return delta if isinstance(delta, str) else ""
    return ""


def build_ollama_payload(
    model: str,
    user_text: str,
    image_b64: str,
    history: list[dict],
    image_updated: bool = False,
    prev_image_b64: str = "",
) -> dict:
    messages: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]
    user_seen = False
    for turn in history[-MAX_HISTORY_TURNS:]:
        role = "assistant" if turn.get("role") == "assistant" else "user"
        text = str(turn.get("text") or "").strip()
        if not text:
            continue
        msg: dict = {"role": role, "content": text}
        if not user_seen and role == "user":
            user_seen = True
            hist_b64 = prev_image_b64 if image_updated else image_b64
            if hist_b64:
                msg["images"] = [hist_b64]
        messages.append(msg)

    cur: dict = {"role": "user", "content": user_text}
    if image_b64 and (image_updated or not user_seen):
        cur["images"] = [image_b64]
    messages.append(cur)
    return {"model": model, "stream": True, "messages": messages}


def parse_ollama_ndjson_line(line: str) -> str:
    raw = line.strip()
    if not raw:
        return ""
    obj = json.loads(raw)
    msg = obj.get("message") or {}
    txt = msg.get("content")
    return txt if isinstance(txt, str) else ""


def stream_http(req: urllib.request.Request, line_parser) -> None:
    total = 0
    with urllib.request.urlopen(req, timeout=SOCKET_TIMEOUT) as resp:
        for raw_line in resp:
            line = raw_line.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                delta = line_parser(line)
            except json.JSONDecodeError:
                continue
            if not delta:
                continue
            remaining = MAX_RESPONSE_CHARS - total
            if remaining <= 0:
                break
            chunk = delta[:remaining]
            total += len(chunk)
            emit({"type": "delta", "text": chunk})


def detect_default_agent() -> str:
    cmd = shutil.which("omarchy-default-agent")
    if not cmd:
        return ""
    proc = subprocess.run([cmd], capture_output=True, text=True, timeout=5)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def build_agent_cli_command(
    agent: str,
    full_prompt: str,
    model: str = "",
    image_path: str = "",
    web_search: bool = False,
) -> list[str] | None:
    clean_model = "" if (not model or model == "default") else model.strip()
    if agent == "claude":
        tools_spec = "Read,WebSearch,WebFetch" if web_search else "Read"
        return [
            "claude",
            "-p",
            "--model",
            clean_model or "haiku",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config",
            '{"mcpServers":{}}',
            "--setting-sources",
            "",
            "--tools",
            tools_spec,
            "--add-dir",
            "/tmp",
            "--allowedTools",
            tools_spec,
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            full_prompt,
        ]
    if agent == "agy":
        cmd = [
            "agy",
            "--add-dir",
            "/tmp",
            "--disable-slash-commands",
            "--effort",
            "low",
            "--output-format",
            "stream-json",
        ]
        if clean_model:
            cmd.extend(["--model", clean_model])
        cmd.extend(["-p", full_prompt])
        return cmd
    if agent == "codex":
        cmd = [
            "codex",
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "-s",
            "read-only",
            "--color",
            "never",
            "--json",
        ]
        if clean_model:
            cmd.extend(["-m", clean_model])
        if image_path:
            cmd.extend(["-i", image_path])
        cmd.extend(["--", full_prompt])
        return cmd
    if agent == "opencode":
        cmd = ["opencode", "run", "--archived", "--format", "json"]
        if clean_model:
            cmd.extend(["-m", clean_model])
        if image_path:
            cmd.extend(["-f", image_path])
        cmd.append(full_prompt)
        return cmd
    if agent == "gemini":
        cmd = ["gemini"]
        if clean_model:
            cmd.extend(["-m", clean_model])
        cmd.extend(["-p", full_prompt])
        return cmd
    if agent == "grok":
        tools_spec = "Read,WebSearch,WebFetch" if web_search else "Read"
        cmd = [
            "grok",
            "--add-dir",
            "/tmp",
            "--no-memory",
            "--no-plan",
            "--no-subagents",
        ]
        if not web_search:
            cmd.append("--disable-web-search")
        cmd.extend(
            [
                "--tools",
                tools_spec,
                "--allow",
                tools_spec,
                "--output-format",
                "plain",
            ]
        )
        if clean_model:
            cmd.extend(["-m", clean_model])
        cmd.extend(["-p", full_prompt])
        return cmd
    return None


def parse_claude_stream_json_line(line: str) -> tuple[str, str]:
    """Return (delta_text, final_fallback_text) from a Claude Code stream-json line."""
    raw = line.strip()
    if not raw or not raw.startswith("{"):
        return "", ""
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return "", ""
    if not isinstance(obj, dict):
        return "", ""
    msg_type = obj.get("type")
    if msg_type == "stream_event":
        ev = obj.get("event") or {}
        if ev.get("type") == "content_block_delta":
            delta = ev.get("delta") or {}
            if delta.get("type") == "text_delta":
                return str(delta.get("text") or ""), ""
    elif msg_type == "result":
        result_text = obj.get("result")
        if isinstance(result_text, str) and result_text:
            return "", result_text
    return "", ""


def parse_agy_stream_json_line(line: str) -> tuple[str, str, str]:
    """Return (delta_text, final_fallback_text, error_msg) from an agy stream-json line."""
    raw = line.strip()
    if not raw or not raw.startswith("{"):
        return "", "", ""
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return "", "", ""
    if not isinstance(obj, dict):
        return "", "", ""
    ev = obj.get("event")
    if ev == "step_update":
        su = obj.get("step_update") or {}
        if su.get("step_type") == "agent_response":
            td = su.get("text_delta")
            if isinstance(td, str) and td:
                return td, "", ""
    elif ev == "result":
        res = obj.get("result") or {}
        resp = res.get("response")
        if isinstance(resp, str) and resp:
            return "", resp, ""
    elif ev == "error":
        msg = str(obj.get("message") or (obj.get("error") or {}).get("message") or "agy error")
        return "", "", msg
    return "", "", ""


def parse_codex_jsonl_line(line: str) -> tuple[str, str, str]:
    """Return (delta_text, final_fallback_text, error_msg) from a `codex exec --json` line."""
    raw = line.strip()
    if not raw or not raw.startswith("{"):
        return "", "", ""
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return "", "", ""
    if not isinstance(obj, dict):
        return "", "", ""
    ev_type = str(obj.get("type") or "")
    if ev_type in ("item.completed", "item.updated"):
        item = obj.get("item") or {}
        if item.get("type") in ("agent_message", "message", "assistant_message"):
            txt = item.get("text")
            if isinstance(txt, str) and txt:
                return (txt, "", "") if ev_type == "item.completed" else ("", txt, "")
            content = item.get("content")
            if isinstance(content, list):
                parts = [str(c.get("text") or "") for c in content if isinstance(c, dict) and c.get("text")]
                joined = "".join(parts)
                if joined:
                    return (joined, "", "") if ev_type == "item.completed" else ("", joined, "")
    elif ev_type in ("item.delta", "agent_message.delta", "response.output_text.delta"):
        delta = obj.get("delta") or obj.get("text")
        if isinstance(delta, str) and delta:
            return delta, "", ""
    elif ev_type in ("error", "turn.failed"):
        msg = str(obj.get("message") or (obj.get("error") or {}).get("message") or "codex failed")
        return "", "", msg
    return "", "", ""


def parse_opencode_jsonl_line(line: str) -> tuple[str, str, str]:
    """Return (delta_text, final_fallback_text, error_msg) from an `opencode run --format json` line."""
    raw = line.strip()
    if not raw or not raw.startswith("{"):
        return "", "", ""
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return "", "", ""
    if not isinstance(obj, dict):
        return "", "", ""
    ev_type = str(obj.get("type") or "")
    if ev_type == "text":
        part = obj.get("part") or {}
        txt = part.get("text") if isinstance(part, dict) else obj.get("text")
        if isinstance(txt, str) and txt:
            return txt, "", ""
    elif ev_type == "error":
        err = obj.get("error")
        msg = str(err.get("message") if isinstance(err, dict) else (obj.get("message") or err or "opencode error"))
        return "", "", msg
    return "", "", ""


def run_agent_fallback(
    user_text: str,
    saved_image_path: str,
    history: list[dict],
    model: str = "",
    cli: str = "default",
    web_search: bool = False,
    image_updated: bool = False,
    previous_image_path: str = "",
    frame_number: int = 1,
) -> None:
    agent = cli if (cli and cli != "default") else detect_default_agent()
    if not agent:
        emit(
            {
                "type": "error",
                "message": (
                    "No Vision API key configured and no Omarchy default agent is set. "
                    "Add a Gemini, Anthropic, or OpenAI key in ScreenLens Settings, "
                    "or run `omarchy default agent`."
                ),
            }
        )
        return

    lines = [SYSTEM_PROMPT]
    if saved_image_path:
        if agent in ("codex", "opencode"):
            if image_updated:
                lines.append(f"Inspect the newly recaptured screenshot image (frame #{frame_number}) attached to this turn.")
            else:
                lines.append("Inspect the attached screenshot image to answer the user's question.")
        else:
            if image_updated:
                lines.append(
                    f"The user recaptured their screen (frame #{frame_number}). Inspect the updated screenshot image file at "
                    f"{saved_image_path} using your file-reading tool."
                )
                if previous_image_path and previous_image_path != saved_image_path and os.path.isfile(previous_image_path):
                    lines.append(f"(Earlier frame from this conversation, if needed for comparison: {previous_image_path})")
            else:
                lines.append(f"Inspect the screenshot image file at {saved_image_path} using your file-reading tool.")
    if web_search:
        lines.append("Live web search is enabled: use your web search tool to verify current or real-time facts when helpful.")
    for turn in history[-MAX_HISTORY_TURNS:]:
        role = "Assistant" if turn.get("role") == "assistant" else "User"
        text = str(turn.get("text") or "").strip()
        if text:
            lines.append(f"{role}: {text}")
    lines.append(f"User: {user_text}")
    full_prompt = "\n\n".join(lines)

    cmd = build_agent_cli_command(
        agent,
        full_prompt,
        model=model,
        image_path=saved_image_path,
        web_search=web_search,
    )
    if not cmd or not shutil.which(cmd[0]):
        emit(
            {
                "type": "error",
                "message": (
                    f"Direct Vision API key not set, and CLI agent '{agent}' is not available on PATH. "
                    "Configure a provider in ScreenLens Settings or click 'Continue in Agent'."
                ),
            }
        )
        return

    clean_model = "" if (not model or model == "default") else model.strip()
    display_model = (clean_model or "haiku") if agent == "claude" else (clean_model or agent)
    emit(
        {
            "type": "meta",
            "provider": f"agent:{agent}",
            "model": display_model,
            "croppedPath": saved_image_path,
            "webSearch": bool(web_search),
        }
    )
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    total = 0
    final_fallback = ""
    last_json_error = ""
    assert proc.stdout is not None
    if agent in ("claude", "agy", "codex", "opencode"):
        for line in proc.stdout:
            if agent == "claude":
                delta, fallback = parse_claude_stream_json_line(line)
                err_msg = ""
            elif agent == "agy":
                delta, fallback, err_msg = parse_agy_stream_json_line(line)
            elif agent == "codex":
                delta, fallback, err_msg = parse_codex_jsonl_line(line)
            else:
                delta, fallback, err_msg = parse_opencode_jsonl_line(line)
            if fallback:
                final_fallback = fallback
            if err_msg:
                last_json_error = err_msg
            if not delta:
                continue
            remaining = MAX_RESPONSE_CHARS - total
            if remaining <= 0:
                break
            chunk = delta[:remaining]
            total += len(chunk)
            emit({"type": "delta", "text": chunk})
        if total == 0 and final_fallback:
            chunk = final_fallback[:MAX_RESPONSE_CHARS]
            total += len(chunk)
            emit({"type": "delta", "text": chunk})
    else:
        for line in proc.stdout:
            remaining = MAX_RESPONSE_CHARS - total
            if remaining <= 0:
                break
            chunk = line[:remaining]
            total += len(chunk)
            emit({"type": "delta", "text": chunk})
    stderr_text = proc.stderr.read().strip() if proc.stderr else ""
    code = proc.wait()
    if (code != 0 or last_json_error) and total == 0:
        emit({"type": "error", "message": last_json_error or stderr_text or f"{agent} exited with code {code}"})
        return
    emit({"type": "done"})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request-file", default="")
    args = parser.parse_args()

    try:
        if args.request_file:
            with open(args.request_file, "r", encoding="utf-8") as f:
                req_data = json.load(f)
        else:
            raw_line = sys.stdin.readline()
            if not raw_line.strip():
                raise ValueError("empty stdin")
            req_data = json.loads(raw_line)
    except Exception as exc:
        emit({"type": "error", "message": f"invalid request payload: {exc}"})
        return 1

    prompt = str(req_data.get("prompt") or "").strip()
    if not prompt:
        emit({"type": "error", "message": "prompt is empty"})
        return 1

    image_path = str(req_data.get("imagePath") or "")
    crop = req_data.get("crop")
    selected_text = str(req_data.get("selectedText") or "")
    window_info = req_data.get("windowInfo")
    history = req_data.get("history") or []
    task = str(req_data.get("task") or "general").strip().lower()
    web_search = bool(req_data.get("webSearch"))
    image_updated = bool(req_data.get("imageUpdated"))
    frame_number = max(1, int(req_data.get("frameNumber") or 1))
    prev_image_path = str(req_data.get("previousImagePath") or "")

    config = load_config()
    max_dim = int(config.get("maxImageDim") or 1920)
    max_dim = max(512, min(3840, max_dim))

    try:
        resolved = resolve_provider(config, task=task)
        img_bytes, mime, saved_path = prepare_image(image_path, crop, max_dim=max_dim)
        image_b64 = base64.b64encode(img_bytes).decode("ascii") if img_bytes else ""
        prev_image_b64 = ""
        prev_mime = ""
        if image_updated and history and prev_image_path and prev_image_path != image_path and os.path.isfile(prev_image_path):
            try:
                prev_bytes, prev_mime, _ = prepare_image(prev_image_path, None, max_dim=min(max_dim, 1280))
                prev_image_b64 = base64.b64encode(prev_bytes).decode("ascii") if prev_bytes else ""
            except Exception:
                prev_image_b64 = ""
                prev_mime = ""
        user_text = compose_user_text(
            prompt,
            selected_text,
            window_info,
            has_crop=bool(crop),
            image_updated=image_updated,
            frame_number=frame_number,
        )
        provider = resolved["provider"]
        model = resolved["model"]

        if provider == "agent":
            run_agent_fallback(
                user_text,
                saved_path,
                history,
                model=model,
                cli=str(resolved.get("cli") or "default"),
                web_search=web_search,
                image_updated=image_updated,
                previous_image_path=prev_image_path,
                frame_number=frame_number,
            )
            return 0

        if provider == "gemini":
            api_key = resolved.get("apiKey") or ""
            if not api_key:
                raise RuntimeError("Missing Gemini API key (set GEMINI_API_KEY or ~/.config/omarchy/screenlens.json)")
            emit({"type": "meta", "provider": "gemini", "model": model, "croppedPath": saved_path, "webSearch": web_search})
            safe_model = urllib.parse.quote(model, safe=".-_")
            url = f"https://generativelanguage.googleapis.com/v1beta/models/{safe_model}:streamGenerateContent?alt=sse"
            body = json.dumps(
                build_gemini_payload(
                    user_text,
                    image_b64,
                    mime,
                    history,
                    web_search=web_search,
                    image_updated=image_updated,
                    prev_image_b64=prev_image_b64,
                    prev_mime=prev_mime,
                )
            ).encode("utf-8")
            req = urllib.request.Request(
                url,
                data=body,
                headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
                method="POST",
            )
            stream_http(req, parse_gemini_sse_line)
            emit({"type": "done"})
            return 0

        if provider == "anthropic":
            api_key = resolved.get("apiKey") or ""
            if not api_key:
                raise RuntimeError("Missing Anthropic API key (set ANTHROPIC_API_KEY or ~/.config/omarchy/screenlens.json)")
            emit({"type": "meta", "provider": "anthropic", "model": model, "croppedPath": saved_path, "webSearch": web_search})
            body = json.dumps(
                build_anthropic_payload(
                    model,
                    user_text,
                    image_b64,
                    mime,
                    history,
                    web_search=web_search,
                    image_updated=image_updated,
                    prev_image_b64=prev_image_b64,
                    prev_mime=prev_mime,
                )
            ).encode("utf-8")
            req = urllib.request.Request(
                "https://api.anthropic.com/v1/messages",
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "x-api-key": api_key,
                    "anthropic-version": "2023-06-01",
                },
                method="POST",
            )
            stream_http(req, parse_anthropic_sse_line)
            emit({"type": "done"})
            return 0

        if provider == "openai":
            api_key = resolved.get("apiKey") or ""
            if not api_key:
                raise RuntimeError("Missing OpenAI API key (set OPENAI_API_KEY or ~/.config/omarchy/screenlens.json)")
            emit({"type": "meta", "provider": "openai", "model": model, "croppedPath": saved_path, "webSearch": web_search})
            if web_search:
                body = json.dumps(
                    build_openai_responses_payload(
                        model,
                        user_text,
                        image_b64,
                        mime,
                        history,
                        web_search=True,
                        image_updated=image_updated,
                        prev_image_b64=prev_image_b64,
                        prev_mime=prev_mime,
                    )
                ).encode("utf-8")
                req = urllib.request.Request(
                    "https://api.openai.com/v1/responses",
                    data=body,
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {api_key}",
                    },
                    method="POST",
                )
                stream_http(req, parse_openai_responses_sse_line)
            else:
                body = json.dumps(
                    build_openai_payload(
                        model,
                        user_text,
                        image_b64,
                        mime,
                        history,
                        image_updated=image_updated,
                        prev_image_b64=prev_image_b64,
                        prev_mime=prev_mime,
                    )
                ).encode("utf-8")
                req = urllib.request.Request(
                    "https://api.openai.com/v1/chat/completions",
                    data=body,
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {api_key}",
                    },
                    method="POST",
                )
                stream_http(req, parse_openai_sse_line)
            emit({"type": "done"})
            return 0

        if provider == "ollama":
            host = resolved["host"]
            emit({"type": "meta", "provider": "ollama", "model": model, "croppedPath": saved_path, "webSearch": False})
            body = json.dumps(
                build_ollama_payload(
                    model,
                    user_text,
                    image_b64,
                    history,
                    image_updated=image_updated,
                    prev_image_b64=prev_image_b64,
                )
            ).encode("utf-8")
            req = urllib.request.Request(
                f"{host}/api/chat",
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            stream_http(req, parse_ollama_ndjson_line)
            emit({"type": "done"})
            return 0

        raise RuntimeError(f"Unsupported provider: {provider}")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:400]
        emit({"type": "error", "message": f"HTTP {exc.code}: {detail}"})
        return 1
    except Exception as exc:
        emit({"type": "error", "message": str(exc)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
