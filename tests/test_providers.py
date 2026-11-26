#!/usr/bin/env python3
import importlib.util
import json
import os
import unittest
from unittest import mock

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("providers", os.path.join(ROOT_DIR, "scripts/providers.py"))
providers_mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(providers_mod)


class ProviderToolsTests(unittest.TestCase):
    def test_key_url_allowlist(self):
        self.assertTrue(providers_mod.get_key_url("gemini").startswith("https://aistudio.google.com/"))
        self.assertTrue(providers_mod.get_key_url("anthropic").startswith("https://console.anthropic.com/"))
        self.assertTrue(providers_mod.get_key_url("openai").startswith("https://platform.openai.com/"))
        self.assertTrue(providers_mod.get_key_url("ollama").startswith("https://ollama.com/"))
        with self.assertRaises(ValueError):
            providers_mod.get_key_url("agent")
        with self.assertRaises(ValueError):
            providers_mod.get_key_url("unknown")

    def test_curated_and_live_model_discovery(self):
        cfg = {"providers": {"gemini": {"apiKey": "", "model": "gemini-2.5-flash"}}}
        res = providers_mod.discover_models("gemini", cfg, live=True, env={})
        self.assertTrue(res["ok"])
        self.assertEqual(res["source"], "curated")
        self.assertIn("gemini-2.5-flash", res["models"])

        with mock.patch.object(
            providers_mod,
            "fetch_json",
            return_value={
                "models": [
                    {"name": "models/gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"]},
                    {"name": "models/gemini-3.0-preview", "supportedGenerationMethods": ["generateContent"]},
                    {"name": "models/embedding-001", "supportedGenerationMethods": ["embedContent"]},
                ]
            },
        ):
            live_res = providers_mod.discover_models("gemini", cfg, live=True, env={"GEMINI_API_KEY": "test-key"})
            self.assertEqual(live_res["source"], "live")
            self.assertIn("gemini-3.0-preview", live_res["models"])
            self.assertNotIn("embedding-001", live_res["models"])

    def test_ollama_discovery_and_host_guard(self):
        with mock.patch.object(
            providers_mod,
            "fetch_json",
            return_value={"models": [{"name": "qwen2.5vl:7b"}, {"name": "llava:latest"}]},
        ):
            res = providers_mod.discover_models(
                "ollama",
                {"providers": {"ollama": {"host": "http://127.0.0.1:11434"}}},
                live=True,
            )
            self.assertTrue(res["ok"])
            self.assertEqual(res["source"], "live")
            self.assertEqual(res["models"][0], "qwen2.5vl:7b")

        bad_test = providers_mod.test_provider(
            "ollama",
            {"providers": {"ollama": {"host": "http://evil.example.com:11434"}}},
        )
        self.assertFalse(bad_test["ok"])
        self.assertIn("localhost", bad_test["error"])

    def test_provider_connection_test(self):
        missing = providers_mod.test_provider("openai", {"providers": {"openai": {"apiKey": ""}}}, env={})
        self.assertFalse(missing["ok"])
        self.assertIn("Missing API key", missing["error"])

        with mock.patch.object(providers_mod, "fetch_json", return_value={"id": "gpt-4.1-mini"}):
            ok_res = providers_mod.test_provider(
                "openai",
                {"providers": {"openai": {"apiKey": "sk-test", "model": "gpt-4.1-mini"}}},
                env={},
            )
            self.assertTrue(ok_res["ok"])
            self.assertEqual(ok_res["detail"], "Connected")
            self.assertIsInstance(ok_res["latencyMs"], int)


if __name__ == "__main__":
    unittest.main()
