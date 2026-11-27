#!/usr/bin/env python3
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("updater", os.path.join(ROOT_DIR, "scripts/updater.py"))
updater_mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(updater_mod)


def _git(cwd: str, *args: str) -> None:
    env = dict(
        os.environ,
        GIT_AUTHOR_NAME="Tester",
        GIT_AUTHOR_EMAIL="tester@example.invalid",
        GIT_COMMITTER_NAME="Tester",
        GIT_COMMITTER_EMAIL="tester@example.invalid",
    )
    subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, text=True, env=env)


class UpdaterTests(unittest.TestCase):
    def test_validate_plugin_id_guards(self):
        self.assertEqual(updater_mod.validate_plugin_id("io.github.cgranier.screenlens"), "io.github.cgranier.screenlens")
        for bad in ["", "../evil", "foo;rm -rf /", "has space", "-flag"]:
            with self.assertRaises(ValueError):
                updater_mod.validate_plugin_id(bad)

    def test_non_git_directory_reports_unmanaged(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "manifest.json"), "w", encoding="utf-8") as f:
                json.dump({"id": "io.github.cgranier.screenlens", "version": "0.9.1"}, f)
            res = updater_mod.check_updates(plugin_dir=tmp, cache_path=os.path.join(tmp, "cache.json"))
            self.assertTrue(res["ok"])
            self.assertFalse(res["managed"])
            self.assertFalse(res["available"])
            self.assertEqual(res["behind"], 0)

    def test_git_update_detection_and_cache_behavior(self):
        with tempfile.TemporaryDirectory() as tmp:
            bare = os.path.join(tmp, "remote.git")
            work = os.path.join(tmp, "work")
            installed = os.path.join(tmp, "installed")
            cache = os.path.join(tmp, "cache.json")

            os.makedirs(bare)
            _git(bare, "init", "--bare", "-b", "main")
            subprocess.run(["git", "clone", bare, work], check=True, capture_output=True)
            with open(os.path.join(work, "manifest.json"), "w", encoding="utf-8") as f:
                json.dump({"id": "io.github.cgranier.screenlens", "version": "0.9.1"}, f)
            _git(work, "add", "manifest.json")
            _git(work, "commit", "-m", "initial")
            _git(work, "push", "-u", "origin", "main")

            subprocess.run(["git", "clone", bare, installed], check=True, capture_output=True)

            # Up to date initially
            r1 = updater_mod.check_updates(plugin_dir=installed, cache_path=cache)
            self.assertTrue(r1["ok"])
            self.assertTrue(r1["managed"])
            self.assertFalse(r1["available"])
            self.assertEqual(r1["behind"], 0)
            self.assertFalse(r1["cached"])

            # Push two new commits to remote
            for idx in (1, 2):
                with open(os.path.join(work, f"note{idx}.txt"), "w", encoding="utf-8") as f:
                    f.write(f"commit {idx}\n")
                _git(work, "add", f"note{idx}.txt")
                _git(work, "commit", "-m", f"change {idx}")
            _git(work, "push", "origin", "main")

            # Without --force, cache returns previous result
            r_cached = updater_mod.check_updates(plugin_dir=installed, cache_path=cache, force=False)
            self.assertTrue(r_cached["cached"])
            self.assertFalse(r_cached["available"])

            # With --force, detects 2 new commits
            r_live = updater_mod.check_updates(plugin_dir=installed, cache_path=cache, force=True)
            self.assertTrue(r_live["ok"])
            self.assertFalse(r_live["cached"])
            self.assertTrue(r_live["available"])
            self.assertEqual(r_live["behind"], 2)


if __name__ == "__main__":
    unittest.main()
