#!/usr/bin/env python3
"""Owner-only (0600) local session history store with TTL expiry, disk cap, and compact frames."""

import argparse
import glob
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
TMP_PREFIX = "/tmp/omarchy-screenlens-"
TMP_STALE_SECONDS = 900  # 15 minutes
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MAX_MESSAGES = 40
MAX_MSG_CHARS = 16000
MAX_SELECTED_TEXT = 4000
MAX_FRAME_DIM = "1440x1440>"
FRAME_JPEG_QUALITY = "78"
MAX_TOTAL_FRAME_BYTES = 10 * 1024 * 1024  # Hard 10 MB ceiling on saved frames


def state_paths(state_dir: str = DEFAULT_STATE_DIR) -> tuple[str, str, str, str]:
    root = os.path.abspath(os.path.expanduser(state_dir or DEFAULT_STATE_DIR))
    history_file = os.path.join(root, "history.json")
    frames_dir = os.path.join(root, "frames")
    legacy_thumbs_dir = os.path.join(root, "thumbs")
    return root, history_file, frames_dir, legacy_thumbs_dir


def pinned_path(state_dir: str = DEFAULT_STATE_DIR) -> str:
    root, _, _, _ = state_paths(state_dir)
    return os.path.join(root, "pinned.json")


def save_pinned(payload: dict, state_dir: str = DEFAULT_STATE_DIR) -> dict:
    root, _, _, _ = state_paths(state_dir)
    ensure_private_dir(root)
    pfile = pinned_path(state_dir)

    messages = sanitize_messages(payload.get("messages"))
    answer = str(payload.get("answer") or "").strip()[:MAX_MSG_CHARS]
    if not answer:
        for msg in reversed(messages):
            if msg.get("role") == "assistant" and msg.get("text"):
                answer = str(msg["text"])[:MAX_MSG_CHARS]
                break
    if not answer and not messages:
        return {"ok": False, "error": "Nothing to pin"}

    raw_sid = str(payload.get("sessionId") or payload.get("id") or "").strip()
    sid = raw_sid if (raw_sid and SESSION_ID_RE.match(raw_sid)) else ""
    title = str(payload.get("title") or "").strip()[:160]
    if not title:
        for msg in messages:
            if msg.get("role") == "user" and msg.get("text"):
                title = " ".join(str(msg["text"]).split())[:160]
                break

    entry = {
        "schemaVersion": 1,
        "pinnedAt": int(time.time() * 1000),
        "sessionId": sid,
        "title": title or "ScreenLens Note",
        "answer": answer,
        "providerLabel": str(payload.get("providerLabel") or "")[:120],
        "webSearch": bool(payload.get("webSearch", False)),
        "windowClass": str(payload.get("windowClass") or "")[:120],
        "windowTitle": str(payload.get("windowTitle") or "")[:240],
        "selectedText": str(payload.get("selectedText") or "")[:MAX_SELECTED_TEXT],
        "messages": messages,
    }

    fd, tmp_path = tempfile.mkstemp(prefix=".pinned.", suffix=".tmp", dir=root)
    try:
        os.chmod(tmp_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(entry, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, pfile)
        os.chmod(pfile, 0o600)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return {"ok": True, "pinned": entry}


def get_pinned(state_dir: str = DEFAULT_STATE_DIR) -> dict:
    pfile = pinned_path(state_dir)
    try:
        with open(pfile, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {"ok": True, "pinned": None}
    if not isinstance(data, dict) or not (data.get("answer") or data.get("messages")):
        return {"ok": True, "pinned": None}
    return {"ok": True, "pinned": data}


def clear_pinned(state_dir: str = DEFAULT_STATE_DIR) -> dict:
    pfile = pinned_path(state_dir)
    removed = False
    if os.path.exists(pfile):
        try:
            os.unlink(pfile)
            removed = True
        except OSError:
            pass
    return {"ok": True, "cleared": removed}


def ensure_private_dir(path: str) -> None:
    os.makedirs(path, mode=0o700, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def cleanup_stale_tmp(force_all: bool = False) -> None:
    now = time.time()
    patterns = (f"{TMP_PREFIX}*.png", f"{TMP_PREFIX}*.jpg", f"{TMP_PREFIX}*.json", f"{TMP_PREFIX}*.md")
    for pattern in patterns:
        for path in glob.glob(pattern):
            try:
                if force_all or (now - os.path.getmtime(path) > TMP_STALE_SECONDS):
                    os.unlink(path)
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
    root, history_file, _, _ = state_paths(state_dir)
    ensure_private_dir(root)
    payload = {
        "schemaVersion": 2,
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


def read_image_dimensions(path: str) -> tuple[int, int]:
    magick = shutil.which("magick")
    if not magick or not path or not os.path.isfile(path):
        return 0, 0
    try:
        proc = subprocess.run(
            [magick, "identify", "-format", "%w %h", path],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if proc.returncode == 0:
            parts = proc.stdout.strip().split()
            if len(parts) == 2:
                return int(parts[0]), int(parts[1])
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return 0, 0


def generate_durable_frame(source_path: str, session_id: str, frames_dir: str) -> tuple[str, int, int]:
    """Create a single compact, metadata-stripped 0600 JPEG used for both thumbnail preview and visual Resume."""
    src = str(source_path or "").strip()
    if not src or not os.path.isfile(src):
        return "", 0, 0
    ensure_private_dir(frames_dir)
    dest = os.path.join(frames_dir, f"{session_id}.jpg")
    if os.path.abspath(src) == os.path.abspath(dest):
        w, h = read_image_dimensions(dest)
        return dest, w, h
    magick = shutil.which("magick")
    if not magick:
        return "", 0, 0
    tmp_dest = os.path.join(frames_dir, f".{session_id}.{os.getpid()}.jpg")
    try:
        proc = subprocess.run(
            [magick, src, "-auto-orient", "-resize", MAX_FRAME_DIM, "-strip", "-quality", FRAME_JPEG_QUALITY, tmp_dest],
            capture_output=True,
            timeout=10,
        )
        if proc.returncode == 0 and os.path.isfile(tmp_dest):
            os.chmod(tmp_dest, 0o600)
            os.replace(tmp_dest, dest)
            os.chmod(dest, 0o600)
            w, h = read_image_dimensions(dest)
            return dest, w, h
    except (OSError, subprocess.SubprocessError):
        pass
    finally:
        if os.path.exists(tmp_dest):
            try:
                os.unlink(tmp_dest)
            except OSError:
                pass
    return "", 0, 0


def history_settings(config_path: str = CONFIG_PATH) -> dict:
    cfg = load_config(config_path)
    enabled = bool(cfg.get("historyEnabled", True))
    try:
        max_sessions = int(cfg.get("historyMaxSessions", 15))
    except (TypeError, ValueError):
        max_sessions = 15
    try:
        retention_days = int(cfg.get("historyRetentionDays", 1))
    except (TypeError, ValueError):
        retention_days = 1
    save_images = bool(cfg.get("historySaveImages", True))
    return {
        "enabled": enabled,
        "maxSessions": max(1, min(100, max_sessions)),
        "retentionDays": max(1, min(90, retention_days)),
        "saveImages": save_images,
    }


def _session_frame_path(sess: dict) -> str:
    fp = str(sess.get("framePath") or sess.get("thumbPath") or "").strip()
    return fp if (fp and os.path.isfile(fp)) else ""


def prune_media_files(sessions: list[dict], frames_dir: str, legacy_thumbs_dir: str) -> None:
    keep = set()
    for sess in sessions:
        fp = str(sess.get("framePath") or "").strip()
        if fp:
            keep.add(os.path.abspath(fp))
    for directory in (frames_dir, legacy_thumbs_dir):
        if not os.path.isdir(directory):
            continue
        for name in os.listdir(directory):
            full = os.path.abspath(os.path.join(directory, name))
            if full not in keep:
                try:
                    if os.path.isfile(full):
                        os.unlink(full)
                except OSError:
                    pass


def enforce_policies(
    sessions: list[dict],
    settings: dict,
    frames_dir: str,
    legacy_thumbs_dir: str,
    now_ms: int | None = None,
    max_frame_bytes: int = MAX_TOTAL_FRAME_BYTES,
) -> tuple[list[dict], bool]:
    """Apply time-based TTL expiry, count cap, saveImages opt-out, and hard disk ceiling."""
    now = int(time.time() * 1000) if now_ms is None else int(now_ms)
    cutoff_ms = now - int(settings["retentionDays"]) * 86400 * 1000
    save_images = bool(settings["saveImages"])
    max_sessions = int(settings["maxSessions"])

    changed = False
    ordered = sorted(sessions, key=lambda s: int(s.get("updatedAt") or 0), reverse=True)
    kept: list[dict] = []

    for sess in ordered:
        ts = int(sess.get("updatedAt") or sess.get("createdAt") or 0)
        if ts > 0 and ts < cutoff_ms:
            changed = True
            continue
        if len(kept) >= max_sessions:
            changed = True
            continue
        item = dict(sess)
        # Normalize legacy thumbPath -> framePath and drop missing/disabled frames.
        fp = _session_frame_path(item)
        if not save_images:
            if fp or item.get("framePath") or item.get("thumbPath"):
                changed = True
            item["framePath"] = ""
            item["thumbPath"] = ""
            item["frameWidth"] = 0
            item["frameHeight"] = 0
        else:
            if fp != str(item.get("framePath") or "") or fp != str(item.get("thumbPath") or ""):
                changed = True
            item["framePath"] = fp
            item["thumbPath"] = fp
        kept.append(item)

    # Enforce hard disk ceiling across saved frames (keep newest frames, drop oldest first).
    if save_images and max_frame_bytes > 0:
        running_bytes = 0
        for item in kept:
            fp = str(item.get("framePath") or "")
            if not fp or not os.path.isfile(fp):
                continue
            try:
                sz = os.path.getsize(fp)
            except OSError:
                sz = 0
            if running_bytes + sz > max_frame_bytes:
                item["framePath"] = ""
                item["thumbPath"] = ""
                item["frameWidth"] = 0
                item["frameHeight"] = 0
                changed = True
            else:
                running_bytes += sz

    prune_media_files(kept, frames_dir, legacy_thumbs_dir)
    return kept, changed


def compute_storage_bytes(state_dir: str = DEFAULT_STATE_DIR) -> int:
    _, history_file, frames_dir, legacy_thumbs_dir = state_paths(state_dir)
    total = 0
    if os.path.isfile(history_file):
        try:
            total += os.path.getsize(history_file)
        except OSError:
            pass
    for directory in (frames_dir, legacy_thumbs_dir):
        if not os.path.isdir(directory):
            continue
        for name in os.listdir(directory):
            full = os.path.join(directory, name)
            try:
                if os.path.isfile(full):
                    total += os.path.getsize(full)
            except OSError:
                pass
    return total


def save_session(
    payload: dict,
    state_dir: str = DEFAULT_STATE_DIR,
    config_path: str = CONFIG_PATH,
    now_ms: int | None = None,
    max_frame_bytes: int = MAX_TOTAL_FRAME_BYTES,
) -> dict:
    settings = history_settings(config_path)
    if not settings["enabled"]:
        return {"ok": True, "skipped": True, "reason": "history_disabled"}

    messages = sanitize_messages(payload.get("messages"))
    if not messages:
        return {"ok": True, "skipped": True, "reason": "empty_messages"}

    _, history_file, frames_dir, legacy_thumbs_dir = state_paths(state_dir)
    sessions = load_raw_sessions(history_file)
    sid = sanitize_session_id(payload.get("id"))
    ts_now = int(time.time() * 1000) if now_ms is None else int(now_ms)

    existing = None
    remaining: list[dict] = []
    for item in sessions:
        if str(item.get("id") or "") == sid:
            existing = item
        else:
            remaining.append(item)

    created_at = int(existing.get("createdAt") or ts_now) if existing else ts_now
    existing_frame = _session_frame_path(existing) if existing else ""
    existing_fw = int(existing.get("frameWidth") or 0) if existing else 0
    existing_fh = int(existing.get("frameHeight") or 0) if existing else 0
    replace_frame = bool(payload.get("replaceFrame", False))

    src_image = str(payload.get("imagePath") or "").strip()
    frame_path = ""
    frame_w = 0
    frame_h = 0

    if settings["saveImages"]:
        if existing_frame and not replace_frame:
            frame_path = existing_frame
            frame_w = existing_fw
            frame_h = existing_fh
            if (frame_w <= 0 or frame_h <= 0) and os.path.isfile(frame_path):
                frame_w, frame_h = read_image_dimensions(frame_path)
        elif src_image and os.path.isfile(src_image):
            frame_path, frame_w, frame_h = generate_durable_frame(src_image, sid, frames_dir)

    entry = {
        "id": sid,
        "createdAt": created_at,
        "updatedAt": ts_now,
        "windowClass": str(payload.get("windowClass") or (existing.get("windowClass") if existing else "") or "")[:120],
        "windowTitle": str(payload.get("windowTitle") or (existing.get("windowTitle") if existing else "") or "")[:240],
        "providerLabel": str(payload.get("providerLabel") or "")[:120],
        "webSearch": bool(payload.get("webSearch", False)),
        "selectedText": str(payload.get("selectedText") or "")[:MAX_SELECTED_TEXT],
        "framePath": frame_path,
        "thumbPath": frame_path,
        "frameWidth": frame_w,
        "frameHeight": frame_h,
        "messages": messages,
    }

    updated, _ = enforce_policies(
        [entry] + remaining,
        settings,
        frames_dir,
        legacy_thumbs_dir,
        now_ms=ts_now,
        max_frame_bytes=max_frame_bytes,
    )
    write_sessions_atomic(updated, state_dir=state_dir)
    cleanup_stale_tmp(force_all=False)
    saved_entry = next((s for s in updated if s.get("id") == sid), entry)
    return {
        "ok": True,
        "session": saved_entry,
        "count": len(updated),
        "storageBytes": compute_storage_bytes(state_dir),
    }


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


def _load_and_auto_prune(
    state_dir: str,
    config_path: str,
    now_ms: int | None = None,
) -> tuple[list[dict], dict]:
    settings = history_settings(config_path)
    _, history_file, frames_dir, legacy_thumbs_dir = state_paths(state_dir)
    raw = load_raw_sessions(history_file)
    kept, changed = enforce_policies(raw, settings, frames_dir, legacy_thumbs_dir, now_ms=now_ms)
    if changed and os.path.exists(history_file):
        write_sessions_atomic(kept, state_dir=state_dir)
    return kept, settings


def list_sessions(
    state_dir: str = DEFAULT_STATE_DIR,
    config_path: str = CONFIG_PATH,
    query: str = "",
    limit: int = 0,
    now_ms: int | None = None,
) -> dict:
    sessions, settings = _load_and_auto_prune(state_dir, config_path, now_ms=now_ms)
    if query:
        sessions = [s for s in sessions if matches_query(s, query)]
    if limit and limit > 0:
        sessions = sessions[:limit]
    return {
        "ok": True,
        "enabled": settings["enabled"],
        "maxSessions": settings["maxSessions"],
        "retentionDays": settings["retentionDays"],
        "saveImages": settings["saveImages"],
        "storageBytes": compute_storage_bytes(state_dir),
        "sessions": sessions,
    }


def get_session(
    session_id: str,
    state_dir: str = DEFAULT_STATE_DIR,
    config_path: str = CONFIG_PATH,
    now_ms: int | None = None,
) -> dict:
    sid = str(session_id or "").strip()
    if not sid or not SESSION_ID_RE.match(sid):
        return {"ok": False, "error": "Invalid session id"}
    sessions, settings = _load_and_auto_prune(state_dir, config_path, now_ms=now_ms)
    for sess in sessions:
        if str(sess.get("id") or "") == sid:
            return {"ok": True, "enabled": settings["enabled"], "session": sess}
    return {"ok": False, "error": "Session not found"}


def latest_session(
    state_dir: str = DEFAULT_STATE_DIR,
    config_path: str = CONFIG_PATH,
    now_ms: int | None = None,
) -> dict:
    sessions, settings = _load_and_auto_prune(state_dir, config_path, now_ms=now_ms)
    return {
        "ok": True,
        "enabled": settings["enabled"],
        "session": sessions[0] if sessions else None,
    }


def delete_session(
    session_id: str,
    state_dir: str = DEFAULT_STATE_DIR,
) -> dict:
    sid = str(session_id or "").strip()
    if not sid or not SESSION_ID_RE.match(sid):
        return {"ok": False, "error": "Invalid session id"}
    _, history_file, frames_dir, legacy_thumbs_dir = state_paths(state_dir)
    sessions = load_raw_sessions(history_file)
    kept = [s for s in sessions if str(s.get("id") or "") != sid]
    deleted = len(kept) != len(sessions)
    if deleted:
        write_sessions_atomic(kept, state_dir=state_dir)
        prune_media_files(kept, frames_dir, legacy_thumbs_dir)
    return {
        "ok": True,
        "deleted": deleted,
        "remaining": len(kept),
        "storageBytes": compute_storage_bytes(state_dir),
    }


def clear_history(state_dir: str = DEFAULT_STATE_DIR, purge_tmp: bool = True) -> dict:
    _, history_file, frames_dir, legacy_thumbs_dir = state_paths(state_dir)
    prev = load_raw_sessions(history_file)
    write_sessions_atomic([], state_dir=state_dir)
    prune_media_files([], frames_dir, legacy_thumbs_dir)
    if purge_tmp:
        cleanup_stale_tmp(force_all=False)
    return {
        "ok": True,
        "cleared": len(prev),
        "storageBytes": compute_storage_bytes(state_dir),
    }


def prune_history(
    state_dir: str = DEFAULT_STATE_DIR,
    config_path: str = CONFIG_PATH,
    now_ms: int | None = None,
) -> dict:
    settings = history_settings(config_path)
    _, history_file, frames_dir, legacy_thumbs_dir = state_paths(state_dir)
    raw = load_raw_sessions(history_file)
    kept, _ = enforce_policies(raw, settings, frames_dir, legacy_thumbs_dir, now_ms=now_ms)
    if os.path.exists(history_file) or kept:
        write_sessions_atomic(kept, state_dir=state_dir)
    cleanup_stale_tmp(force_all=False)
    return {
        "ok": True,
        "remaining": len(kept),
        "maxSessions": settings["maxSessions"],
        "retentionDays": settings["retentionDays"],
        "saveImages": settings["saveImages"],
        "storageBytes": compute_storage_bytes(state_dir),
    }


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

    p_pin_set = sub.add_parser("pin-set")
    p_pin_set.add_argument("source", nargs="?", default="-", help="JSON file path or '-' for stdin")
    sub.add_parser("pin-get")
    sub.add_parser("pin-clear")

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
        elif args.cmd == "pin-set":
            if args.source == "-":
                raw = sys.stdin.readline()
                payload = json.loads(raw) if raw.strip() else {}
            else:
                with open(args.source, "r", encoding="utf-8") as f:
                    payload = json.load(f)
            res = save_pinned(payload, state_dir=args.state_dir)
        elif args.cmd == "pin-get":
            res = get_pinned(state_dir=args.state_dir)
        elif args.cmd == "pin-clear":
            res = clear_pinned(state_dir=args.state_dir)
        else:
            res = {"ok": False, "error": "Unknown command"}
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), flush=True)
        return 1

    print(json.dumps(res), flush=True)
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
