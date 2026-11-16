#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Replace fractional PDF poster edges without moving paths or adjacent content."""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from PIL import Image, ImageChops, ImageDraw
from reportlab.pdfgen import canvas

from gui_session import PrivateGuiSession


def fixture(directory, scene_size, background):
    width, height = scene_size
    scale = min(300 / width, 180 / height)
    left = 50 + (300 - width * scale) / 2
    top = 60 + (180 - height * scale) / 2
    fitted = (left, top, left + width * scale, top + height * scale)
    pdf = directory / "region.pdf"
    document = canvas.Canvas(str(pdf), pagesize=(400, 300))
    # Green surrounding content touches the poster on every side, making an
    # extra overwritten pixel observable instead of blending into a white page.
    document.setFillColorRGB(0, .5, 0)
    document.rect(0, 0, 400, 300, fill=1, stroke=0)
    document.setFillColorRGB(1, 0, 1)
    document.rect(left, 300 - fitted[3], fitted[2] - left,
                  fitted[3] - top, fill=1, stroke=0)
    document.linkURL("pdfpc-vector:registration", (50, 60, 350, 240), thickness=0)
    document.setPageTransition("Wipe", duration=1, direction=0)
    document.save()
    coords = [width*.4, height*.4, width*.6, height*.4,
              width*.6, height*.6, width*.4, height*.6]
    scene = {"id": "registration", "width": width, "height": height,
             "duration": 1, "background": [*background, 1],
             "checkpoints": [{"time": 0, "label": "Start"}, {"time": 1, "label": "End"}],
             "objects": [{"id": "landmark", "commands": "MLLLZ", "z": 0,
                          "keyframes": [{"time": 0, "coords": coords,
                                         "fill": [1, 0, 0, 1], "stroke": [0, 0, 0, 0],
                                         "stroke_width": 0}]}]}
    # Deliberate off-canvas paths must remain clipped, including when a square
    # scene is fitted inside a wider annotation rectangle.
    for name, points in (
            ("outside-right", [width*1.1, height*.3, width*1.2, height*.3,
                               width*1.2, height*.7, width*1.1, height*.7]),
            ("outside-top", [width*.3, -height*.2, width*.7, -height*.2,
                             width*.7, -height*.1, width*.3, -height*.1])):
        scene["objects"].append({"id": name, "commands": "MLLLZ", "z": 1,
            "keyframes": [{"time": 0, "coords": points, "fill": [0, 0, 1, 1],
                           "stroke": [0, 0, 0, 0], "stroke_width": 0}]})
    timeline = pdf.with_suffix(".vector.json")
    timeline.write_text(json.dumps({"version": 1, "scenes": [scene]}))
    return pdf, timeline, fitted


def pixels(rectangle, size, offset=(0, 0)):
    width, height = size
    scale = min(width / 400, height / 300)
    dx = (width - 400 * scale) / 2 + offset[0]
    dy = (height - 300 * scale) / 2 + offset[1]
    x0, y0, x1, y1 = rectangle
    # Outward physical-pixel coverage of the authored PDF region.
    return (math.floor(x0 * scale + dx + 1e-9), math.floor(y0 * scale + dy + 1e-9),
            math.ceil(x1 * scale + dx - 1e-9), math.ceil(y1 * scale + dy - 1e-9))


def image(path):
    with Image.open(path) as source:
        return source.convert("RGB")


