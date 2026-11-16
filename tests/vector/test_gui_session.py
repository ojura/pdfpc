#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Terminate a real GUI test runner and check its owned process groups."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from gui_session import PrivateGuiSession


def group_exists(identifier):
    try:
        os.killpg(identifier, 0)
        return True
    except ProcessLookupError:
        return False


def read_owned(directory):
    filename = directory / "owned.json"
    return json.loads(filename.read_text()) if filename.exists() else []


def reap_owned(identifiers):
    # The Linux test process adopts only descendants of its own killed runner.
    for identifier in identifiers:
        while True:
            try:
                pid, _status = os.waitpid(-identifier, os.WNOHANG)
            except ChildProcessError:
                break
            if pid == 0:
                break


def await_condition(check, timeout=10):
    deadline = time.monotonic() + timeout
    while not check():
        if time.monotonic() >= deadline:
            raise AssertionError("Timed out waiting for the owned test process")
        time.sleep(.025)


def worker(directory, mode, pdfpc):
    directory.mkdir(parents=True, exist_ok=True)

    class RecordingSession(PrivateGuiSession):
        def start(self, command, **kwargs):
            process = super().start(command, **kwargs)
            temporary = directory / "owned.new"
            temporary.write_text(json.dumps([child.pid for child in self.processes]))
            temporary.replace(directory / "owned.json")
            if mode == "full-gui" and len(self.processes) == 3:
                (directory / "ready").write_text("ready\n")
            if mode == "starting" and len(self.processes) == 2:
                (directory / "ready").write_text("ready\n")
            return process

        def _ready(self, command, name, timeout=10):
            if mode == "starting" and name == "dbus":
                command = [sys.executable, "-c", "import signal; signal.pause()"]
            return super()._ready(command, name, timeout)

    if mode.startswith("full-"):
        import test_gui
        test_gui.PrivateGuiSession = RecordingSession
        executable = directory / "missing-pdfpc" if mode == "full-missing" else pdfpc
        sys.argv = [test_gui.__file__, str(executable), "--output", str(directory / "gui")]
        if mode == "full-preload":
            sys.argv += ["--future-frame-clock", str(directory / "missing-clock.so")]
        test_gui.main()
        return

    if mode == "report-signal":
        def terminated(number, _frame):
            (directory / "signal.txt").write_text(str(number))
            signal.signal(number, signal.SIG_DFL)
            os.kill(os.getpid(), number)
        signal.signal(signal.SIGTERM, terminated)

    with RecordingSession(directory) as session:
        client = "import time; time.sleep(60)"
        if mode == "family":
            descendant = ("import signal,time; from pathlib import Path; "
                          "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                          "Path(" + repr(str(directory / "descendant-ready")) + ").touch(); "
                          "time.sleep(60)")
            client = ("import subprocess,sys,time; "
                      "subprocess.Popen([sys.executable,'-c'," + repr(descendant) + "]); "
                      "time.sleep(60)")
        session.start([sys.executable, "-c", client],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if mode == "family":
            await_condition(lambda: (directory / "descendant-ready").exists())
        (directory / "ready").write_text("ready\n")
        while True:
            signal.pause()


class GuiSessionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.previous_subreaper = ctypes.c_int()
        cls.libc = ctypes.CDLL(None, use_errno=True) if sys.platform == "linux" else None
        if cls.libc is not None:
            if cls.libc.prctl(37, ctypes.byref(cls.previous_subreaper), 0, 0, 0) != 0:
                raise OSError(ctypes.get_errno(), "PR_GET_CHILD_SUBREAPER")
            if cls.libc.prctl(36, 1, 0, 0, 0) != 0:
                raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")

    @classmethod
    def tearDownClass(cls):
        if cls.libc is not None:
            cls.libc.prctl(36, cls.previous_subreaper.value, 0, 0, 0)

    @contextmanager
    def owned_runner(self, command_factory, *, ready=True, groups=3):
        with tempfile.TemporaryDirectory(prefix="runner-", dir=OUTPUT) as temporary:
            directory = Path(temporary)
            with (directory / "runner.log").open("wb") as log:
                process = subprocess.Popen(command_factory(directory), start_new_session=True,
                                           stdout=log, stderr=log,
                                           env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
                try:
                    if ready:
                        await_condition(lambda: (directory / "ready").exists() or process.poll() is not None)
                        self.assertTrue((directory / "ready").exists(),
                                        (directory / "runner.log").read_text())
                        self.assertEqual(len(read_owned(directory)), groups)
                    yield process, directory
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=10)
                    identifiers = read_owned(directory)
                    # Always clean our failed baseline, including children that
                    # the uncorrected helper leaves running after termination.
                    for identifier in identifiers:
                        try:
                            os.killpg(identifier, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    await_condition(lambda: self.groups_gone(identifiers), timeout=10)

    @staticmethod
    def groups_gone(identifiers):
        reap_owned(identifiers)
        return not any(group_exists(identifier) for identifier in identifiers)

    def assert_cleaned(self, directory):
        identifiers = read_owned(directory)
        try:
            await_condition(lambda: self.groups_gone(identifiers), timeout=3)
        except AssertionError:
            self.fail("Runner left owned process groups running: " +
                      str([item for item in identifiers if group_exists(item)]))

    def test_external_sigterm_cleans_owned_groups(self):
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with self.subTest(signal=number):
                with self.owned_runner(lambda directory: [sys.executable, "-B", __file__,
                        "--worker", str(directory)]) as (process, directory):
                    process.send_signal(number)
                    self.assertEqual(process.wait(timeout=10), -number)
                    self.assert_cleaned(directory)

    def test_external_sigterm_during_readiness_cleans_partial_startup(self):
        with self.owned_runner(lambda directory: [sys.executable, "-B", __file__,
                "--worker", str(directory), "--mode", "starting"], groups=2) as (process, directory):
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=10), -signal.SIGTERM)
            self.assert_cleaned(directory)

    def test_external_sigterm_kills_a_resistant_descendant(self):
        with self.owned_runner(lambda directory: [sys.executable, "-B", __file__,
                "--worker", str(directory), "--mode", "family"]) as (process, directory):
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=10), -signal.SIGTERM)
            self.assert_cleaned(directory)

    def test_ctest_timeout_cleans_owned_groups(self):
        def command(directory):
            arguments = " ".join(json.dumps(str(item)) for item in
                                 (sys.executable, "-B", Path(__file__).resolve(),
                                  "--worker", directory, "--mode", "report-signal"))
            (directory / "CTestTestfile.cmake").write_text(
                "add_test(interrupted " + arguments + ")\n"
                "set_tests_properties(interrupted PROPERTIES TIMEOUT 3)\n")
            return ["ctest", "--test-dir", str(directory), "--output-on-failure"]

        with self.owned_runner(command) as (process, directory):
            self.assertNotEqual(process.wait(timeout=15), 0)
            output = (directory / "runner.log").read_text()
            self.assertIn("Timeout", output)
            received = directory / "signal.txt"
            print("CTest SIGTERM handler:", received.read_text() if received.exists() else "not invoked", flush=True)
            self.assert_cleaned(directory)

    def test_normal_close_restores_handlers_and_is_idempotent(self):
        handlers = {number: signal.getsignal(number) for number in
                    (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        with tempfile.TemporaryDirectory(dir=OUTPUT) as temporary:
            session = PrivateGuiSession(Path(temporary))
            with session:
                self.assertIsNot(signal.getsignal(signal.SIGTERM), handlers[signal.SIGTERM])
            self.assertEqual({number: signal.getsignal(number) for number in handlers}, handlers)
            self.assertTrue(all(process.poll() is not None for process in session.processes))
            with patch("gui_session.os.killpg") as kill:
                session.close()
                kill.assert_not_called()
            with self.assertRaisesRegex(RuntimeError, "already closed"):
                session.start([sys.executable, "-c", "pass"])

    def test_failed_start_restores_handlers(self):
        handlers = {number: signal.getsignal(number) for number in
                    (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        with tempfile.TemporaryDirectory(dir=OUTPUT) as temporary:
            session = PrivateGuiSession(Path(temporary))
            start = session.start

            def missing_bus(command, **kwargs):
                if command[0] == "dbus-daemon":
                    raise FileNotFoundError("missing bus fixture")
                return start(command, **kwargs)

            with patch.object(session, "start", side_effect=missing_bus):
                with self.assertRaisesRegex(FileNotFoundError, "missing bus fixture"):
                    with session:
                        self.fail("A failed startup entered its context")
            self.assertEqual({number: signal.getsignal(number) for number in handlers}, handlers)
            self.assertTrue(all(process.poll() is not None for process in session.processes))

    def test_nested_signal_closes_sessions_before_calling_prior_handler(self):
        observed = []
        sessions = []

        def prior(number, _frame):
            observed.append((number, [process.poll() for session in sessions
                                      for process in session.processes]))

        previous = signal.signal(signal.SIGTERM, prior)
        try:
            with tempfile.TemporaryDirectory(dir=OUTPUT) as temporary:
                root = Path(temporary)
                outer, inner = PrivateGuiSession(root / "outer"), PrivateGuiSession(root / "inner")
                sessions.extend((outer, inner))
                unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                             start_new_session=True)
                try:
                    with outer, inner:
                        os.kill(os.getpid(), signal.SIGTERM)
                        self.assertEqual(len(observed), 1)
                        self.assertEqual(observed[0][0], signal.SIGTERM)
                        self.assertTrue(all(value is not None for value in observed[0][1]))
                        self.assertIsNone(unrelated.poll())
                        self.assertIs(signal.getsignal(signal.SIGTERM), prior)
                finally:
                    unrelated.terminate()
                    unrelated.wait(timeout=5)
        finally:
            signal.signal(signal.SIGTERM, previous)

    def test_nested_normal_close_keeps_outer_cleanup(self):
        previous = signal.getsignal(signal.SIGTERM)
        with tempfile.TemporaryDirectory(dir=OUTPUT) as temporary:
            root = Path(temporary)
            with PrivateGuiSession(root / "outer") as outer:
                active_handler = signal.getsignal(signal.SIGTERM)
                with PrivateGuiSession(root / "inner"):
                    self.assertIs(signal.getsignal(signal.SIGTERM), active_handler)
                self.assertIs(signal.getsignal(signal.SIGTERM), active_handler)
                self.assertTrue(all(process.poll() is None for process in outer.processes))
            self.assertIs(signal.getsignal(signal.SIGTERM), previous)

    def test_ignored_signal_and_new_caller_handler_are_preserved(self):
        previous = signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            with tempfile.TemporaryDirectory(dir=OUTPUT) as temporary:
                with PrivateGuiSession(Path(temporary)) as session:
                    self.assertEqual(signal.getsignal(signal.SIGTERM), signal.SIG_IGN)
                    os.kill(os.getpid(), signal.SIGTERM)
                    self.assertTrue(all(process.poll() is None for process in session.processes))
                self.assertEqual(signal.getsignal(signal.SIGTERM), signal.SIG_IGN)
        finally:
            signal.signal(signal.SIGTERM, previous)

        def replacement(_number, _frame):
            pass

        try:
            with tempfile.TemporaryDirectory(dir=OUTPUT) as temporary:
                with PrivateGuiSession(Path(temporary)):
                    signal.signal(signal.SIGTERM, replacement)
                self.assertIs(signal.getsignal(signal.SIGTERM), replacement)
        finally:
            signal.signal(signal.SIGTERM, previous)

    def test_signal_between_spawn_and_registration_closes_new_child(self):
        observed = []
        session = None

        def prior(_number, _frame):
            observed.append([process.poll() for process in session.processes])

        previous = signal.signal(signal.SIGTERM, prior)
        try:
            with tempfile.TemporaryDirectory(dir=OUTPUT) as temporary:
                with PrivateGuiSession(Path(temporary)) as session:
                    popen = subprocess.Popen

                    def interrupted_spawn(*args, **kwargs):
                        process = popen(*args, **kwargs)
                        os.kill(os.getpid(), signal.SIGTERM)
                        return process

                    with patch("gui_session.subprocess.Popen", side_effect=interrupted_spawn):
                        process = session.start([sys.executable, "-c", "import time; time.sleep(60)"])
                    self.assertIsNotNone(process.poll())
                    self.assertEqual(len(observed), 1)
                    self.assertEqual(len(observed[0]), 3)
                    self.assertTrue(all(value is not None for value in observed[0]))
        finally:
            signal.signal(signal.SIGTERM, previous)

    def test_full_gui_failed_viewer_start_closes_display_and_bus(self):
        with self.owned_runner(lambda directory: [sys.executable, "-B", __file__,
                "--worker", str(directory), "--mode", "full-missing"], ready=False) as (process, directory):
            self.assertNotEqual(process.wait(timeout=15), 0)
            self.assertIn("missing-pdfpc", (directory / "runner.log").read_text())
            self.assertEqual(len(read_owned(directory)), 2)
            self.assert_cleaned(directory)

    def test_full_gui_missing_preload_starts_no_process(self):
        with self.owned_runner(lambda directory: [sys.executable, "-B", __file__,
                "--worker", str(directory), "--mode", "full-preload",
                "--pdfpc", str(PDFPC)], ready=False) as (process, directory):
            self.assertNotEqual(process.wait(timeout=15), 0)
            self.assertIn("missing-clock.so", (directory / "runner.log").read_text())
            self.assertEqual(read_owned(directory), [])

    def test_external_sigterm_closes_full_gui_runner(self):
        self.assertTrue(PDFPC.is_file(), "Build pdfpc or supply --pdfpc")
        with self.owned_runner(lambda directory: [sys.executable, "-B", __file__,
                "--worker", str(directory), "--mode", "full-gui",
                "--pdfpc", str(PDFPC)]) as (process, directory):
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=10), -signal.SIGTERM)
            self.assert_cleaned(directory)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path)
    parser.add_argument("--mode", default="default")
    parser.add_argument("--pdfpc", type=Path,
                        default=Path(__file__).resolve().parents[2] / "build/bin/pdfpc")
    parser.add_argument("--output", type=Path, default=Path("build/tests/vector/gui-session"))
    args, remaining = parser.parse_known_args()
    if args.worker:
        worker(args.worker, args.mode, args.pdfpc.resolve())
    else:
        PDFPC = args.pdfpc.resolve()
        OUTPUT = args.output.resolve()
        OUTPUT.mkdir(parents=True, exist_ok=True)
        unittest.main(argv=[__file__, *remaining], verbosity=2)
