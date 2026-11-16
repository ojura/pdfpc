#!/usr/bin/env python3
"""Exercise actual PDF wipes, composed vector states and audience readiness."""
import argparse
from io import BytesIO
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from PIL import Image, ImageChops
from pypdf import PdfReader, PdfWriter
from pypdf.generic import DictionaryObject, FloatObject, NameObject, NumberObject
from reportlab.pdfgen import canvas
from gui_session import PrivateGuiSession


class TransitionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory(prefix="transition-", dir=OUTPUT)
        cls.directory = Path(cls.folder.name)
        cls.pdf = cls.directory / "transitions.pdf"
        document = canvas.Canvas(str(cls.pdf), pagesize=(400, 300))
        for page in range(3):
            if page == 1:
                document.setFillColorRGB(0, 0, 1)
                document.rect(0, 0, 400, 300, fill=1, stroke=0)
            else:
                # A deliberately distinct poster detects its accidental use
                # instead of the actual initial/partial/final vector state.
                document.setFillColorRGB(1, 0, 1)
                document.rect(50, 60, 300, 180, fill=1, stroke=0)
                document.linkURL("pdfpc-vector:motion", (50, 60, 350, 240), thickness=0)
            document.showPage()
        document.save()
        # ReportLab truncates fractional transition durations and writes /Di as
        # a name. Set the intended numeric values through the PDF object API.
        reader = PdfReader(BytesIO(cls.pdf.read_bytes()))
        writer = PdfWriter()
        for page in reader.pages:
            page[NameObject("/Trans")] = DictionaryObject({
                NameObject("/Type"): NameObject("/Trans"),
                NameObject("/S"): NameObject("/Wipe"),
                NameObject("/D"): FloatObject(.8),
                NameObject("/Di"): NumberObject(0),
            })
            writer.add_page(page)
        with cls.pdf.open("wb") as output:
            writer.write(output)
        for page in PdfReader(cls.pdf).pages:
            transition = page["/Trans"]
            if (not isinstance(transition["/D"], (FloatObject, NumberObject)) or
                    float(transition["/D"]) != .8 or
                    not isinstance(transition["/Di"], NumberObject) or
                    int(transition["/Di"]) != 0):
                raise AssertionError("Transition fixture must encode numeric /D 0.8 and /Di 0")
        scene = {"id": "motion", "width": 100, "height": 60, "duration": 3,
                 "background": [1, 1, 1, 1],
                 "checkpoints": [{"time": t, "label": str(t)} for t in (0, 1.5, 3)],
                 "objects": [{"id": "moving-box", "z": 0, "commands": "MLLLZ",
                    "keyframes": [{"time": t, "coords": [x, 20, x+20, 20, x+20, 40, x, 40],
                                   "fill": [1, 0, 0, 1], "stroke": [0, 0, 0, 0], "stroke_width": 0}
                                  for t, x in ((0, 10), (3, 70))]}]}
        cls.pdf.with_suffix(".vector.json").write_text(json.dumps({"version": 1, "scenes": [scene]}))

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def run_case(self, case):
        env = {**os.environ, "GDK_SCALE": "1", "GDK_DPI_SCALE": "1",
               "XDG_CONFIG_HOME": str(self.directory / "config"),
               "XDG_CACHE_HOME": str(self.directory / "cache")}
        for key in ("PDFPC_VECTOR_MANIFEST", "PDFPC_VECTOR_SPEED", "PDFPC_VECTOR_TRACE"):
            env.pop(key, None)
        prefix = OUTPUT / case
        for old_image in OUTPUT.glob(case + "-*.png"):
            old_image.unlink()
        with PrivateGuiSession(self.directory / (case + "-session"), env) as session:
            result = session.run([PROBE, str(self.pdf), case, str(prefix)])
        (OUTPUT / (case + ".log")).write_text(result.stdout + result.stderr, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS " + case, result.stdout)
        return prefix

    def image(self, prefix, name):
        with Image.open(str(prefix) + "-" + name + ".png") as image:
            return image.convert("RGB")

    def assert_solid(self, image, color, inset=0):
        if inset:
            # The centered PDF has a fractional horizontal edge at this GTK
            # allocation. Keep all interior pixels exact, excluding that edge.
            image = image.crop((inset, inset, image.width-inset, image.height-inset))
        self.assertIsNone(ImageChops.difference(image, Image.new("RGB", image.size, color)).getbbox())

    def assert_color(self, image, x, color):
        self.assertEqual(image.getpixel((round(image.width*x), image.height//2)), color)

    def test_outgoing_partial_state_and_first_frame(self):
        prefix = self.run_case("outgoing")
        before, first = self.image(prefix, "before"), self.image(prefix, "first")
        self.assertIsNone(ImageChops.difference(before, first).getbbox(),
                          "First transition frame must retain the composed outgoing state")
        middle = self.image(prefix, "middle")
        self.assert_color(before, .5, (255, 0, 0))
        self.assert_color(middle, .1, (0, 0, 255))
        self.assert_color(middle, .5, (255, 0, 0))
        self.assert_color(middle, .9, (255, 255, 255))
        self.assert_solid(self.image(prefix, "final"), (0, 0, 255), inset=1)

    def test_forward_entry_contains_initial_vector_state(self):
        prefix = self.run_case("incoming")
        self.assert_solid(self.image(prefix, "before"), (0, 0, 255), inset=1)
        self.assertIsNone(ImageChops.difference(self.image(prefix, "before"), self.image(prefix, "first")).getbbox())
        for phase in ("middle", "final"):
            image = self.image(prefix, phase)
            self.assertEqual(image.getpixel((round(image.width*.275), image.height//2)), (255, 0, 0))
        self.assert_color(self.image(prefix, "middle"), .9, (0, 0, 255))
        self.assert_color(self.image(prefix, "final"), .9, (255, 255, 255))

    def test_backward_entry_contains_final_vector_state(self):
        prefix = self.run_case("backward")
        self.assert_solid(self.image(prefix, "before"), (0, 0, 255), inset=1)
        self.assertIsNone(ImageChops.difference(self.image(prefix, "before"), self.image(prefix, "first")).getbbox())
        for phase in ("middle", "final"):
            image = self.image(prefix, phase)
            self.assertEqual(image.getpixel((round(image.width*.725), image.height//2)), (255, 0, 0))
        self.assert_color(self.image(prefix, "middle"), .1, (0, 0, 255))
        self.assert_color(self.image(prefix, "final"), .1, (255, 255, 255))

    def test_next_waits_for_audience(self): self.run_case("queued-next")
    def test_toggle_waits_for_audience(self): self.run_case("queued-toggle")
    def test_continuous_waits_for_audience(self): self.run_case("queued-all")
    def test_pending_start_is_cancelled_by_navigation(self):
        prefix = self.run_case("cancel-page")
        self.assert_solid(self.image(prefix, "cancelled"), (0, 0, 255), inset=1)

    def test_pending_start_is_cancelled_by_blanking(self):
        prefix = self.run_case("cancel-blank")
        self.assert_solid(self.image(prefix, "blank"), (0, 0, 0))
        self.assert_color(self.image(prefix, "recovered"), .275, (255, 0, 0))

    def test_pending_start_is_cancelled_by_toggle(self): self.run_case("cancel-toggle")

    def test_resize_completes_the_composed_entry(self):
        prefix = self.run_case("resize")
        image = self.image(prefix, "resized")
        self.assertLess(image.width, self.image(prefix, "before").width)
        self.assert_color(image, .325, (255, 0, 0))
        self.assert_color(image, .9, (255, 255, 255))

    def test_single_audience_window_releases_playback(self): self.run_case("audience-only")

    def test_presenter_only_paint_releases_playback(self):
        prefix = self.run_case("presenter-only")
        self.assert_color(self.image(prefix, "first"), .275, (255, 0, 0))

    def test_seek_during_entry_changes_the_composed_destination(self):
        prefix = self.run_case("cancel-seek")
        self.assert_color(self.image(prefix, "final"), .5, (255, 0, 0))

    def test_finish_during_entry_changes_the_composed_destination(self):
        prefix = self.run_case("cancel-finish")
        self.assert_color(self.image(prefix, "final"), .725, (255, 0, 0))

    def test_reload_cancels_the_request_and_allows_new_playback(self):
        prefix = self.run_case("cancel-reload")
        self.assert_color(self.image(prefix, "recovered"), .275, (255, 0, 0))

    def test_rapid_navigation_cancels_the_old_start(self):
        prefix = self.run_case("rapid-navigation")
        self.assert_color(self.image(prefix, "recovered"), .275, (255, 0, 0))

    def test_blanked_resize_remains_black_then_recovers(self):
        prefix = self.run_case("blank-resize")
        self.assert_solid(self.image(prefix, "blank"), (0, 0, 0))
        self.assert_solid(self.image(prefix, "resized"), (0, 0, 0))
        self.assert_color(self.image(prefix, "recovered"), .275, (255, 0, 0))

    def test_frozen_transition_stops_painting_and_survives_resize(self):
        prefix = self.run_case("freeze")
        held = self.image(prefix, "held")
        self.assertIsNone(ImageChops.difference(held, self.image(prefix, "held-later")).getbbox())
        for image in (held, self.image(prefix, "resized")):
            self.assert_color(image, .1, (255, 255, 255))
            self.assert_color(image, .9, (0, 0, 255))

    def test_destroying_waiting_view_cancels_and_recovers(self): self.run_case("destroy-waiting")
    def test_destroying_playing_view_cancels_and_recovers(self): self.run_case("destroy-playing")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("probe")
    parser.add_argument("--output", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    PROBE = str(Path(args.probe).resolve())
    OUTPUT = args.output.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    unittest.main(argv=[__file__, *remaining])
