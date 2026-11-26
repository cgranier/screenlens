#!/usr/bin/env python3
"""Safe clipboard copy and Omarchy agent handoff actions without shell interpolation."""

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import time


def read_payload(path: str, b64_value: str = "") -> dict:
    if b64_value:
        decoded = base64.b64decode(b64_value).decode("utf-8")
        return json.loads(decoded)
    if path == "-":
        raw = sys.stdin.readline()
        return json.loads(raw)
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def copy_text_from_file(path: str) -> int:
    if path == "-":
        payload = read_payload("-")
        data = str(payload.get("text") or "")[:65536].encode("utf-8")
    else:
        with open(path, "rb") as f:
            data = f.read(65536)
    proc = subprocess.run(["wl-copy"], input=data, timeout=5)
    return proc.returncode


def copy_image(image_path: str, crop_spec: str) -> int:
    if not os.path.isfile(image_path):
        return 1
    if crop_spec:
        parts = [int(p.strip()) for p in crop_spec.split(",")]
        if len(parts) != 4 or parts[2] <= 0 or parts[3] <= 0:
            return 1
        geom = f"{parts[2]}x{parts[3]}+{parts[0]}+{parts[1]}"
        proc = subprocess.run(["magick", image_path, "-crop", geom, "+repage", "png:-"], capture_output=True, timeout=15)
        if proc.returncode != 0:
            return proc.returncode
        data = proc.stdout
    else:
        with open(image_path, "rb") as f:
            data = f.read()
    cp = subprocess.run(["wl-copy", "--type", "image/png"], input=data, timeout=5)
    return cp.returncode


def build_single_line_handoff_prompt(context_path: str, crop_path: str, image_path: str, draft_prompt: str) -> str:
    """Build a strictly single-line prompt so xdg-terminal-exec never splits args on newlines."""
    parts = [f"Read the ScreenLens context file at {context_path}"]
    if crop_path:
        parts.append(f"and inspect the cropped screenshot at {crop_path}")
    elif image_path:
        parts.append(f"and inspect the screenshot at {image_path}")
    clean_draft = " ".join(str(draft_prompt or "").split())
    if clean_draft:
        parts.append(f"— Request: {clean_draft[:500]}")
    else:
        parts.append("and continue helping with the captured screen context.")
    return " ".join(parts).replace("\n", " ").replace("\r", " ")


