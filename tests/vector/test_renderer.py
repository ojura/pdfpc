#!/usr/bin/env python3
"""Verify native interpolation, glyph holes, vector export and invalid input handling."""

import argparse
import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from PIL import Image
from pypdf import PdfReader


def fixture():
    def key(time, coords=None, opacity=1):
        state = {"time": time, "fill": [1, 0, 0, opacity],
                 "stroke": [0, 0, 0, 0], "stroke_width": 0}
        if coords is not None:
            state["coords"] = coords
        return state
    start = [10, 20, 30, 20, 30, 40, 10, 40]
    end = [70, 20, 90, 20, 90, 40, 70, 40]
    return {"version": 1, "scenes": [{"id": "rotation", "width": 100, "height": 60,
        "duration": 3, "background": [1, 1, 1, 1],
        "checkpoints": [{"time": 0, "label": "Initial"}, {"time": 1, "label": "Held"},
                        {"time": 2, "label": "Moved"}, {"time": 3, "label": "Faded"}],
        "objects": [{"id": "square", "z": 0, "commands": "MLLLZ", "fill_rule": "nonzero",
            "keyframes": [key(0, start), key(1), key(2, end), key(3, opacity=0.5)]}]}]}


class RendererTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="vector-renderer-", dir=OUTPUT)
        cls.directory = Path(cls.temporary.name)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def write(self, data, name="fixture.json"):
        filename = self.directory / name
        filename.write_text(json.dumps(data), encoding="utf-8")
        return filename

    def invoke(self, *args, check=True):
        result = subprocess.run([PROBE, *map(str, args)], capture_output=True, text=True,
                                env={**__import__("os").environ, "G_DEBUG": "fatal-criticals"})
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def render(self, time, data=None, width=100, height=60):
        source = self.write(fixture() if data is None else data)
        image = self.directory / "state.png"
        self.invoke("render", source, "rotation", time, image, width, height)
        return Image.open(image).convert("RGB")

    def test_sparse_geometry_and_hold(self):
        image = self.render(0.75)
        self.assertEqual(image.getpixel((20, 30)), (255, 0, 0))
        self.assertEqual(image.getpixel((50, 30)), (255, 255, 255))

    def test_arbitrary_time_interpolation(self):
        image = self.render(1.375)
        self.assertEqual(image.getpixel((40, 30)), (255, 0, 0))
        self.assertEqual(image.getpixel((20, 30)), (255, 255, 255))
        self.assertEqual(image.getpixel((70, 30)), (255, 255, 255))

    def test_opacity_uses_shared_geometry(self):
        image = self.render(2.5)
        self.assertEqual(image.getpixel((80, 30)), (255, 64, 64))

    def test_resolution_independent_geometry(self):
        image = self.render(1.5, width=1000, height=600)
        self.assertEqual(image.getpixel((500, 300)), (255, 0, 0))
        self.assertEqual(image.getpixel((300, 300)), (255, 255, 255))

    def test_multiple_subpaths_and_hole(self):
        data = fixture()
        path = data["scenes"][0]["objects"][0]
        path["commands"] = "MLLLZMLLLZ"
        path["fill_rule"] = "evenodd"
        path["keyframes"] = [{"time": 0, "coords": [10, 10, 90, 10, 90, 50, 10, 50,
            40, 20, 60, 20, 60, 40, 40, 40], "fill": [1, 0, 0, 1],
            "stroke": [0, 0, 0, 0], "stroke_width": 0}]
        image = self.render(0, data)
        self.assertEqual(image.getpixel((20, 30)), (255, 0, 0))
        self.assertEqual(image.getpixel((50, 30)), (255, 255, 255))

    def test_pdf_output_contains_vectors(self):
        source = self.write(fixture())
        destination = self.directory / "state.pdf"
        self.invoke("render", source, "rotation", 1.5, destination, 100, 60)
        page = PdfReader(destination).pages[0]
        self.assertEqual(len(page.images), 0)
        operators = {operator for _, operator in page.get_contents().operations}
        self.assertTrue(operators.intersection({b"m", b"re"}))
        self.assertIn(b"f", operators)

    def test_empty_inputs_fail_without_glib_criticals(self):
        for index, contents in enumerate(("", " \t\r\n")):
            with self.subTest(contents=repr(contents)):
                source = self.directory / f"empty-{index}.json"
                source.write_text(contents, encoding="utf-8")
                result = self.invoke("validate", source, check=False)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("CRITICAL", result.stderr)

    def test_invalid_inputs_fail_without_glib_criticals(self):
        cases = []
        for mutate in (
            lambda d: d.update(version=2),
            lambda d: d["scenes"][0].update(width={}),
            lambda d: d["scenes"][0].update(background=[1, 1, 1, 0]),
            lambda d: d["scenes"][0]["checkpoints"][-1].update(time=2),
            lambda d: d["scenes"][0]["objects"][0].update(commands="MA"),
            lambda d: d["scenes"][0]["objects"][0]["keyframes"][0].pop("coords"),
            lambda d: d["scenes"][0]["objects"][0]["keyframes"][0].update(coords=[1, 2]),
            lambda d: d["scenes"][0]["objects"][0]["keyframes"][1].update(time=0),
            lambda d: d["scenes"][0]["objects"][0]["keyframes"][1].update(fill=[2, 0, 0, 1]),
        ):
            value = copy.deepcopy(fixture())
            mutate(value)
            cases.append(value)
        for index, data in enumerate(cases):
            with self.subTest(index=index):
                result = self.invoke("validate", self.write(data, f"invalid-{index}.json"), check=False)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("CRITICAL", result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("probe")
    parser.add_argument("--output", type=Path, required=True)
    options, remaining = parser.parse_known_args()
    PROBE = str(Path(options.probe).resolve())
    OUTPUT = options.output.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    unittest.main(argv=[__file__, *remaining])
