import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

import config as sl_config  # noqa: E402
import history as sl_history  # noqa: E402


class SessionHistoryTests(unittest.TestCase):
    def _make_config(
        self,
        tmpdir: str,
        enabled: bool = True,
        max_sessions: int = 15,
        retention_days: int = 1,
        save_images: bool = True,
    ) -> str:
        cfg_path = os.path.join(tmpdir, "screenlens.json")
        cfg = sl_config.normalize_config({
            "historyEnabled": enabled,
            "historyMaxSessions": max_sessions,
            "historyRetentionDays": retention_days,
            "historySaveImages": save_images,
            "providers": {
                "gemini": {"apiKey": "sk-secret-never-store", "model": "gemini-2.5-flash"},
            },
        })
        sl_config.save_config(cfg, path=cfg_path)
        return cfg_path

    def _make_png(self, path: str, color: str = "#7aa2f7") -> None:
        proc = subprocess.run(
            ["magick", "-size", "640x400", "xc:#181a22", "-fill", color, "-draw", "rectangle 40,40 300,200", path],
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr.decode("utf-8", "replace"))

    def test_save_permissions_durable_frame_upsert_and_no_secret_leak(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = os.path.join(tmp, "state")
            cfg_path = self._make_config(tmp, enabled=True, max_sessions=5, retention_days=7)
            img1 = os.path.join(tmp, "capture1.png")
            img2 = os.path.join(tmp, "capture2.png")
            self._make_png(img1, "#7aa2f7")
            self._make_png(img2, "#f7768e")

            res = sl_history.save_session(
                {
                    "windowClass": "chromium",
                    "windowTitle": "GitHub — ScreenLens",
                    "providerLabel": "gemini · gemini-2.5-flash",
                    "webSearch": True,
                    "selectedText": "hello world",
                    "imagePath": img1,
                    "messages": [
                        {"role": "user", "text": "What is this repo?"},
                        {"role": "assistant", "text": "It is ScreenLens for Omarchy."},
                    ],
                },
                state_dir=state_dir,
                config_path=cfg_path,
            )
            self.assertTrue(res["ok"])
            sid = res["session"]["id"]
            frame = res["session"]["framePath"]
            self.assertTrue(frame and os.path.isfile(frame))
            self.assertEqual(res["session"]["thumbPath"], frame)
            self.assertEqual(res["session"]["frameWidth"], 640)
            self.assertEqual(res["session"]["frameHeight"], 400)

            _, hist_file, frames_dir, _ = sl_history.state_paths(state_dir)
            self.assertEqual(stat.S_IMODE(os.stat(state_dir).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(hist_file).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(frames_dir).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(frame).st_mode), 0o600)

            with open(hist_file, "r", encoding="utf-8") as f:
                raw_text = f.read()
            self.assertNotIn("sk-secret-never-store", raw_text)

            # Upsert same session id preserves original durable frame unless replaceFrame=True.
            with open(frame, "rb") as rf:
                orig_bytes = rf.read()
            created = res["session"]["createdAt"]
            time.sleep(0.01)
            res2 = sl_history.save_session(
                {
                    "id": sid,
                    "windowClass": "chromium",
                    "windowTitle": "GitHub — ScreenLens",
                    "providerLabel": "gemini · gemini-2.5-flash",
                    "imagePath": img2,
                    "messages": [
                        {"role": "user", "text": "What is this repo?"},
                        {"role": "assistant", "text": "It is ScreenLens for Omarchy."},
                        {"role": "user", "text": "How do I install it?"},
                        {"role": "assistant", "text": "Run bin/install."},
                    ],
                },
                state_dir=state_dir,
                config_path=cfg_path,
            )
            self.assertEqual(res2["count"], 1)
            self.assertEqual(res2["session"]["createdAt"], created)
            self.assertEqual(len(res2["session"]["messages"]), 4)
            self.assertEqual(res2["session"]["framePath"], frame)
            with open(frame, "rb") as rf2:
                self.assertEqual(rf2.read(), orig_bytes)

    def test_ttl_expiry_count_prune_and_save_images_opt_out(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = os.path.join(tmp, "state")
            cfg_path = self._make_config(tmp, enabled=True, max_sessions=5, retention_days=1, save_images=True)
            img_path = os.path.join(tmp, "cap.png")
            self._make_png(img_path)

            t0 = 1_700_000_000_000
            day_ms = 86_400_000

            old_res = sl_history.save_session(
                {
                    "windowClass": "oldapp",
                    "imagePath": img_path,
                    "messages": [{"role": "user", "text": "Old Q"}, {"role": "assistant", "text": "Old A"}],
                },
                state_dir=state_dir,
                config_path=cfg_path,
                now_ms=t0,
            )
            old_frame = old_res["session"]["framePath"]
            self.assertTrue(os.path.isfile(old_frame))

            # 2 days later (> 1 day TTL), saving/listing auto-prunes the expired session + its frame.
            fresh_res = sl_history.save_session(
                {
                    "windowClass": "newapp",
                    "imagePath": img_path,
                    "messages": [{"role": "user", "text": "New Q"}, {"role": "assistant", "text": "New A"}],
                },
                state_dir=state_dir,
                config_path=cfg_path,
                now_ms=t0 + 2 * day_ms,
            )
            fresh_frame = fresh_res["session"]["framePath"]
            self.assertFalse(os.path.exists(old_frame))
            self.assertTrue(os.path.isfile(fresh_frame))

            listed = sl_history.list_sessions(state_dir=state_dir, config_path=cfg_path, now_ms=t0 + 2 * day_ms)
            self.assertEqual(len(listed["sessions"]), 1)
            self.assertEqual(listed["sessions"][0]["windowClass"], "newapp")
            self.assertGreater(listed["storageBytes"], 0)

            # Disabling historySaveImages + pruning immediately wipes saved screenshot files while keeping text.
            self._make_config(tmp, enabled=True, max_sessions=5, retention_days=7, save_images=False)
            pruned = sl_history.prune_history(state_dir=state_dir, config_path=cfg_path, now_ms=t0 + 2 * day_ms)
            self.assertEqual(pruned["remaining"], 1)
            self.assertFalse(os.path.exists(fresh_frame))

    def test_hard_disk_cap_drops_oldest_frames_first(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = os.path.join(tmp, "state")
            cfg_path = self._make_config(tmp, enabled=True, max_sessions=10, retention_days=7, save_images=True)
            img_path = os.path.join(tmp, "cap.png")
            self._make_png(img_path)

            t0 = 1_700_000_000_000
            r1 = sl_history.save_session(
                {"windowClass": "a", "imagePath": img_path, "messages": [{"role": "user", "text": "1"}, {"role": "assistant", "text": "1"}]},
                state_dir=state_dir,
                config_path=cfg_path,
                now_ms=t0,
            )
            sz = os.path.getsize(r1["session"]["framePath"])
            # Set disk ceiling just above 1 frame so saving a 2nd frame drops the older frame file.
            r2 = sl_history.save_session(
                {"windowClass": "b", "imagePath": img_path, "messages": [{"role": "user", "text": "2"}, {"role": "assistant", "text": "2"}]},
                state_dir=state_dir,
                config_path=cfg_path,
                now_ms=t0 + 1000,
                max_frame_bytes=sz + 100,
            )
            self.assertFalse(os.path.exists(r1["session"]["framePath"]))
            self.assertTrue(os.path.isfile(r2["session"]["framePath"]))

    def test_opt_out_skips_saving(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = os.path.join(tmp, "state")
            cfg_path = self._make_config(tmp, enabled=False, max_sessions=10)
            res = sl_history.save_session(
                {"messages": [{"role": "user", "text": "Do not store"}, {"role": "assistant", "text": "Okay"}]},
                state_dir=state_dir,
                config_path=cfg_path,
            )
            self.assertTrue(res["ok"])
            self.assertTrue(res.get("skipped"))
            latest = sl_history.latest_session(state_dir=state_dir, config_path=cfg_path)
            self.assertFalse(latest["enabled"])
            self.assertIsNone(latest["session"])

    def test_cli_save_and_latest_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = os.path.join(tmp, "state")
            cfg_path = self._make_config(tmp, enabled=True, max_sessions=10, retention_days=7)
            script = os.path.join(os.path.dirname(__file__), "..", "scripts", "history.py")
            payload = json.dumps({
                "windowClass": "ghostty",
                "messages": [
                    {"role": "user", "text": "Fix traceback"},
                    {"role": "assistant", "text": "Install missing module."},
                ],
            })
            p_save = subprocess.run(
                [sys.executable, script, "--state-dir", state_dir, "--config", cfg_path, "save", "-"],
                input=payload + "\n",
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(p_save.returncode, 0, p_save.stderr)
            saved = json.loads(p_save.stdout)
            self.assertTrue(saved["ok"])

            p_latest = subprocess.run(
                [sys.executable, script, "--state-dir", state_dir, "--config", cfg_path, "latest"],
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(p_latest.returncode, 0, p_latest.stderr)
            latest = json.loads(p_latest.stdout)
            self.assertEqual(latest["session"]["id"], saved["session"]["id"])

    def test_pinned_note_save_get_clear_and_0600_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = os.path.join(tmp, "state")
            saved = sl_history.save_pinned(
                {
                    "sessionId": "sl-99",
                    "providerLabel": "anthropic · haiku",
                    "webSearch": True,
                    "windowClass": "ghostty",
                    "messages": [
                        {"role": "user", "text": "How do I restart waybar?"},
                        {"role": "assistant", "text": "Run `omarchy restart shell`."},
                    ],
                },
                state_dir=state_dir,
            )
            self.assertTrue(saved["ok"])
            self.assertEqual(saved["pinned"]["title"], "How do I restart waybar?")
            self.assertEqual(saved["pinned"]["answer"], "Run `omarchy restart shell`.")
            pfile = sl_history.pinned_path(state_dir)
            self.assertEqual(stat.S_IMODE(os.stat(pfile).st_mode), 0o600)

            fetched = sl_history.get_pinned(state_dir=state_dir)
            self.assertTrue(fetched["ok"])
            self.assertEqual(fetched["pinned"]["sessionId"], "sl-99")

            cleared = sl_history.clear_pinned(state_dir=state_dir)
            self.assertTrue(cleared["ok"])
            self.assertTrue(cleared["cleared"])
            self.assertFalse(os.path.exists(pfile))
            self.assertIsNone(sl_history.get_pinned(state_dir=state_dir)["pinned"])


if __name__ == "__main__":
    unittest.main()