def prepare_handoff(request_file: str, b64_value: str = "") -> dict:
    payload = read_payload(request_file, b64_value=b64_value)

    prompt = str(payload.get("prompt") or "").strip()
    image_path = str(payload.get("imagePath") or "")
    crop = payload.get("crop")
    draft_prompt = str(payload.get("draftPrompt") or "")

    crop_path = ""
    # If the user circled a region, save a dedicated cropped PNG and point the agent to it too.
    if image_path and os.path.isfile(image_path) and isinstance(crop, dict) and int(crop.get("w", 0)) > 0 and int(crop.get("h", 0)) > 0:
        x = max(0, int(crop["x"]))
        y = max(0, int(crop["y"]))
        w = max(1, int(crop["w"]))
        h = max(1, int(crop["h"]))
        candidate = f"/tmp/omarchy-screenlens-handoff-{os.getuid()}-{int(time.time() * 1000)}.png"
        fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.close(fd)
        res = subprocess.run(
            ["magick", image_path, "-crop", f"{w}x{h}+{x}+{y}", "+repage", candidate],
            capture_output=True,
            timeout=15,
        )
        if res.returncode == 0:
            crop_path = candidate
            prompt = f"Cropped region image: {crop_path}\n" + prompt

    # Write the full multi-line context to a private file because xdg-terminal-exec
    # splits command arguments on embedded newlines.
    context_path = f"/tmp/omarchy-screenlens-context-{os.getuid()}-{int(time.time() * 1000)}.md"
    fd = os.open(context_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as ctx_file:
        ctx_file.write(prompt + "\n")

    single_line_prompt = build_single_line_handoff_prompt(context_path, crop_path, image_path, draft_prompt)
    return {
        "ok": True,
        "prompt": single_line_prompt,
        "contextPath": context_path,
        "cropPath": crop_path,
    }


def handoff_to_agent(request_file: str) -> int:
    prepared = prepare_handoff(request_file)
    agent_prompt_bin = shutil.which("omarchy-agent-prompt") or "/usr/share/omarchy/bin/omarchy-agent-prompt"
    if not os.path.isfile(agent_prompt_bin):
        return 1
    subprocess.Popen(
        [agent_prompt_bin, prepared["prompt"]],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    return 0


def build_context_markdown(
    window_class: str,
    window_title: str,
    image_path: str,
    crop: dict | None,
    selected_text: str,
    messages: list[dict],
    draft_prompt: str,
    crop_path: str = "",
) -> str:
    lines: list[str] = []
    if crop_path:
        lines.append(f"Cropped region image: {crop_path}")
    lines.append("Context captured via ScreenLens:")
    if window_class or window_title:
        label = f"{window_class} — {window_title}" if window_class and window_title else (window_class or window_title)
        lines.append(f"- Active window: {label}")
    if image_path:
        lines.append(f"- Screenshot file: {image_path}")
    if isinstance(crop, dict) and int(crop.get("w", 0)) > 0 and int(crop.get("h", 0)) > 0:
        lines.append(
            f"- Selected region (image px): x={int(crop['x'])}, y={int(crop['y'])}, "
            f"w={int(crop['w'])}, h={int(crop['h'])}"
        )
    if selected_text:
        lines.extend(["", "Selected on-screen text:", '"""', selected_text[:4000], '"""'])
    if messages:
        lines.extend(["", "Prior ScreenLens conversation:"])
        for msg in messages[-8:]:
            if not isinstance(msg, dict) or not msg.get("text"):
                continue
            role = "User" if msg.get("role") == "user" else "Assistant"
            lines.append(f"{role}: {str(msg['text'])[:2000]}")
    if draft_prompt.strip():
        lines.extend(["", f"Follow-up request: {draft_prompt.strip()}"])
    else:
        lines.extend(["", "Continue helping me with what is shown above. Inspect the screenshot file if helpful."])
    return "\n".join(lines)


def notify_error(message: str) -> None:
    notifier = shutil.which("omarchy-notification-send") or "/usr/share/omarchy/bin/omarchy-notification-send"
    if os.path.isfile(notifier):
        subprocess.run([notifier, "ScreenLens", message[:300]], check=False, timeout=5)


def build_handoff_launch_cmd(single_line_prompt: str, agent_override: str = "default") -> list[str]:
    agent = str(agent_override or "default").strip().lower()
    if not agent or agent == "default":
        agent_prompt_bin = shutil.which("omarchy-agent-prompt") or "/usr/share/omarchy/bin/omarchy-agent-prompt"
        return [agent_prompt_bin, single_line_prompt]

    launch_tui = shutil.which("omarchy-launch-tui") or "/usr/share/omarchy/bin/omarchy-launch-tui"
    if agent == "claude":
        agent_cmd = ["claude", "--permission-mode", "auto", "--", single_line_prompt]
    elif agent == "agy":
        agent_cmd = ["agy", "--dangerously-skip-permissions", "--prompt-interactive", single_line_prompt]
    elif agent == "codex":
        agent_cmd = ["codex", "--approve-for-me", "--", single_line_prompt]
    elif agent == "opencode":
        agent_cmd = ["opencode", "--auto", "--prompt", single_line_prompt]
    elif agent == "grok":
        agent_cmd = ["grok", "--permission-mode", "bypassPermissions", "--", single_line_prompt]
    elif agent == "gemini":
        agent_cmd = ["gemini", "-i", single_line_prompt]
    else:
        agent_prompt_bin = shutil.which("omarchy-agent-prompt") or "/usr/share/omarchy/bin/omarchy-agent-prompt"
        return [agent_prompt_bin, single_line_prompt]
    return [launch_tui, "--app-id=org.omarchy.agent", *agent_cmd]


def resolve_handoff_agent() -> str:
    try:
        scripts_dir = os.path.dirname(os.path.abspath(__file__))
        if scripts_dir not in sys.path:
            sys.path.insert(0, scripts_dir)
        from config import load_config as load_sl_config

        cfg = load_sl_config()
        routing = cfg.get("taskRouting") or {}
        if routing.get("enabled"):
            chosen = str(routing.get("handoffAgent") or "default").strip().lower()
            if chosen:
                return chosen
    except Exception:
        pass
    return "default"


def handoff_direct(args: argparse.Namespace, dry_run: bool = False) -> dict | int:
    crop = None
    if args.crop:
        parts = [int(p.strip()) for p in args.crop.split(",")]
        if len(parts) == 4 and parts[2] > 0 and parts[3] > 0:
            crop = {"x": parts[0], "y": parts[1], "w": parts[2], "h": parts[3]}

    messages: list[dict] = []
    if args.messages_json:
        try:
            parsed = json.loads(args.messages_json)
            if isinstance(parsed, list):
                messages = parsed
        except json.JSONDecodeError:
            messages = []

    crop_path = ""
    if args.image and os.path.isfile(args.image) and crop is not None:
        candidate = f"/tmp/omarchy-screenlens-handoff-{os.getuid()}-{int(time.time() * 1000)}.png"
        fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.close(fd)
        res = subprocess.run(
            ["magick", args.image, "-crop", f"{crop['w']}x{crop['h']}+{crop['x']}+{crop['y']}", "+repage", candidate],
            capture_output=True,
            timeout=15,
        )
        if res.returncode == 0:
            crop_path = candidate

    md = build_context_markdown(
        window_class=args.window_class,
        window_title=args.window_title,
        image_path=args.image,
        crop=crop,
        selected_text=args.selected_text,
        messages=messages,
        draft_prompt=args.draft,
        crop_path=crop_path,
    )
    context_path = f"/tmp/omarchy-screenlens-context-{os.getuid()}-{int(time.time() * 1000)}.md"
    fd = os.open(context_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as ctx_file:
        ctx_file.write(md + "\n")

    single_line_prompt = build_single_line_handoff_prompt(context_path, crop_path, args.image, args.draft)
    handoff_agent = resolve_handoff_agent()
    launch_cmd = build_handoff_launch_cmd(single_line_prompt, agent_override=handoff_agent)
    if dry_run:
        return {
            "ok": True,
            "prompt": single_line_prompt,
            "contextPath": context_path,
            "cropPath": crop_path,
            "handoffAgent": handoff_agent,
            "launchCmd": launch_cmd,
        }

    if not os.path.isfile(launch_cmd[0]) and not shutil.which(launch_cmd[0]):
        notify_error(f"Could not find {launch_cmd[0]}.")
        return 1
    os.execvp(launch_cmd[0], launch_cmd)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_text = sub.add_parser("copy-text")
    p_text.add_argument("file")

    p_img = sub.add_parser("copy-image")
    p_img.add_argument("image")
    p_img.add_argument("--crop", default="")

    p_prep = sub.add_parser("prepare-handoff")
    p_prep.add_argument("file", nargs="?", default="-")
    p_prep.add_argument("--b64", default="")

    p_handoff = sub.add_parser("handoff")
    p_handoff.add_argument("file")

    p_direct = sub.add_parser("handoff-direct")
    p_direct.add_argument("--image", default="")
    p_direct.add_argument("--crop", default="")
    p_direct.add_argument("--window-class", default="")
    p_direct.add_argument("--window-title", default="")
    p_direct.add_argument("--selected-text", default="")
    p_direct.add_argument("--draft", default="")
    p_direct.add_argument("--messages-json", default="[]")
    p_direct.add_argument("--dry-run", action="store_true")

    args = parser.parse_args()
    if args.cmd == "copy-text":
        return copy_text_from_file(args.file)
    if args.cmd == "copy-image":
        return copy_image(args.image, args.crop)
    if args.cmd == "prepare-handoff":
        print(json.dumps(prepare_handoff(args.file, b64_value=args.b64)), flush=True)
        return 0
    if args.cmd == "handoff":
        return handoff_to_agent(args.file)
    if args.cmd == "handoff-direct":
        try:
            result = handoff_direct(args, dry_run=args.dry_run)
            if args.dry_run:
                print(json.dumps(result), flush=True)
                return 0
            return int(result)
        except Exception as exc:
            notify_error(f"Agent handoff failed: {exc}")
            return 1
    return 1


if __name__ == "__main__":
    sys.exit(main())
