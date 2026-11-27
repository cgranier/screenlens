#!/usr/bin/env python3
import importlib.util
import json
import os
import re
import subprocess
import tempfile
import unittest

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_module(name: str, rel_path: str):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT_DIR, rel_path))
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


capture_mod = load_module("capture", "scripts/capture.py")
ocr_mod = load_module("ocr", "scripts/ocr.py")
ask_mod = load_module("ask", "scripts/ask.py")
voice_mod = load_module("voice", "scripts/voice.py")
actions_mod = load_module("actions", "scripts/actions.py")


class ScreenLensTests(unittest.TestCase):
    def test_ocr_tsv_parsing_filters_noise(self):
        tsv = "\n".join(
            [
                "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext",
                "4\t1\t1\t1\t1\t0\t10\t10\t200\t40\t-1\t",
                "5\t1\t1\t1\t1\t1\t12\t14\t80\t28\t95.4\tHello",
                "5\t1\t1\t1\t1\t2\t100\t14\t90\t28\t5.0\tNoise",
                "5\t1\t1\t1\t1\t3\t200\t14\t110\t28\t88.1\t<script>",
            ]
        )
        words = ocr_mod.parse_tsv(tsv)
        self.assertEqual([w["text"] for w in words], ["Hello", "<script>"])
        self.assertEqual(words[0]["x"], 12)
        self.assertEqual(words[0]["h"], 28)

    def test_synthetic_png_dimensions_crop_and_ocr(self):
        with tempfile.TemporaryDirectory() as tmp:
            img_path = os.path.join(tmp, "sample.png")
            subprocess.run(
                [
                    "magick",
                    "-size",
                    "600x200",
                    "xc:white",
                    "-fill",
                    "black",
                    "-pointsize",
                    "42",
                    "-gravity",
                    "center",
                    "-annotate",
                    "+0+0",
                    "OMARCHY LENS",
                    img_path,
                ],
                check=True,
                capture_output=True,
            )

            # Verify PNG header reader
            self.assertEqual(capture_mod.read_png_dimensions(img_path), (600, 200))

            # Verify real OCR word-box extraction
            proc = subprocess.run(
                ["python3", os.path.join(ROOT_DIR, "scripts/ocr.py"), img_path],
                capture_output=True,
                text=True,
                check=True,
            )
            data = json.loads(proc.stdout)
            self.assertTrue(data["ok"])
            joined = " ".join(w["text"] for w in data["words"]).upper()
            self.assertIn("OMARCHY", joined)

            # Verify ask.py image crop preparation
            cropped_bytes, mime, saved = ask_mod.prepare_image(
                img_path, {"x": 50, "y": 20, "w": 400, "h": 140}
            )
            try:
                self.assertEqual(mime, "image/png")
                self.assertGreater(len(cropped_bytes), 100)
                self.assertEqual(capture_mod.read_png_dimensions(saved), (400, 140))
            finally:
                if saved and saved != img_path and os.path.exists(saved):
                    os.unlink(saved)

    def test_provider_resolution_and_security_guards(self):
        self.assertEqual(ask_mod.resolve_provider({}, env={})["provider"], "agent")
        self.assertEqual(
            ask_mod.resolve_provider({}, env={"GEMINI_API_KEY": "k"})["provider"],
            "gemini",
        )
        self.assertEqual(
            ask_mod.resolve_provider({}, env={"ANTHROPIC_API_KEY": "k"})["provider"],
            "anthropic",
        )
        self.assertEqual(
            ask_mod.resolve_provider({}, env={"OPENAI_API_KEY": "k"})["provider"],
            "openai",
        )
        self.assertEqual(
            ask_mod.resolve_provider({"provider": "ollama"}, env={})["host"],
            "http://127.0.0.1:11434",
        )
        with self.assertRaises(ValueError):
            ask_mod.validate_ollama_host("http://evil.example.com:11434")

    def test_task_routing_and_handoff_agent_override(self):
        cfg = {
            "defaultProvider": "anthropic",
            "providers": {
                "anthropic": {"apiKey": "ant-key", "model": "claude-haiku-4-5-20251001"},
                "gemini": {"apiKey": "gem-key", "model": "gemini-2.5-flash"},
                "openai": {"apiKey": "oai-key", "model": "gpt-4.1-mini"},
            },
            "taskRouting": {
                "enabled": True,
                "translate": {"provider": "gemini", "model": "gemini-2.5-flash-lite"},
                "vision": {"provider": "openai", "model": ""},
                "general": {"provider": "", "model": ""},
                "handoffAgent": "codex",
            },
        }
        tr = ask_mod.resolve_provider(cfg, env={}, task="translate")
        self.assertEqual(tr["provider"], "gemini")
        self.assertEqual(tr["model"], "gemini-2.5-flash-lite")

        vis = ask_mod.resolve_provider(cfg, env={}, task="vision")
        self.assertEqual(vis["provider"], "openai")
        self.assertEqual(vis["model"], "gpt-4.1-mini")

        gen = ask_mod.resolve_provider(cfg, env={}, task="general")
        self.assertEqual(gen["provider"], "anthropic")

        # When disabled, taskRouting is ignored.
        cfg_off = dict(cfg, taskRouting=dict(cfg["taskRouting"], enabled=False))
        self.assertEqual(ask_mod.resolve_provider(cfg_off, env={}, task="translate")["provider"], "anthropic")

        # Explicit handoff CLI command construction.
        default_cmd = actions_mod.build_handoff_launch_cmd("hello", "default")
        self.assertTrue(default_cmd[0].endswith("omarchy-agent-prompt"))
        codex_cmd = actions_mod.build_handoff_launch_cmd("hello", "codex")
        self.assertIn("codex", codex_cmd)
        self.assertIn("--approve-for-me", codex_cmd)

    def test_sse_and_ndjson_parsers(self):
        gem_line = 'data: {"candidates":[{"content":{"parts":[{"text":"Hello "},{"text":"world"}]}}]}'
        self.assertEqual(ask_mod.parse_gemini_sse_line(gem_line), "Hello world")

        ant_line = 'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi!"}}'
        self.assertEqual(ask_mod.parse_anthropic_sse_line(ant_line), "Hi!")

        oai_line = 'data: {"choices":[{"delta":{"content":"Streamed"}}]}'
        self.assertEqual(ask_mod.parse_openai_sse_line(oai_line), "Streamed")

        oll_line = '{"message":{"role":"assistant","content":"Local"}}'
        self.assertEqual(ask_mod.parse_ollama_ndjson_line(oll_line), "Local")

        oai_resp_line = 'data: {"type":"response.output_text.delta","delta":"Grounded"}'
        self.assertEqual(ask_mod.parse_openai_responses_sse_line(oai_resp_line), "Grounded")
        self.assertEqual(
            ask_mod.parse_openai_responses_sse_line('data: {"type":"response.web_search_call.in_progress"}'),
            "",
        )

    def test_web_search_grounding_payloads_and_cli_flags(self):
        gem_off = ask_mod.build_gemini_payload("what is this?", "", "", [], web_search=False)
        self.assertNotIn("tools", gem_off)
        gem_on = ask_mod.build_gemini_payload("latest price?", "", "", [], web_search=True)
        self.assertEqual(gem_on["tools"], [{"google_search": {}}])

        ant_off = ask_mod.build_anthropic_payload("claude-haiku-4-5-20251001", "hi", "", "", [], web_search=False)
        self.assertNotIn("tools", ant_off)
        ant_on = ask_mod.build_anthropic_payload("claude-haiku-4-5-20251001", "news?", "", "", [], web_search=True)
        self.assertEqual(ant_on["tools"][0]["type"], "web_search_20250305")
        self.assertEqual(ant_on["tools"][0]["name"], "web_search")

        oai_resp = ask_mod.build_openai_responses_payload(
            "gpt-4.1-mini",
            "check live weather",
            "YWJj",
            "image/png",
            [{"role": "user", "text": "prev"}, {"role": "assistant", "text": "ans"}],
            web_search=True,
        )
        self.assertEqual(oai_resp["tools"], [{"type": "web_search_preview"}])
        self.assertEqual(oai_resp["input"][0]["content"][1]["type"], "input_image")
        self.assertEqual(oai_resp["input"][1]["content"][0]["type"], "output_text")

        claude_off = ask_mod.build_agent_cli_command("claude", "describe", web_search=False)
        self.assertIn("Read", claude_off)
        self.assertNotIn("Read,WebSearch,WebFetch", claude_off)
        claude_on = ask_mod.build_agent_cli_command("claude", "describe", web_search=True)
        self.assertIn("Read,WebSearch,WebFetch", claude_on)

        grok_off = ask_mod.build_agent_cli_command("grok", "describe", web_search=False)
        self.assertIn("--disable-web-search", grok_off)
        grok_on = ask_mod.build_agent_cli_command("grok", "describe", web_search=True)
        self.assertNotIn("--disable-web-search", grok_on)
        self.assertIn("Read,WebSearch,WebFetch", grok_on)

    def test_voice_payload_extraction(self):
        sample = {"lastDictation": {"timestamp": "2026-11-25T20:00:00Z", "text": "Explain this chart"}}
        self.assertEqual(voice_mod.extract_text(sample), "Explain this chart")
        self.assertEqual(voice_mod.extract_signature(sample), "timestamp:2026-11-25T20:00:00Z")

    def test_claude_stream_json_and_single_line_handoff(self):
        delta_line = json.dumps(
            {
                "type": "stream_event",
                "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Chunk"}},
            }
        )
        self.assertEqual(ask_mod.parse_claude_stream_json_line(delta_line), ("Chunk", ""))
        result_line = json.dumps({"type": "result", "result": "Full answer"})
        self.assertEqual(ask_mod.parse_claude_stream_json_line(result_line), ("", "Full answer"))

        cmd = ask_mod.build_agent_cli_command("claude", "describe")
        self.assertIn("--add-dir", cmd)
        self.assertIn("--allowedTools", cmd)
        self.assertIn("stream-json", cmd)
        self.assertIn("haiku", cmd)
        self.assertIn("--strict-mcp-config", cmd)

        # Verify tuned headless commands and streaming parsers for agy, codex, opencode, grok
        agy_cmd = ask_mod.build_agent_cli_command("agy", "describe", model="gemini-3-flash")
        self.assertIn("--add-dir", agy_cmd)
        self.assertIn("/tmp", agy_cmd)
        self.assertIn("stream-json", agy_cmd)
        self.assertIn("gemini-3-flash", agy_cmd)
        self.assertEqual(
            ask_mod.parse_agy_stream_json_line(
                json.dumps({"event": "step_update", "step_update": {"step_type": "agent_response", "text_delta": "Hi"}})
            ),
            ("Hi", "", ""),
        )
        self.assertEqual(
            ask_mod.parse_agy_stream_json_line(json.dumps({"event": "result", "result": {"response": "Full"}})),
            ("", "Full", ""),
        )

        codex_cmd = ask_mod.build_agent_cli_command("codex", "describe", model="gpt-5", image_path="/tmp/shot.png")
        self.assertIn("--skip-git-repo-check", codex_cmd)
        self.assertIn("--ephemeral", codex_cmd)
        self.assertIn("-i", codex_cmd)
        self.assertIn("/tmp/shot.png", codex_cmd)
        self.assertIn("--", codex_cmd)
        self.assertEqual(
            ask_mod.parse_codex_jsonl_line(
                json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "Answer"}})
            ),
            ("Answer", "", ""),
        )
        self.assertEqual(
            ask_mod.parse_codex_jsonl_line(json.dumps({"type": "error", "message": "401 Unauthorized"})),
            ("", "", "401 Unauthorized"),
        )

        oc_cmd = ask_mod.build_agent_cli_command("opencode", "describe", image_path="/tmp/shot.png")
        self.assertIn("--archived", oc_cmd)
        self.assertIn("-f", oc_cmd)
        self.assertIn("/tmp/shot.png", oc_cmd)
        self.assertEqual(
            ask_mod.parse_opencode_jsonl_line(json.dumps({"type": "text", "part": {"type": "text", "text": "Reply"}})),
            ("Reply", "", ""),
        )

        grok_cmd = ask_mod.build_agent_cli_command("grok", "describe")
        self.assertIn("--add-dir", grok_cmd)
        self.assertIn("--no-memory", grok_cmd)
        self.assertIn("plain", grok_cmd)

        prompt = actions_mod.build_single_line_handoff_prompt(
            "/tmp/ctx.md", "/tmp/crop.png", "/tmp/full.png", "line1\nline2\r\nline3"
        )
        self.assertNotIn("\n", prompt)
        self.assertNotIn("\r", prompt)
        self.assertIn("/tmp/ctx.md", prompt)
        self.assertIn("/tmp/crop.png", prompt)

        import base64
        b64_payload = base64.b64encode(
            json.dumps({"prompt": "Context\nLine 2", "imagePath": "", "crop": None, "draftPrompt": "Help"}).encode("utf-8")
        ).decode("ascii")
        prepared = actions_mod.prepare_handoff("-", b64_value=b64_payload)
        try:
            self.assertTrue(prepared["ok"])
            self.assertTrue(os.path.isfile(prepared["contextPath"]))
            self.assertNotIn("\n", prepared["prompt"])
        finally:
            if os.path.exists(prepared["contextPath"]):
                os.unlink(prepared["contextPath"])

        # Verify handoff-direct with UTF-8 Spanish window title and conversation history
        proc = subprocess.run(
            [
                "python3",
                os.path.join(ROOT_DIR, "scripts/actions.py"),
                "handoff-direct",
                "--window-class",
                "chromium",
                "--window-title",
                "Recreación visual — EL PAÍS",
                "--selected-text",
                "cinco toneladas",
                "--draft",
                "Explain\nthis",
                "--messages-json",
                json.dumps([{"role": "user", "text": "Translate"}]),
                "--dry-run",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        direct = json.loads(proc.stdout)
        try:
            self.assertTrue(direct["ok"])
            self.assertNotIn("\n", direct["prompt"])
            self.assertTrue(os.path.isfile(direct["contextPath"]))
            with open(direct["contextPath"], "r", encoding="utf-8") as f:
                md = f.read()
            self.assertIn("Recreación visual — EL PAÍS", md)
            self.assertIn("cinco toneladas", md)
        finally:
            if os.path.exists(direct["contextPath"]):
                os.unlink(direct["contextPath"])

    def test_qml_ui_safety_and_motion_conventions(self):
        qml_files = []
        for dirpath, dirnames, filenames in os.walk(ROOT_DIR):
            dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__")]
            for fname in sorted(filenames):
                if fname.endswith(".qml") and fname != "PlainText.qml":
                    qml_files.append(os.path.relpath(os.path.join(dirpath, fname), ROOT_DIR))
        self.assertGreaterEqual(len(qml_files), 10, f"Expected modular QML files, found {qml_files}")
        for rel in qml_files:
            with open(os.path.join(ROOT_DIR, rel), "r", encoding="utf-8") as f:
                qml = f.read()
            # No raw Text elements allowed — must use PlainText wrapper.
            raw_text_matches = re.findall(r"(?<![A-Za-z0-9_])Text\s*\{", qml)
            self.assertEqual(raw_text_matches, [], f"{rel}: Found raw Text blocks: {raw_text_matches}")
            # Every NumberAnimation duration must go through Style.duration(...)
            bare_durations = re.findall(r"duration\s*:\s*[0-9]+", qml)
            self.assertEqual(bare_durations, [], f"{rel}: Found bare numeric durations: {bare_durations}")
            # Avoid QML Canvas FBO black-screen regressions across Wayland surface remaps.
            self.assertIsNone(re.search(r"(?<![A-Za-z0-9_])Canvas\s*\{", qml), f"{rel}: Found Canvas block")


if __name__ == "__main__":
    unittest.main()
