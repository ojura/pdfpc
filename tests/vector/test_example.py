#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate the distributed example, its source, PDF binding and actual poster."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from PIL import Image, ImageChops, ImageStat
from pypdf import PdfReader


class ExampleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="example-", dir=OUTPUT)
        cls.directory = Path(cls.temporary.name)
        spec = importlib.util.spec_from_file_location("vector_example", EXAMPLE / "vector_animation.py")
        cls.example = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.example)
        cls.generated_pdf, cls.generated_json = cls.example.write_example(cls.directory)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_distributed_timeline_matches_its_source_and_loads_in_pdfpc(self):
        expected = self.example.timeline()
        self.assertEqual(json.loads(self.generated_json.read_text()), expected)
        published = EXAMPLE / "vector-animation.vector.json"
        self.assertEqual(json.loads(published.read_text()), expected)
        subprocess.run([PROBE, "validate", str(published)], check=True,
                       capture_output=True, text=True)

    def test_pdf_region_targets_the_scene_and_preserves_vector_poster(self):
        for pdf in (EXAMPLE / "vector-animation.pdf", self.generated_pdf):
            with self.subTest(pdf=str(pdf)):
                document = PdfReader(pdf)
                self.assertEqual(len(document.pages), 1)
                page = document.pages[0]
                self.assertEqual(tuple(map(float, page.mediabox[2:])), self.example.PAGE_SIZE)
                annotations = [item.get_object() for item in page["/Annots"]]
                self.assertEqual(len(annotations), 1)
                self.assertEqual(annotations[0]["/Subtype"], "/Link")
                self.assertEqual(annotations[0]["/A"]["/S"], "/URI")
                self.assertEqual(annotations[0]["/A"]["/URI"],
                                 "pdfpc-vector:" + self.example.timeline()["scenes"][0]["id"])
                self.assertEqual(tuple(map(float, annotations[0]["/Rect"])), self.example.REGION)
                self.assertEqual(len(page.images), 0)
                self.assertIn("Hold, move, fade", page.extract_text())
                self.assertIn("Ctrl+Left / Ctrl+Right", page.extract_text())

    def test_rendered_poster_matches_the_native_initial_state(self):
        left, bottom, right, top = self.example.REGION
        width, height = right - left, top - bottom
        target = self.directory / "native.png"
        subprocess.run([PROBE, "render", str(self.generated_json), "moving-square", "0",
                        str(target), str(width), str(height)], check=True,
                       capture_output=True, text=True)
        with Image.open(target) as native_file:
            native = native_file.convert("RGB")
        for index, pdf in enumerate((EXAMPLE / "vector-animation.pdf", self.generated_pdf)):
            with self.subTest(pdf=str(pdf)):
                output = self.directory / ("poster-" + str(index))
                subprocess.run(["pdftoppm", "-singlefile", "-r", "72", "-png",
                                str(pdf), str(output)], check=True,
                               capture_output=True, text=True)
                with Image.open(output.with_suffix(".png")) as page:
                    self.assertEqual(page.size, self.example.PAGE_SIZE)
                    poster = page.convert("RGB").crop((left, page.height - top,
                                                        right, page.height - bottom))
                self.assertEqual(poster.size, native.size)
                self.assertEqual(poster.getpixel((108, 162)), (255, 0, 0))
                self.assertEqual(poster.getpixel((270, 162)), (255, 255, 255))
                difference = ImageStat.Stat(ImageChops.difference(poster, native))
                self.assertLess(max(difference.mean), .5,
                                "The PDF poster differs from the native initial state")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe")
    parser.add_argument("--example-dir", type=Path,
                        default=Path(__file__).resolve().parents[2] / "demo")
    parser.add_argument("--output", type=Path, required=True)
    options, remaining = parser.parse_known_args()
    PROBE = str(Path(options.probe).resolve())
    EXAMPLE = options.example_dir.resolve()
    OUTPUT = options.output.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    unittest.main(argv=[__file__, *remaining])
