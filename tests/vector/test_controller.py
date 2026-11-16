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
        for name in ("PDFPC_VECTOR_MANIFEST", "PDFPC_VECTOR_SPEED", "PDFPC_VECTOR_TRACE",
                     "PDFPC_CONFIG_DIR", "PDFPC_DATA_DIR"):
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

    def inspect_bindings(self, *statements):
        with PrivateGuiSession(self.directory / self.id().rsplit(".", 1)[-1],
                               self.environment()) as session:
            result = session.run([PROBE, str(self.untimed), "bindings", *statements])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS bindings", result.stdout)
        report = json.loads(next(line[len("BINDINGS "):]
                                 for line in result.stdout.splitlines()
                                 if line.startswith("BINDINGS ")))
        for name in ("bindings", "descriptions"):
            entries = report[name]
            self.assertEqual(len(entries) % 2, 0)
            report[name] = dict(zip(entries[::2], entries[1::2]))
        self.assertEqual(len(report["buttons"]), 4)
        self.assertTrue(all(button["mapped"] for button in report["buttons"]), report)
        report["stderr"] = result.stderr
        (OUTPUT / (self.id().rsplit(".", 1)[-1] + ".json")).write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8")
        return report

    def assert_vector_tooltips(self, report):
        actions = ("vectorRestart", "vectorPreviousCheckpoint", "vectorToggle",
                   "vectorNextCheckpoint")
        for action, button in zip(actions, report["buttons"]):
            with self.subTest(action=action):
                bindings = report["bindings"].get(action, "")
                expected = report["descriptions"][action]
                if bindings:
                    expected += " (" + bindings + ")"
                self.assertEqual(button["tooltip"], expected)
                self.assertTrue(button["has_tooltip"])

    def test_binding_display_retains_every_modifier(self):
        report = self.inspect_bindings("unbind_all", "unmouse_all",
            "bind C+Right vectorNextCheckpoint", "bind M+Left vectorPreviousCheckpoint",
            "bind S+Home vectorRestart", "bind CM+Up vectorPlayAll",
            "bind CS+Down vectorFinish", "bind MS+End vectorToggle",
            "bind CMS+Insert vectorStatus")
        self.assertEqual(report["bindings"], {
            "vectorNextCheckpoint": "Ctrl+Right", "vectorPreviousCheckpoint": "Meta+Left",
            "vectorRestart": "Shift+Home", "vectorPlayAll": "Ctrl+Meta+Up",
            "vectorFinish": "Ctrl+Shift+Down", "vectorToggle": "Meta+Shift+End",
            "vectorStatus": "Ctrl+Meta+Shift+Insert",
        })

    def test_binding_display_keeps_shifted_letters_and_alt_alias(self):
        report = self.inspect_bindings("unbind_all", "unmouse_all",
            "bind X vectorRestart", "bind CS+y vectorToggle",
            "bind CA+Left vectorPreviousCheckpoint", "bind a vectorNextCheckpoint")
        self.assertEqual(report["bindings"], {
            "vectorRestart": "Shift+x", "vectorToggle": "Ctrl+Shift+y",
            "vectorPreviousCheckpoint": "Ctrl+Meta+Left", "vectorNextCheckpoint": "a",
        })

    def test_mouse_binding_display_uses_its_own_parameters(self):
        report = self.inspect_bindings("unbind_all", "unmouse_all",
            "bind a switchMode pen", "mouse 97 switchMode pointer",
            "mouse CS+1 windowed presentation", "mouse 2 setPenColor red")
        self.assertCountEqual(report["bindings"]["switchMode"].split(", "),
                              ("a [pen]", "Mouse_97 [pointer]"))
        self.assertEqual(report["bindings"]["windowed"], "Ctrl+Shift+Mouse_1 [presentation]")
        self.assertEqual(report["bindings"]["setPenColor"], "Mouse_2 [red]")

    def test_parsed_parameters_follow_registered_action_types(self):
        report = self.inspect_bindings("unbind_all", "unmouse_all",
            "mouse 1 gotoPage 3", "bind g gotoPage 2", "bind CM+m movePointer 0.1,0.2")
        self.assertCountEqual(report["bindings"].get("gotoPage", "").split(", "),
                              ("g [2]", "Mouse_1 [3]"))
        self.assertEqual(report["bindings"].get("movePointer"), "Ctrl+Meta+m [0.1,0.2]")
        self.assertNotIn("expects a parameter", report["stderr"])
        self.assertNotIn("No argument is expected", report["stderr"])

    def test_invalid_binding_does_not_replace_a_valid_binding(self):
        report = self.inspect_bindings("unbind_all", "unmouse_all",
            "bind a switchMode pen", "bind a switchMode",
            "mouse 1 windowed presenter", "mouse 1 windowed",
            "bind x vectorRestart", "bind x vectorToggle unexpected",
            "mouse 2 vectorNextCheckpoint", "mouse 2 vectorToggle unexpected",
            "bind x absentAction", "mouse 2 absentAction")
        self.assertEqual(report["bindings"], {
            "switchMode": "a [pen]", "windowed": "Mouse_1 [presenter]",
            "vectorRestart": "x", "vectorNextCheckpoint": "Mouse_2",
        })
        self.assertIn("Action switchMode expects a parameter", report["stderr"])
        self.assertIn("Action windowed expects a parameter", report["stderr"])
        self.assertIn("does not expect a parameter", report["stderr"])
        self.assertIn("Unknown action absentAction", report["stderr"])

    def test_default_presenter_tooltips_use_action_descriptions(self):
        report = self.inspect_bindings()
        self.assertEqual(report["bindings"]["vectorNextCheckpoint"], "Ctrl+Right")
        self.assert_vector_tooltips(report)

    def test_remapped_presenter_tooltips_follow_actual_bindings(self):
        report = self.inspect_bindings("unbind_all", "unmouse_all",
            "bind x vectorRestart", "bind A+Left vectorPreviousCheckpoint",
            "mouse 1 vectorToggle", "bind CMS+Right vectorNextCheckpoint",
            "mouse S+3 vectorNextCheckpoint", "bind r quit")
        self.assertCountEqual(report["bindings"]["vectorNextCheckpoint"].split(", "),
                              ("Ctrl+Meta+Shift+Right", "Shift+Mouse_3"))
        self.assertEqual(report["bindings"]["vectorToggle"], "Mouse_1")
        self.assert_vector_tooltips(report)

    def test_unbound_presenter_actions_keep_description_only(self):
        report = self.inspect_bindings("unbind_all", "unmouse_all")
        self.assertEqual(report["bindings"], {})
        self.assert_vector_tooltips(report)

    def test_disabled_tooltips_apply_to_vector_controls_and_status(self):
        report = self.inspect_bindings("option disable-tooltips true")
        for button in report["buttons"]:
            self.assertIsNone(button["tooltip"])
            self.assertFalse(button["has_tooltip"])
        self.assertIsNone(report["status_tooltip"])

    def inspect_trace(self, case, destination=None):
        environment = self.environment()
        environment["G_DEBUG"] = "fatal-criticals"
        if destination is not None:
            environment["PDFPC_VECTOR_TRACE"] = str(destination)
        with PrivateGuiSession(self.directory / case, environment) as session:
            result = session.run([PROBE, str(self.untimed), case])
        prefix = OUTPUT / self.id().rsplit(".", 1)[-1]
        prefix.with_suffix(".log").write_text(
            "STDOUT\n" + result.stdout + "\nSTDERR\n" + result.stderr, encoding="utf-8")
        records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        self.assertEqual(len(records), 2, result.stdout + result.stderr)
        for record in records:
            self.assertEqual((record["event"], record["reason"]), ("state", "status"))
            self.assertEqual(record["scene"], "rotation")
            self.assertFalse(record["playing"])
        report = json.loads(next(line[len("TRACE "):] for line in result.stdout.splitlines()
                                 if line.startswith("TRACE ")))
        prefix.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        self.assertGreater(report["advanced_time"], 0)
        self.assertAlmostEqual(records[0]["time"], report["advanced_time"], places=6)
        self.assertAlmostEqual(records[1]["time"], .3, places=6)
        self.assertFalse(report["after_close_enabled"])
        self.assertTrue(all(process.poll() is not None for process in session.processes))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return report, result.stderr

    def test_trace_write_failure_disables_sink_not_playback_or_status(self):
        report, errors = self.inspect_trace("trace-failure", "/dev/full")
        self.assertFalse(report["initial_enabled"])
        self.assertFalse(report["after_play_enabled"])
        self.assertEqual(report["diagnostic_cpu_us"], -1)
        self.assertEqual(errors.count("Cannot write vector trace"), 1, errors)
        self.assertIn("/dev/full", errors)
        self.assertNotIn("Cannot open vector trace", errors)

    def test_trace_close_is_idempotent_and_status_remains_available(self):
        destination = OUTPUT / "controller-trace.jsonl"
        destination.unlink(missing_ok=True)
        report, errors = self.inspect_trace("trace-normal", destination)
        self.assertTrue(report["initial_enabled"])
        self.assertTrue(report["after_play_enabled"])
        self.assertEqual(errors, "")
        records = [json.loads(line) for line in destination.read_text().splitlines()]
        self.assertTrue(any(record["event"] == "frame" for record in records))
        self.assertTrue(any(record["event"] == "timing" for record in records))
        self.assertEqual(sum(record["event"] == "trace-closed" for record in records), 1)
        self.assertEqual(records[-1]["event"], "trace-closed")
        self.assertEqual(sum(record.get("reason") == "status" for record in records), 1)

    def test_status_without_trace_does_not_enable_collection(self):
        report, errors = self.inspect_trace("trace-none")
        self.assertFalse(report["initial_enabled"])
        self.assertFalse(report["after_play_enabled"])
        self.assertEqual(report["diagnostic_cpu_us"], -1)
        self.assertEqual(errors, "")

    def test_stopped_collector_does_not_retain_playback(self):
        destination = OUTPUT / "released-playback.jsonl"
        destination.unlink(missing_ok=True)
        environment = self.environment()
        environment.update(PDFPC_VECTOR_TRACE=str(destination), G_DEBUG="fatal-criticals")
        with PrivateGuiSession(self.directory / "trace-release", environment) as session:
            result = session.run([PROBE, str(self.untimed), "trace-release"])
        (OUTPUT / "trace-release.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("PASS trace-release", result.stdout)
        records = [json.loads(line) for line in destination.read_text().splitlines()]
        self.assertEqual(records[-1]["event"], "frame")
        self.assertEqual(records[-1]["view"], "lifetime")
        self.assertTrue(all(process.poll() is not None for process in session.processes))

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
