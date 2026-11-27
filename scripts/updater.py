#!/usr/bin/env python3
"""Check for and apply ScreenLens git-managed plugin updates cleanly."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

PLUGIN_DIR = os.path.dirname(_SCRIPTS_DIR)
CACHE_PATH = os.path.expanduser("~/.cache/omarchy/screenlens-update.json")
CACHE_TTL_SEC = 3600
VALID_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def load_manifest(plugin_dir: str = PLUGIN_DIR) -> dict:
    path = os.path.join(plugin_dir, "manifest.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def validate_plugin_id(plugin_id: str) -> str:
    pid = str(plugin_id or "").strip()
    if not pid or ".." in pid or not VALID_ID_RE.match(pid):
        raise ValueError(f"Invalid plugin id '{plugin_id}'")
    return pid


def _git_env() -> dict:
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env.setdefault("GIT_SSH_COMMAND", "ssh -oBatchMode=yes")
    return env


def _run_git(plugin_dir: str, args: list[str], timeout: float = 12.0) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", plugin_dir, *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        env=_git_env(),
    )


def _read_cache(cache_path: str) -> dict | None:
    try:
        with open(cache_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def _write_cache(cache_path: str, payload: dict) -> None:
    parent = os.path.dirname(os.path.abspath(cache_path))
    os.makedirs(parent, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".screenlens-upd.", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, cache_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def clear_cache(cache_path: str = CACHE_PATH) -> None:
    try:
        if os.path.exists(cache_path):
            os.unlink(cache_path)
    except OSError:
        pass


def check_updates(
    plugin_dir: str = PLUGIN_DIR,
    cache_path: str = CACHE_PATH,
    force: bool = False,
    ttl_sec: int = CACHE_TTL_SEC,
) -> dict:
    manifest = load_manifest(plugin_dir)
    current_version = str(manifest.get("version") or "")
    plugin_id = str(manifest.get("id") or "io.github.cgranier.screenlens")

    if not os.path.isdir(os.path.join(plugin_dir, ".git")):
        return {
            "ok": True,
            "managed": False,
            "available": False,
            "behind": 0,
            "pluginId": plugin_id,
            "currentVersion": current_version,
            "localCommit": "",
            "remoteCommit": "",
            "cached": False,
            "checkedAt": int(time.time()),
            "reason": "not-git-managed",
        }

    head_proc = _run_git(plugin_dir, ["rev-parse", "--short=7", "HEAD"], timeout=5.0)
    local_commit = head_proc.stdout.strip() if head_proc.returncode == 0 else ""

    now = int(time.time())
    if not force:
        cached = _read_cache(cache_path)
        if (
            cached
            and cached.get("ok") is True
            and cached.get("managed") is True
            and cached.get("pluginDir") == os.path.abspath(plugin_dir)
            and cached.get("localCommit") == local_commit
            and (now - int(cached.get("checkedAt") or 0)) < ttl_sec
        ):
            out = dict(cached)
            out["cached"] = True
            return out

    fetch_proc = _run_git(plugin_dir, ["fetch", "--quiet", "origin", "HEAD"], timeout=15.0)
    if fetch_proc.returncode != 0:
        err = (fetch_proc.stderr or fetch_proc.stdout or "git fetch failed").strip().splitlines()
        msg = err[-1][:180] if err else "git fetch failed"
        return {
            "ok": False,
            "managed": True,
            "available": False,
            "behind": 0,
            "pluginId": plugin_id,
            "currentVersion": current_version,
            "localCommit": local_commit,
            "remoteCommit": "",
            "cached": False,
            "checkedAt": now,
            "error": msg,
        }

    remote_proc = _run_git(plugin_dir, ["rev-parse", "--short=7", "FETCH_HEAD"], timeout=5.0)
    remote_commit = remote_proc.stdout.strip() if remote_proc.returncode == 0 else ""

    count_proc = _run_git(plugin_dir, ["rev-list", "--count", "HEAD..FETCH_HEAD"], timeout=5.0)
    try:
        behind = max(0, int((count_proc.stdout or "0").strip()))
    except ValueError:
        behind = 0

    result = {
        "ok": True,
        "managed": True,
        "available": behind > 0,
        "behind": behind,
        "pluginId": plugin_id,
        "pluginDir": os.path.abspath(plugin_dir),
        "currentVersion": current_version,
        "localCommit": local_commit,
        "remoteCommit": remote_commit,
        "cached": False,
        "checkedAt": now,
    }
    _write_cache(cache_path, result)
    return result


def launch_updater(plugin_dir: str = PLUGIN_DIR) -> dict:
    manifest = load_manifest(plugin_dir)
    plugin_id = validate_plugin_id(str(manifest.get("id") or "io.github.cgranier.screenlens"))
    if not os.path.isdir(os.path.join(plugin_dir, ".git")):
        raise RuntimeError("Installed from a local copy (not git-managed). Pull from git or run ./bin/install.")

    term = shutil.which("xdg-terminal-exec")
    if not term:
        raise RuntimeError("xdg-terminal-exec not found")

    script_path = os.path.abspath(__file__)
    subprocess.Popen(
        [term, "/usr/bin/python3", script_path, "run-interactive", "--dir", os.path.abspath(plugin_dir)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return {"ok": True, "pluginId": plugin_id}


def run_interactive_update(plugin_dir: str = PLUGIN_DIR, cache_path: str = CACHE_PATH) -> int:
    manifest = load_manifest(plugin_dir)
    plugin_id = validate_plugin_id(str(manifest.get("id") or "io.github.cgranier.screenlens"))

    print(f"==> Updating ScreenLens ({plugin_id})...\n", flush=True)
    fetch_proc = _run_git(plugin_dir, ["fetch", "--quiet", "origin", "HEAD"], timeout=20.0)
    if fetch_proc.returncode == 0:
        log_proc = _run_git(plugin_dir, ["log", "--oneline", "--no-decorate", "-n", "12", "HEAD..FETCH_HEAD"], timeout=5.0)
        incoming = (log_proc.stdout or "").strip()
        if incoming:
            print("Incoming commits:", flush=True)
            print(incoming + "\n", flush=True)

    upd = subprocess.run(["omarchy", "plugin", "update", plugin_id, "--yes"])
    if upd.returncode != 0:
        print("\nUpdate failed. Review the error above.", flush=True)
        try:
            input("Press Enter to close...")
        except EOFError:
            pass
        return upd.returncode

    clear_cache(cache_path)
    print("\n==> Restarting omarchy-shell so updated QML loads fresh...", flush=True)
    subprocess.run(
        ["omarchy", "restart", "shell"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    print("ScreenLens updated successfully!", flush=True)
    time.sleep(1.4)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Check for and apply ScreenLens plugin updates.")
    parser.add_argument("--dir", default=PLUGIN_DIR)
    parser.add_argument("--cache", default=CACHE_PATH)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_check = sub.add_parser("check")
    p_check.add_argument("--force", action="store_true")

    sub.add_parser("apply")
    sub.add_parser("run-interactive")

    args = parser.parse_args()
    try:
        if args.cmd == "check":
            res = check_updates(plugin_dir=args.dir, cache_path=args.cache, force=args.force)
            print(json.dumps(res), flush=True)
            return 0 if res.get("ok") else 1
        if args.cmd == "apply":
            res = launch_updater(plugin_dir=args.dir)
            print(json.dumps(res), flush=True)
            return 0
        if args.cmd == "run-interactive":
            return run_interactive_update(plugin_dir=args.dir, cache_path=args.cache)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
