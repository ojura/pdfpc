#!/usr/bin/env python3
"""Check production controller state in an owned display and session bus."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from reportlab.pdfgen import canvas
from test_renderer import fixture
from gui_session import PrivateGuiSession


class ControllerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="controller-", dir=OUTPUT)
        cls.directory = Path(cls.temporary.name)
        cls.pdf = cls.directory / "controller.pdf"
        cls.untimed = cls.directory / "untimed.pdf"
        for pdf, timed in ((cls.pdf, True), (cls.untimed, False)):
            document = canvas.Canvas(str(pdf), pagesize=(1000, 750))
            for page in range(3):
                document.drawString(50, 700, f"Controller fixture {page+1}")
                if page == 0:
                    if timed:
                        document.setPageDuration(.9)
                    document.linkURL("pdfpc-vector:rotation", (50, 100, 950, 640), thickness=0)
                document.showPage()
            document.save()
            pdf.with_suffix(".vector.json").write_text(json.dumps(fixture()))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def environment(self):
        environment = {**os.environ, "GDK_BACKEND": "x11", "NO_AT_BRIDGE": "1",
                       "GIO_USE_VFS": "local", "XDG_CONFIG_HOME": str(self.directory / "config"),
                       "XDG_CACHE_HOME": str(self.directory / "cache")}
        for name in ("PDFPC_VECTOR_MANIFEST", "PDFPC_VECTOR_SPEED", "PDFPC_VECTOR_TRACE"):
            environment.pop(name, None)
        return environment

    def run_case(self, case, timed=True):
        with PrivateGuiSession(self.directory / case, self.environment()) as session:
            result = session.run([PROBE, str(self.pdf if timed else self.untimed), case])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"PASS {case}", result.stdout)

    def test_next_starts_talk_timer(self): self.run_case("next-start")
    def test_next_resumes_talk_timer(self): self.run_case("next-resume")
    def test_toggle_starts_talk_timer(self): self.run_case("toggle-start")
    def test_play_all_starts_talk_timer(self): self.run_case("all-start")
    def test_initial_page_autoadvance(self): self.run_case("initial-autoadvance")
    def test_resumed_page_autoadvance(self): self.run_case("resumed-autoadvance")
    def test_segments_keep_page_deadline(self): self.run_case("checkpoint-keeps-deadline")
    def test_no_page_duration(self): self.run_case("no-duration", timed=False)
    def test_blanked_play_keeps_stopped_timer(self): self.run_case("blocked-stopped")
    def test_blanked_play_keeps_paused_timer(self): self.run_case("blocked-paused")
    def test_presenter_pause_indicator_tracks_animation_resume(self):
        self.run_case("presenter-resume", timed=False)

    def test_timeout_closes_display_bus_and_probe(self):
        session = PrivateGuiSession(self.directory / "timeout", self.environment())
        with self.assertRaises(subprocess.TimeoutExpired) as stopped:
            with session:
                session.run([PROBE, str(self.untimed), "hang"], timeout=1)
        self.assertIn("READY hang", stopped.exception.output)
        self.assertEqual(len(session.processes), 3)
        for process in session.processes:
            self.assertIsNotNone(process.poll())
            with self.assertRaises(ProcessLookupError):
                os.kill(process.pid, 0)
            with self.assertRaises(ProcessLookupError):
                os.killpg(process.pid, 0)

    def test_failed_bus_start_closes_the_display_and_ready_pipes(self):
        session = PrivateGuiSession(self.directory / "failed-start", self.environment())
        start = session.start
        pipe = os.pipe
        pipes = []

        def record_pipe():
            descriptors = pipe()
            pipes.append(descriptors)
            return descriptors

        def fail_bus(command, **kwargs):
            if command[0] == "dbus-daemon":
                raise FileNotFoundError("Injected missing session bus")
            return start(command, **kwargs)

        with patch.object(session, "start", side_effect=fail_bus), \
                patch("gui_session.os.pipe", side_effect=record_pipe):
            with self.assertRaisesRegex(FileNotFoundError, "Injected missing"):
                with session:
                    self.fail("A failed bus launch must not enter the session")
        self.assertEqual(len(session.processes), 1)
        self.assertIsNotNone(session.processes[0].poll())
        for descriptors in pipes:
            for descriptor in descriptors:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("probe", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args, rest = parser.parse_known_args()
    PROBE = str(args.probe.resolve())
    OUTPUT = args.output.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    unittest.main(argv=[__file__, *rest])
