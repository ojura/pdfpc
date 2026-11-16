#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check an actual staged native install, including the installed runnable example."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest


class InstalledDocumentation(unittest.TestCase):
    def test_installed_license_guide_and_example_match_source(self):
        for source, installed in (
                (SOURCE / "LICENSE.txt", DOCDIR / "LICENSE.txt"),
                (SOURCE / "VECTOR_ANIMATIONS.md", DOCDIR / "VECTOR_ANIMATIONS.md"),
                *((SOURCE / "demo" / name, DOCDIR / "examples" / name) for name in
                  ("vector_animation.py", "vector-animation.pdf", "vector-animation.vector.json"))):
            with self.subTest(installed=str(installed)):
                self.assertTrue(installed.is_file(), "Missing installed file: " + str(installed))
                self.assertEqual(installed.read_bytes(), source.read_bytes())

    def test_installed_manuals_format_and_describe_vector_controls(self):
        for name, section, required in (
                ("pdfpc", "1", ("Vector animations", "pdfpc-vector:", "PDFPC_VECTOR_MANIFEST")),
                ("pdfpcrc", "5", ("vectorToggle", "PDFPC_CONFIG_DIR", "PDFPC_DATA_DIR"))):
            with self.subTest(manual=name):
                manual = MANDIR / ("man" + section) / (name + "." + section)
                self.assertTrue(manual.is_file())
                self.assertIsNone(re.search(r"@[A-Z_]+@", manual.read_text()),
                                  "An unexpanded CMake variable remains in the installed manual")
                result = subprocess.run(["groff", "-ww", "-Tutf8", "-man", str(manual)],
                                        env=dict(os.environ, GROFF_NO_SGR="1"),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "", "groff reported a manual formatting error")
                text = re.sub(r".\x08", "", result.stdout)
                for term in required:
                    self.assertIn(term, text)
                (OUTPUT / (name + ".txt")).write_text(text)

    def test_installed_example_runs_its_source_and_native_poster_checks(self):
        result = subprocess.run([
            sys.executable, "-B", str(SOURCE / "tests/vector/test_example.py"), PROBE,
            "--example-dir", str(DOCDIR / "examples"),
            "--output", str(OUTPUT / "example"), "-v"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe")
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--docdir", type=Path, default=Path("share/doc/pdfpc"))
    parser.add_argument("--mandir", type=Path, default=Path("share/man"))
    parser.add_argument("--output", type=Path, required=True)
    options, remaining = parser.parse_known_args()
    SOURCE = Path(__file__).resolve().parents[2]
    PROBE = str(Path(options.probe).resolve())
    DOCDIR = options.prefix.resolve() / options.docdir
    MANDIR = options.prefix.resolve() / options.mandir
    OUTPUT = options.output.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    unittest.main(argv=[__file__, *remaining])