class RegionEdges(unittest.TestCase):
    def test_transparent_scene_backgrounds_remain_rejected(self):
        for alpha in (0, .5):
            with self.subTest(alpha=alpha), tempfile.TemporaryDirectory(dir=OUTPUT) as temporary:
                root = Path(temporary)
                pdf, timeline, _fitted = fixture(root, (100, 60), (1, 1, 1))
                data = json.loads(timeline.read_text())
                data["scenes"][0]["background"][3] = alpha
                timeline.write_text(json.dumps(data))
                result = subprocess.run([TRANSFORM, str(pdf), str(timeline), "none",
                    "798", "598", "none", str(root / "actual"), "2", "0", "0"],
                    capture_output=True, text=True, timeout=20)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("opaque background", result.stderr)

    def assert_region(self, poster, actual, fitted, background, offset=(0, 0)):
        self.assertEqual(actual.size, poster.size)
        bounds = pixels(fitted, actual.size, offset)
        x0, y0, x1, y1 = bounds
        difference = ImageChops.difference(poster, actual)
        ImageDraw.Draw(difference).rectangle((x0, y0, x1-1, y1-1), fill=0)
        self.assertIsNone(difference.getbbox(), "Animation overwrote neighbouring PDF pixels")

        fill = tuple(round(value * 255) for value in background)
        interior = actual.crop(bounds)
        difference = ImageChops.difference(interior, Image.new("RGB", interior.size, fill))
        left, top, right, bottom = fitted
        landmark = (left + (right-left)*.4, top + (bottom-top)*.4,
                    left + (right-left)*.6, top + (bottom-top)*.6)
        rx0, ry0, rx1, ry1 = pixels(landmark, actual.size, offset)
        # Only the independently located red vector landmark is excluded from
        # the background assertion; every region-edge pixel remains checked.
        ImageDraw.Draw(difference).rectangle(
            (rx0-x0-1, ry0-y0-1, rx1-x0, ry1-y0), fill=0)
        self.assertIsNone(difference.getbbox(), "The opaque background retains PDF poster pixels")
        self.assertEqual(actual.getpixel(((rx0+rx1)//2, (ry0+ry1)//2)), (255, 0, 0))
        red = actual.getchannel("R").point(lambda value: 255 if value == 255 else 0)
        green = actual.getchannel("G").point(lambda value: 255 if value == 0 else 0)
        blue = actual.getchannel("B").point(lambda value: 255 if value == 0 else 0)
        painted = ImageChops.multiply(ImageChops.multiply(red, green), blue).getbbox()
        self.assertIsNotNone(painted)
        for found, expected in zip(painted, (rx0, ry0, rx1, ry1)):
            self.assertLessEqual(abs(found-expected), 1, "The vector landmark moved")

    def test_device_scale_offset_and_fitted_scene(self):
        for scene_size in ((100, 60), (100, 100), (200, 60)):
            for scale, offset in ((1, (0, 0)), (2, (0, 0)),
                                  (2, (.25, -.375)), (1.5, (7.25, 5.625)),
                                  (2, (1e-7, -1e-7)), (2, (-1e-7, 1e-7))):
                for background in ((1, 1, 1), (.2, .2, .2)):
                    with self.subTest(scene=scene_size, scale=scale, offset=offset, background=background):
                        with tempfile.TemporaryDirectory(prefix="surface-", dir=OUTPUT) as temporary:
                            root = Path(temporary)
                            pdf, timeline, fitted = fixture(root, scene_size, background)
                            prefix = root / "actual"
                            result = subprocess.run([TRANSFORM, str(pdf), str(timeline), "none",
                                "798", "598", "none", str(prefix), str(scale),
                                str(offset[0]), str(offset[1])], capture_output=True, text=True, timeout=20)
                            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                            self.assert_region(image(str(prefix)+"-pdf.png"),
                                image(str(prefix)+"-vector.png"), fitted, background, offset)

    def test_actual_window_matches_snapshot_at_both_device_scales(self):
        for scale in (1, 2):
            for scene_size in ((100, 60), (100, 100)):
                with self.subTest(scale=scale, scene=scene_size):
                    name = f"scale-{scale}-{scene_size[0]}x{scene_size[1]}"
                    root = OUTPUT / name
                    root.mkdir(exist_ok=True)
                    pdf, _timeline, fitted = fixture(root, scene_size, (1, 1, 1))
                    prefix = root / "actual"
                    environment = {**os.environ, "GDK_SCALE": str(scale), "GDK_DPI_SCALE": "1",
                                   "XDG_CONFIG_HOME": str(root / "config"),
                                   "XDG_CACHE_HOME": str(root / "cache")}
                    for key in ("PDFPC_VECTOR_MANIFEST", "PDFPC_VECTOR_TRACE", "PDFPC_VECTOR_SPEED"):
                        environment.pop(key, None)
                    with PrivateGuiSession(root / "session", environment,
                                           screen="3600x2400x24") as session:
                        result = session.run([WINDOW, str(pdf), "region-edge", str(prefix)])
                    (root / "probe.log").write_text(result.stdout + result.stderr)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    for phase in ("initial", "resized"):
                        poster = image(str(prefix)+f"-{phase}-poster.png")
                        snapshot = image(str(prefix)+f"-{phase}-snapshot.png")
                        window = image(str(prefix)+f"-{phase}-window.png")
                        self.assert_region(poster, snapshot, fitted, (1, 1, 1))
                        self.assert_region(poster, window, fitted, (1, 1, 1))
                        self.assertIsNone(ImageChops.difference(window, snapshot).getbbox(),
                                          "GTK and composed snapshot differ")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transform-probe", type=Path, required=True)
    parser.add_argument("--window-probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    TRANSFORM = str(args.transform_probe.resolve())
    WINDOW = str(args.window_probe.resolve())
    OUTPUT = args.output.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    unittest.main(argv=[__file__, *remaining], verbosity=2)
