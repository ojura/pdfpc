#!/usr/bin/env python3
"""Match independent PDF poster geometry to the production vector binding."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from PIL import Image, ImageChops, ImageStat
from reportlab.pdfgen import canvas


class TransformTests(unittest.TestCase):
    def assert_landmark(self, image, zoom):
        # These screen-space landmarks are independent of the shared renderer
        # implementation. The authored red box is x=72..136, y=68..116 in the
        # cropped 400x300 page. These three 800x600 views exercise both zoom axes.
        expected = {
            ((800, 600), "none"): (144, 136, 272, 232),
            ((800, 600), ".1,.1,.7,.5"): (91.4286, 194.2857, 274.2857, 331.4286),
            ((800, 600), ".1,.1,.5,.7"): (205.7143, 108.5714, 388.5714, 245.7143),
            ((1000, 650), "none"): (222.6667, 147.3333, 361.3333, 251.3333),
            ((650, 1000), "none"): (117, 366.75, 221, 444.75),
        }[(image.size, zoom)]
        red, green, blue = image.split()
        mask = ImageChops.multiply(red.point(lambda v: 255 if v > 240 else 0),
                                  green.point(lambda v: 255 if v < 15 else 0))
        mask = ImageChops.multiply(mask, blue.point(lambda v: 255 if v < 15 else 0))
        actual = mask.getbbox()
        self.assertIsNotNone(actual, "Missing painted landmark")
        for found, required in zip(actual, expected):
            self.assertLessEqual(abs(found - required), 1.5,
                                 f"Painted landmark moved: {actual}, expected {expected}")

    def compare(self, notes, width, height, zoom="none", moved_link=False, common_shift=0):
        with tempfile.TemporaryDirectory(prefix="transform-", dir=OUTPUT) as temporary:
            root = Path(temporary)
            full_width = 800 if notes in ("left", "right") else 400
            full_height = 600 if notes in ("top", "bottom") else 300
            x = 400 if notes == "left" else 0
            y = 300 if notes == "bottom" else 0
            area = [x + 40, y + 40, x + 360, y + 280]
            pdf = root / "poster.pdf"
            document = canvas.Canvas(str(pdf), pagesize=(full_width, full_height))
            document.setFillColorRGB(1, 0, 0)
            document.rect(area[0] + 32, area[3] - 96, 64, 48, fill=1, stroke=0)
            document.setFillColorRGB(0, .5, 0)
            document.circle(area[0] + 224, area[3] - 156, 24, fill=1, stroke=0)
            link = [value + (20 if i % 2 == 0 and moved_link else 0)
                    for i, value in enumerate(area)]
            document.linkURL("pdfpc-vector:registration", link, thickness=0)
            document.save()
            # Four cubic segments describe the circle independently of the PDF.
            k = 24 * .5522847498307936
            circle = [248, 156, 248, 156+k, 224+k, 180, 224, 180,
                      224-k, 180, 200, 156+k, 200, 156,
                      200, 156-k, 224-k, 132, 224, 132,
                      224+k, 132, 248, 156-k, 248, 156]
            scene = {"id": "registration", "width": 320, "height": 240,
                     "duration": 1, "background": [1, 1, 1, 1],
                     "checkpoints": [{"time": 0, "label": "Start"}, {"time": 1, "label": "End"}],
                     "objects": []}
            for name, commands, coords, fill in (
                    ("square", "MLLLZ", [32, 48, 96, 48, 96, 96, 32, 96], [1, 0, 0, 1]),
                    ("circle", "MCCCCZ", circle, [0, .5, 0, 1])):
                scene["objects"].append({"id": name, "commands": commands, "z": 0,
                    "keyframes": [{"time": 0, "coords": coords, "fill": fill,
                                   "stroke": [0, 0, 0, 0], "stroke_width": 0}]})
            timeline = root / "poster.vector.json"
            timeline.write_text(json.dumps({"version": 1, "scenes": [scene]}))
            prefix = root / "actual"
            result = subprocess.run([PROBE, str(pdf), str(timeline), notes,
                                     str(width), str(height), zoom, str(prefix)],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with Image.open(str(prefix) + "-pdf.png") as image:
                poster = image.convert("RGB")
            with Image.open(str(prefix) + "-vector.png") as image:
                vector = image.convert("RGB")
            if common_shift:
                poster = ImageChops.offset(poster, common_shift, common_shift)
                vector = ImageChops.offset(vector, common_shift, common_shift)
            self.assertIsNotNone(ImageChops.difference(poster, Image.new("RGB", poster.size, "white")).getbbox())
            if (width, height) == (800, 600) or zoom == "none":
                self.assert_landmark(poster, zoom)
                if not moved_link:
                    self.assert_landmark(vector, zoom)
            difference = ImageStat.Stat(ImageChops.difference(poster, vector))
            return sum(difference.mean) / 3

    def test_page_crop_zoom_and_viewport_alignment(self):
        for notes in ("none", "left", "right", "top", "bottom"):
            for size in ((800, 600), (1000, 650), (650, 1000)):
                for zoom in ("none", ".1,.1,.7,.5", ".1,.1,.5,.7"):
                    with self.subTest(notes=notes, size=size, zoom=zoom):
                        self.assertLess(self.compare(notes, *size, zoom), .15)

    def test_displaced_annotation_is_detected(self):
        self.assertGreater(self.compare("left", 800, 600, moved_link=True), 1)

    def test_common_translation_is_detected_even_when_renderers_agree(self):
        with self.assertRaisesRegex(AssertionError, "Painted landmark moved"):
            self.compare("top", 800, 600, common_shift=12)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("probe")
    parser.add_argument("--output", type=Path, required=True)
    args, rest = parser.parse_known_args()
    PROBE = str(Path(args.probe).resolve())
    OUTPUT = args.output.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    unittest.main(argv=[__file__, *rest])
