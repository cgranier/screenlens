#!/usr/bin/env python3
import importlib.util
import os
import tempfile
import unittest

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("ocr_langs", os.path.join(ROOT_DIR, "scripts/ocr_langs.py"))
ocr_langs_mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(ocr_langs_mod)


class OcrLangsTests(unittest.TestCase):
    def test_parse_tesseract_list_langs_filters_osd(self):
        raw = 'List of available languages in "/usr/share/tessdata/" (3):\neng\nosd\nspa\n'
        self.assertEqual(ocr_langs_mod.parse_tesseract_langs(raw), ["eng", "spa"])

    def test_validate_install_code_allowlist(self):
        entry = ocr_langs_mod.validate_install_code("fra")
        self.assertEqual(entry["pkg"], "tesseract-data-fra")
        for bad in ["", "../etc", "fra;rm -rf /", "--help", "nonexistent"]:
            with self.assertRaises(ValueError):
                ocr_langs_mod.validate_install_code(bad)

    def test_build_status_splits_installed_and_available(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = os.path.join(tmp, "screenlens.json")
            status = ocr_langs_mod.build_status(cfg_path, installed_override=["eng", "spa"])
            self.assertTrue(status["ok"])
            installed_codes = [x["code"] for x in status["installed"]]
            available_codes = [x["code"] for x in status["available"]]
            self.assertEqual(installed_codes, ["eng", "spa"])
            self.assertNotIn("eng", available_codes)
            self.assertNotIn("spa", available_codes)
            self.assertIn("fra", available_codes)


if __name__ == "__main__":
    unittest.main()
