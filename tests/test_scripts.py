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

    def test_sse_and_ndjson_parsers(self):
        gem_line = 'data: {"candidates":[{"content":{"parts":[{"text":"Hello "},{"text":"world"}]}}]}'
        self.assertEqual(ask_mod.parse_gemini_sse_line(gem_line), "Hello world")

        ant_line = 'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi!"}}'
        self.assertEqual(ask_mod.parse_anthropic_sse_line(ant_line), "Hi!")

        oai_line = 'data: {"choices":[{"delta":{"content":"Streamed"}}]}'
        self.assertEqual(ask_mod.parse_openai_sse_line(oai_line), "Streamed")

        oll_line = '{"message":{"role":"assistant","content":"Local"}}'
        self.assertEqual(ask_mod.parse_ollama_ndjson_line(oll_line), "Local")

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

        prompt = actions_mod.build_single_line_handoff_prompt(
            "/tmp/ctx.md", "/tmp/crop.png", "/tmp/full.png", "line1\nline2\r\nline3"
        )
        self.assertNotIn("\n", prompt)
        self.assertNotIn("\r", prompt)
        self.assertIn("/tmp/ctx.md", prompt)
        self.assertIn("/tmp/crop.png", prompt)

    def test_qml_ui_safety_and_motion_conventions(self):
        with open(os.path.join(ROOT_DIR, "ScreenLens.qml"), "r", encoding="utf-8") as f:
            qml = f.read()
        # No raw Text elements allowed in ScreenLens.qml — must use PlainText wrapper.
        raw_text_matches = re.findall(r"(?<![A-Za-z0-9_])Text\s*\{", qml)
        self.assertEqual(raw_text_matches, [], f"Found raw Text blocks: {raw_text_matches}")
        # Every NumberAnimation duration must go through Style.duration(...)
        bare_durations = re.findall(r"duration\s*:\s*[0-9]+", qml)
        self.assertEqual(bare_durations, [], f"Found bare numeric durations: {bare_durations}")


if __name__ == "__main__":
    unittest.main()
