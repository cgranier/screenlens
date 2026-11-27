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
    def _make_config(self, tmpdir: str, enabled: bool = True, max_sessions: int = 15) -> str:
        cfg_path = os.path.join(tmpdir, "screenlens.json")
        cfg = sl_config.normalize_config({
            "historyEnabled": enabled,
            "historyMaxSessions": max_sessions,
            "providers": {
                "gemini": {"apiKey": "sk-secret-never-store", "model": "gemini-2.5-flash"},
            },
        })
        sl_config.save_config(cfg, path=cfg_path)
        return cfg_path

    def _make_png(self, path: str) -> None:
        proc = subprocess.run(
            ["magick", "-size", "640x400", "xc:#181a22", "-fill", "#7aa2f7", "-draw", "rectangle 40,40 300,200", path],
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr.decode("utf-8", "replace"))

    def test_save_permissions_thumbnail_upsert_and_no_secret_leak(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = os.path.join(tmp, "state")
            cfg_path = self._make_config(tmp, enabled=True, max_sessions=5)
            img_path = os.path.join(tmp, "capture.png")
            self._make_png(img_path)

            res = sl_history.save_session(
                {
                    "windowClass": "chromium",
                    "windowTitle": "GitHub — ScreenLens",
                    "providerLabel": "gemini · gemini-2.5-flash",
                    "webSearch": True,
                    "selectedText": "hello world",
                    "imagePath": img_path,
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
            thumb = res["session"]["thumbPath"]
            self.assertTrue(thumb and os.path.isfile(thumb))

            _, hist_file, thumbs_dir = sl_history.state_paths(state_dir)
            self.assertEqual(stat.S_IMODE(os.stat(state_dir).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(hist_file).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(thumbs_dir).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(thumb).st_mode), 0o600)

            with open(hist_file, "r", encoding="utf-8") as f:
                raw_text = f.read()
            self.assertNotIn("sk-secret-never-store", raw_text)

            # Upsert same session id with follow-up turn preserves createdAt and count=1.
            created = res["session"]["createdAt"]
            time.sleep(0.01)
            res2 = sl_history.save_session(
                {
                    "id": sid,
                    "windowClass": "chromium",
                    "windowTitle": "GitHub — ScreenLens",
                    "providerLabel": "gemini · gemini-2.5-flash",
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
            self.assertEqual(res2["session"]["thumbPath"], thumb)

    def test_auto_prune_removes_expired_sessions_and_orphan_thumbnails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = os.path.join(tmp, "state")
            cfg_path = self._make_config(tmp, enabled=True, max_sessions=2)
            img_path = os.path.join(tmp, "cap.png")
            self._make_png(img_path)

            thumbs = []
            for idx in range(3):
                time.sleep(0.01)
                res = sl_history.save_session(
                    {
                        "windowClass": f"app{idx}",
                        "imagePath": img_path,
                        "messages": [
                            {"role": "user", "text": f"Question {idx}"},
                            {"role": "assistant", "text": f"Answer {idx}"},
                        ],
                    },
                    state_dir=state_dir,
                    config_path=cfg_path,
                )
                thumbs.append(res["session"]["thumbPath"])

            listed = sl_history.list_sessions(state_dir=state_dir, config_path=cfg_path)
            self.assertEqual(len(listed["sessions"]), 2)
            self.assertEqual(listed["sessions"][0]["windowClass"], "app2")
            self.assertEqual(listed["sessions"][1]["windowClass"], "app1")
            self.assertFalse(os.path.exists(thumbs[0]))
            self.assertTrue(os.path.exists(thumbs[1]))
            self.assertTrue(os.path.exists(thumbs[2]))

            # Search query matches across user/assistant/app fields.
            filtered = sl_history.list_sessions(state_dir=state_dir, config_path=cfg_path, query="Question 1")
            self.assertEqual(len(filtered["sessions"]), 1)
            self.assertEqual(filtered["sessions"][0]["windowClass"], "app1")

            # Delete single session removes its thumbnail too.
            sid_del = listed["sessions"][0]["id"]
            del_res = sl_history.delete_session(sid_del, state_dir=state_dir)
            self.assertTrue(del_res["deleted"])
            self.assertFalse(os.path.exists(thumbs[2]))

            # Clear removes everything.
            clr = sl_history.clear_history(state_dir=state_dir)
            self.assertEqual(clr["cleared"], 1)
            self.assertFalse(os.path.exists(thumbs[1]))

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
            cfg_path = self._make_config(tmp, enabled=True, max_sessions=10)
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
                input=payload,
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


if __name__ == "__main__":
    unittest.main()
