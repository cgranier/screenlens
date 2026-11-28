#!/usr/bin/env python3
import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import unittest

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("config", os.path.join(ROOT_DIR, "scripts/config.py"))
config_mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(config_mod)


class ConfigBackendTests(unittest.TestCase):
    def test_v1_flat_migration_and_redaction(self):
        v1 = {
            "provider": "gemini",
            "model": "gemini-2.5-pro",
            "apiKey": "AIzaSySecretKey1234",
            "maxImageDim": 99999,
        }
        migrated = config_mod.normalize_config(v1)
        self.assertEqual(migrated["schemaVersion"], 2)
        self.assertEqual(migrated["defaultProvider"], "gemini")
        self.assertEqual(migrated["providers"]["gemini"]["apiKey"], "AIzaSySecretKey1234")
        self.assertEqual(migrated["providers"]["gemini"]["model"], "gemini-2.5-pro")
        self.assertEqual(migrated["maxImageDim"], 3840)
        self.assertEqual(config_mod.normalize_config({"defaultMode": "box"})["defaultMode"], "box")
        self.assertEqual(config_mod.normalize_config({"defaultMode": "invalid"})["defaultMode"], "lasso")

        redacted = config_mod.redact_config(migrated)
        self.assertEqual(redacted["providers"]["gemini"]["apiKey"], "")
        self.assertTrue(redacted["providers"]["gemini"]["hasKey"])
        self.assertEqual(redacted["providers"]["gemini"]["maskedKey"], "••••1234")

    def test_save_enforces_0600_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = os.path.join(tmp, "screenlens.json")
            config_mod.save_config(
                {"providers": {"openai": {"apiKey": "sk-test-9876"}}},
                path=cfg_path,
            )
            mode = stat.S_IMODE(os.stat(cfg_path).st_mode)
            self.assertEqual(mode, 0o600)
            loaded = config_mod.load_config(cfg_path)
            self.assertEqual(loaded["providers"]["openai"]["apiKey"], "sk-test-9876")

    def test_keybind_validation_and_managed_block_rewrite(self):
        self.assertEqual(config_mod.normalize_keybind("super + alt + a"), "SUPER + ALT + A")
        self.assertEqual(config_mod.normalize_keybind("super+shift+code:65"), "SUPER + SHIFT + code:65")

        for bad in ["", "SUPER + A\nexec bad", 'SUPER + "A"', "FOO + A", "SUPER + ;rm"]:
            with self.assertRaises(ValueError):
                config_mod.normalize_keybind(bad)

        legacy = (
            '-- User stuff\no.bind("SUPER + R", "Reel", "reel toggle")\n\n'
            '-- ScreenLens: Circle-to-Search style AI screen overlay.\n'
            'o.bind("SUPER + ALT + A", "ScreenLens (AI screen overlay)", { panel = "carlos.screenlens" })\n'
        )
        updated = config_mod.apply_bindings_text(legacy, "SUPER + SHIFT + S", rebind=True)
        self.assertIn(config_mod.BLOCK_BEGIN, updated)
        self.assertIn(config_mod.BLOCK_END, updated)
        self.assertIn('o.rebind("SUPER + SHIFT + S"', updated)
        self.assertEqual(updated.count(config_mod.PLUGIN_ID), 1)
        self.assertNotIn("carlos.screenlens", updated)
        self.assertIn('o.bind("SUPER + R"', updated)

        # Updating again replaces only the managed block in place.
        updated2 = config_mod.apply_bindings_text(updated, "SUPER + ALT + A", rebind=False)
        self.assertEqual(updated2.count(config_mod.BLOCK_BEGIN), 1)
        self.assertEqual(updated2.count(config_mod.PLUGIN_ID), 1)
        self.assertIn('o.bind("SUPER + ALT + A"', updated2)

        # Secondary Voice-to-ScreenLens binding lives cleanly inside the same fenced block.
        updated_voice = config_mod.apply_bindings_text(
            updated2,
            "SUPER + ALT + A",
            rebind=False,
            voice_chord="SUPER + ALT + V",
            voice_rebind=True,
        )
        self.assertEqual(updated_voice.count(config_mod.BLOCK_BEGIN), 1)
        self.assertIn('o.rebind("SUPER + ALT + V"', updated_voice)
        self.assertIn("omarchy-shell shell summon", updated_voice)
        self.assertIn('{\\"voice\\":true}', updated_voice)
        with tempfile.TemporaryDirectory() as tmp:
            bpath = os.path.join(tmp, "bindings.lua")
            with open(bpath, "w", encoding="utf-8") as f:
                f.write(updated_voice)
            self.assertEqual(config_mod.read_keybind_from_bindings(bpath), "SUPER + ALT + A")
            self.assertEqual(config_mod.read_voice_keybind_from_bindings(bpath), "SUPER + ALT + V")

    def test_layer_rule_block_migration_and_idempotence(self):
        legacy = (
            'require("default.hypr.omarchy")\n\n'
            '-- ScreenLens: disable compositor layer fade to match stock Omarchy overlays.\n'
            'hl.layer_rule({ match = { namespace = "carlos-screenlens" }, no_anim = true, animation = "none" })\n'
        )
        updated = config_mod.apply_layer_rule_text(legacy)
        self.assertIn(config_mod.LAYER_BLOCK_BEGIN, updated)
        self.assertIn(config_mod.LAYER_BLOCK_END, updated)
        self.assertIn('namespace = "screenlens"', updated)
        self.assertNotIn("carlos-screenlens", updated)
        self.assertEqual(config_mod.apply_layer_rule_text(updated), updated)

    def test_set_keybind_cli_no_reload(self):
        with tempfile.TemporaryDirectory() as tmp:
            bindings = os.path.join(tmp, "bindings.lua")
            hyprland = os.path.join(tmp, "hyprland.lua")
            cfg = os.path.join(tmp, "screenlens.json")
            with open(bindings, "w", encoding="utf-8") as f:
                f.write('-- keep me\no.bind("SUPER + X", "X", "x")\n')
            with open(hyprland, "w", encoding="utf-8") as f:
                f.write('require("default.hypr.omarchy")\n')

            proc = subprocess.run(
                [
                    "python3",
                    os.path.join(ROOT_DIR, "scripts/config.py"),
                    "--config",
                    cfg,
                    "--bindings",
                    bindings,
                    "--hyprland",
                    hyprland,
                    "set-keybind",
                    "super + alt + l",
                    "--ensure-layer-rule",
                    "--no-reload",
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            res = json.loads(proc.stdout)
            self.assertTrue(res["ok"])
            self.assertEqual(res["keybind"], "SUPER + ALT + L")
            self.assertTrue(os.path.isfile(res["backup"]))
            self.assertEqual(config_mod.read_keybind_from_bindings(bindings), "SUPER + ALT + L")
            self.assertEqual(config_mod.load_config(cfg)["keybind"], "SUPER + ALT + L")
            with open(hyprland, "r", encoding="utf-8") as f:
                hl_text = f.read()
            self.assertIn(config_mod.LAYER_BLOCK_BEGIN, hl_text)
            self.assertIn('namespace = "screenlens"', hl_text)

    def test_quick_chips_normalization_and_defaults(self):
        # Empty / missing quickChips yields the 4 built-in defaults
        cfg = config_mod.normalize_config({})
        self.assertEqual(len(cfg["quickChips"]), 4)
        self.assertEqual([c["id"] for c in cfg["quickChips"]], ["explain", "summarize", "translate", "extract"])
        self.assertIn("{{language}}", cfg["quickChips"][2]["prompt"])
        self.assertEqual(cfg["quickChips"][3]["action"], "extract_text")
        self.assertTrue(cfg["smartActionsEnabled"])

        # Partial custom list pads remaining slots with defaults and sanitizes invalid action/task
        custom = config_mod.normalize_config({
            "smartActionsEnabled": False,
            "quickChips": [
                {
                    "id": "fact!",
                    "label": "  Fact-Check  ",
                    "icon": "󰄬",
                    "action": "invalid_kind",
                    "task": "bogus",
                    "prompt": "Verify claims.",
                },
                {
                    "id": "ocr",
                    "label": "Grab Text",
                    "icon": "󰗧",
                    "action": "extract_text",
                    "task": "vision",
                    "prompt": "should be cleared",
                },
            ],
        })
        self.assertFalse(custom["smartActionsEnabled"])
        self.assertEqual(len(custom["quickChips"]), 4)
        self.assertEqual(custom["quickChips"][0]["id"], "fact")
        self.assertEqual(custom["quickChips"][0]["label"], "Fact-Check")
        self.assertEqual(custom["quickChips"][0]["action"], "prompt")
        self.assertEqual(custom["quickChips"][0]["task"], "auto")
        self.assertEqual(custom["quickChips"][1]["action"], "extract_text")
        self.assertEqual(custom["quickChips"][1]["task"], "text")
        self.assertEqual(custom["quickChips"][1]["prompt"], "")
        self.assertEqual(custom["quickChips"][2]["id"], "translate")
        self.assertEqual(custom["quickChips"][3]["id"], "extract")


if __name__ == "__main__":
    unittest.main()
