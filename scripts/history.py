#!/usr/bin/env python3
"""Owner-only (0600) local session history store with thumbnail generation and auto-pruning."""

import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from config import CONFIG_PATH, load_config  # noqa: E402

DEFAULT_STATE_DIR = os.path.expanduser("~/.local/state/omarchy/screenlens")
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MAX_MESSAGES = 40
MAX_MSG_CHARS = 16000
MAX_SELECTED_TEXT = 4000
MAX_THUMB_DIM = "320x200>"


def state_paths(state_dir: str = DEFAULT_STATE_DIR) -> tuple[str, str, str]:
    root = os.path.abspath(os.path.expanduser(state_dir or DEFAULT_STATE_DIR))
    history_file = os.path.join(root, "history.json")
    thumbs_dir = os.path.join(root, "thumbs")
    return root, history_file, thumbs_dir


def ensure_private_dir(path: str) -> None:
    os.makedirs(path, mode=0o700, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def load_raw_sessions(history_file: str) -> list[dict]:
    try:
        with open(history_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []
    if isinstance(data, dict) and isinstance(data.get("sessions"), list):
        return [s for s in data["sessions"] if isinstance(s, dict)]
    if isinstance(data, list):
        return [s for s in data if isinstance(s, dict)]
    return []


def write_sessions_atomic(sessions: list[dict], state_dir: str = DEFAULT_STATE_DIR) -> None:
    root, history_file, _ = state_paths(state_dir)
    ensure_private_dir(root)
    payload = {
        "schemaVersion": 1,
        "updatedAt": int(time.time() * 1000),
        "sessions": sessions,
    }
    fd, tmp_path = tempfile.mkstemp(prefix=".history.", suffix=".tmp", dir=root)
    try:
        os.chmod(tmp_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, history_file)
        os.chmod(history_file, 0o600)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def sanitize_session_id(raw_id: object) -> str:
    sid = str(raw_id or "").strip()
    if sid and SESSION_ID_RE.match(sid):
        return sid
    return f"sl-{int(time.time() * 1000)}-{secrets.token_hex(4)}"


def sanitize_messages(raw_messages: object) -> list[dict]:
    if not isinstance(raw_messages, list):
        return []
    cleaned: list[dict] = []
    for item in raw_messages[-MAX_MESSAGES:]:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or "").strip().lower()
        if role not in ("user", "assistant"):
            continue
        text = str(item.get("text") or "").strip()
        if not text:
            continue
        cleaned.append({"role": role, "text": text[:MAX_MSG_CHARS]})
    return cleaned


def generate_thumbnail(source_path: str, session_id: str, thumbs_dir: str) -> str:
    src = str(source_path or "").strip()
    if not src or not os.path.isfile(src):
        return ""
    ensure_private_dir(thumbs_dir)
    dest = os.path.join(thumbs_dir, f"{session_id}.jpg")
    magick = shutil.which("magick")
    if magick:
        tmp_dest = os.path.join(thumbs_dir, f".{session_id}.{os.getpid()}.jpg")
        try:
            proc = subprocess.run(
                [magick, src, "-auto-orient", "-thumbnail", MAX_THUMB_DIM, "-strip", "-quality", "82", tmp_dest],
                capture_output=True,
                timeout=10,
            )
            if proc.returncode == 0 and os.path.isfile(tmp_dest):
                os.chmod(tmp_dest, 0o600)
                os.replace(tmp_dest, dest)
                os.chmod(dest, 0o600)
                return dest
        except (OSError, subprocess.SubprocessError):
            pass
        finally:
            if os.path.exists(tmp_dest):
                try:
                    os.unlink(tmp_dest)
                except OSError:
                    pass
    return ""


def prune_thumbs(sessions: list[dict], thumbs_dir: str) -> None:
    if not os.path.isdir(thumbs_dir):
        return
    keep = set()
    for sess in sessions:
        tp = str(sess.get("thumbPath") or "")
        if tp:
            keep.add(os.path.abspath(tp))
    for name in os.listdir(thumbs_dir):
        full = os.path.abspath(os.path.join(thumbs_dir, name))
        if full not in keep:
            try:
                if os.path.isfile(full):
                    os.unlink(full)
            except OSError:
                pass


def history_settings(config_path: str = CONFIG_PATH) -> tuple[bool, int]:
    cfg = load_config(config_path)
    enabled = bool(cfg.get("historyEnabled", True))
    try:
        max_sessions = int(cfg.get("historyMaxSessions", 15))
    except (TypeError, ValueError):
        max_sessions = 15
    return enabled, max(1, min(100, max_sessions))


def save_session(
    payload: dict,
    state_dir: str = DEFAULT_STATE_DIR,
    config_path: str = CONFIG_PATH,
) -> dict:
    enabled, max_sessions = history_settings(config_path)
    if not enabled:
        return {"ok": True, "skipped": True, "reason": "history_disabled"}

    messages = sanitize_messages(payload.get("messages"))
    if not messages:
        return {"ok": True, "skipped": True, "reason": "empty_messages"}

    _, history_file, thumbs_dir = state_paths(state_dir)
    sessions = load_raw_sessions(history_file)
    sid = sanitize_session_id(payload.get("id"))
    now_ms = int(time.time() * 1000)

    existing = None
    remaining: list[dict] = []
    for item in sessions:
        if str(item.get("id") or "") == sid:
            existing = item
        else:
            remaining.append(item)

    created_at = int(existing.get("createdAt") or now_ms) if existing else now_ms
    thumb_path = str(existing.get("thumbPath") or "") if existing else ""
    image_path = str(payload.get("imagePath") or "").strip()
    if image_path and not os.path.isfile(image_path):
        image_path = ""

    # Generate thumbnail once per session (or refresh if missing on disk).
    if (not thumb_path or not os.path.isfile(thumb_path)) and image_path:
        thumb_path = generate_thumbnail(image_path, sid, thumbs_dir)

    entry = {
        "id": sid,
        "createdAt": created_at,
        "updatedAt": now_ms,
        "windowClass": str(payload.get("windowClass") or "")[:120],
        "windowTitle": str(payload.get("windowTitle") or "")[:240],
        "providerLabel": str(payload.get("providerLabel") or "")[:120],
        "webSearch": bool(payload.get("webSearch", False)),
        "selectedText": str(payload.get("selectedText") or "")[:MAX_SELECTED_TEXT],
        "imagePath": image_path,
        "thumbPath": thumb_path,
        "messages": messages,
    }

    updated = [entry] + remaining
    updated.sort(key=lambda s: int(s.get("updatedAt") or 0), reverse=True)
    updated = updated[:max_sessions]

    write_sessions_atomic(updated, state_dir=state_dir)
    prune_thumbs(updated, thumbs_dir)
    return {"ok": True, "session": entry, "count": len(updated)}


def matches_query(session: dict, query: str) -> bool:
    q = str(query or "").strip().lower()
    if not q:
        return True
    hay_parts = [
        str(session.get("windowClass") or ""),
        str(session.get("windowTitle") or ""),
        str(session.get("providerLabel") or ""),
        str(session.get("selectedText") or ""),
    ]
    for msg in session.get("messages") or []:
        if isinstance(msg, dict) and msg.get("text"):
            hay_parts.append(str(msg["text"]))
    return q in "\n".join(hay_parts).lower()


def list_sessions(
    state_dir: str = DEFAULT_STATE_DIR,
    config_path: str = CONFIG_PATH,
    query: str = "",
    limit: int = 0,
) -> dict:
    enabled, max_sessions = history_settings(config_path)
    _, history_file, _ = state_paths(state_dir)
    sessions = load_raw_sessions(history_file)
    sessions.sort(key=lambda s: int(s.get("updatedAt") or 0), reverse=True)
    if query:
        sessions = [s for s in sessions if matches_query(s, query)]
    if limit and limit > 0:
        sessions = sessions[:limit]
    return {
        "ok": True,
        "enabled": enabled,
        "maxSessions": max_sessions,
        "sessions": sessions,
    }


def get_session(
    session_id: str,
    state_dir: str = DEFAULT_STATE_DIR,
    config_path: str = CONFIG_PATH,
) -> dict:
    enabled, _ = history_settings(config_path)
    sid = str(session_id or "").strip()
    if not sid or not SESSION_ID_RE.match(sid):
        return {"ok": False, "error": "Invalid session id"}
    _, history_file, _ = state_paths(state_dir)
    for sess in load_raw_sessions(history_file):
        if str(sess.get("id") or "") == sid:
            return {"ok": True, "enabled": enabled, "session": sess}
    return {"ok": False, "error": "Session not found"}


def latest_session(
    state_dir: str = DEFAULT_STATE_DIR,
    config_path: str = CONFIG_PATH,
) -> dict:
    enabled, _ = history_settings(config_path)
    _, history_file, _ = state_paths(state_dir)
    sessions = load_raw_sessions(history_file)
    sessions.sort(key=lambda s: int(s.get("updatedAt") or 0), reverse=True)
    return {
        "ok": True,
        "enabled": enabled,
        "session": sessions[0] if sessions else None,
    }


def delete_session(
    session_id: str,
    state_dir: str = DEFAULT_STATE_DIR,
) -> dict:
    sid = str(session_id or "").strip()
    if not sid or not SESSION_ID_RE.match(sid):
        return {"ok": False, "error": "Invalid session id"}
    _, history_file, thumbs_dir = state_paths(state_dir)
    sessions = load_raw_sessions(history_file)
    kept = [s for s in sessions if str(s.get("id") or "") != sid]
    deleted = len(kept) != len(sessions)
    if deleted:
        write_sessions_atomic(kept, state_dir=state_dir)
        prune_thumbs(kept, thumbs_dir)
    return {"ok": True, "deleted": deleted, "remaining": len(kept)}


def clear_history(state_dir: str = DEFAULT_STATE_DIR) -> dict:
    _, history_file, thumbs_dir = state_paths(state_dir)
    prev = load_raw_sessions(history_file)
    write_sessions_atomic([], state_dir=state_dir)
    prune_thumbs([], thumbs_dir)
    return {"ok": True, "cleared": len(prev)}


def prune_history(
    state_dir: str = DEFAULT_STATE_DIR,
    config_path: str = CONFIG_PATH,
) -> dict:
    _, max_sessions = history_settings(config_path)
    _, history_file, thumbs_dir = state_paths(state_dir)
    sessions = load_raw_sessions(history_file)
    sessions.sort(key=lambda s: int(s.get("updatedAt") or 0), reverse=True)
    kept = sessions[:max_sessions]
    if os.path.exists(history_file) or kept:
        write_sessions_atomic(kept, state_dir=state_dir)
    prune_thumbs(kept, thumbs_dir)
    return {"ok": True, "remaining": len(kept), "maxSessions": max_sessions}


def main() -> int:
    parser = argparse.ArgumentParser(description="ScreenLens local session history backend")
    parser.add_argument("--state-dir", default=DEFAULT_STATE_DIR)
    parser.add_argument("--config", default=CONFIG_PATH)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_save = sub.add_parser("save")
    p_save.add_argument("source", nargs="?", default="-", help="JSON file path or '-' for stdin")

    p_list = sub.add_parser("list")
    p_list.add_argument("--query", default="")
    p_list.add_argument("--limit", type=int, default=0)

    sub.add_parser("latest")

    p_get = sub.add_parser("get")
    p_get.add_argument("session_id")

    p_del = sub.add_parser("delete")
    p_del.add_argument("session_id")

    sub.add_parser("clear")
    sub.add_parser("prune")

    args = parser.parse_args()
    try:
        if args.cmd == "save":
            if args.source == "-":
                raw = sys.stdin.readline()
                payload = json.loads(raw) if raw.strip() else {}
            else:
                with open(args.source, "r", encoding="utf-8") as f:
                    payload = json.load(f)
            res = save_session(payload, state_dir=args.state_dir, config_path=args.config)
        elif args.cmd == "list":
            res = list_sessions(
                state_dir=args.state_dir,
                config_path=args.config,
                query=args.query,
                limit=args.limit,
            )
        elif args.cmd == "latest":
            res = latest_session(state_dir=args.state_dir, config_path=args.config)
        elif args.cmd == "get":
            res = get_session(args.session_id, state_dir=args.state_dir, config_path=args.config)
        elif args.cmd == "delete":
            res = delete_session(args.session_id, state_dir=args.state_dir)
        elif args.cmd == "clear":
            res = clear_history(state_dir=args.state_dir)
        elif args.cmd == "prune":
            res = prune_history(state_dir=args.state_dir, config_path=args.config)
        else:
            res = {"ok": False, "error": "Unknown command"}
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), flush=True)
        return 1

    print(json.dumps(res), flush=True)
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
