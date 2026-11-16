"""Own a private X server, session bus and the processes used by GUI tests."""
from __future__ import annotations

from contextlib import contextmanager
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time


_sessions = []
_previous_handlers = {}
_critical_depth = 0
_pending_signal = None


def _restore_handlers():
    if _sessions or _critical_depth:
        return
    for number, previous in _previous_handlers.items():
        if signal.getsignal(number) == _terminated:
            signal.signal(number, previous)
    _previous_handlers.clear()


@contextmanager
def _registering_or_closing():
    """Finish child registration or cleanup before dispatching termination."""
    global _critical_depth, _pending_signal
    _critical_depth += 1
    try:
        yield
    finally:
        _critical_depth -= 1
        if not _critical_depth:
            pending, _pending_signal = _pending_signal, None
            _restore_handlers()
            if pending is not None:
                _finish_termination(*pending)


def _terminated(number, frame):
    global _pending_signal
    previous = _previous_handlers[number]
    if _critical_depth:
        if _pending_signal is None:
            _pending_signal = (number, frame, previous)
        return
    _finish_termination(number, frame, previous)


def _finish_termination(number, frame, previous):
    with _registering_or_closing():
        for session in reversed(list(_sessions)):
            try:
                session.close()
            except BaseException as error:
                print("GUI test cleanup failed: " + str(error), file=sys.stderr)
    if callable(previous):
        previous(number, frame)
    elif previous != signal.SIG_IGN:
        # Preserve a signal exit status instead of converting it to success or
        # a Python exception. Callable handlers retain their own exit policy.
        signal.signal(number, previous)
        os.kill(os.getpid(), number)


def _register_session(session):
    if session in _sessions:
        return
    if not _sessions:
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            previous = signal.getsignal(number)
            if previous != signal.SIG_IGN:
                _previous_handlers[number] = previous
                signal.signal(number, _terminated)
    _sessions.append(session)


class PrivateGuiSession:
    def __init__(self, directory: Path, environment=None, screen="1600x1000x24"):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.environment = dict(os.environ if environment is None else environment)
        self.environment.update(GDK_BACKEND="x11", NO_AT_BRIDGE="1", GIO_USE_VFS="local")
        self.environment.pop("DBUS_STARTER_ADDRESS", None)
        self.environment.pop("DBUS_STARTER_BUS_TYPE", None)
        self.screen = screen
        self.processes = []
        self.logs = []
        self._closed = False

    def start(self, command, **kwargs):
        if self._closed:
            raise RuntimeError("This private GUI session is already closed")
        # A signal between Popen returning and appending its result must not
        # leave a newly created process outside this session's cleanup list.
        with _registering_or_closing():
            _register_session(self)
            process = subprocess.Popen(command, env=self.environment,
                                       start_new_session=True, **kwargs)
            self.processes.append(process)
        return process

    def _ready(self, command, name, timeout=10):
        reader, writer = os.pipe()
        try:
            try:
                log = (self.directory / (name + ".log")).open("wb")
                self.logs.append(log)
                self.start([part.format(fd=writer) for part in command],
                           pass_fds=(writer,), stdout=log, stderr=log)
            finally:
                os.close(writer)
            deadline = time.monotonic() + timeout
            value = bytearray()
            while b"\n" not in value:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([reader], [], [], remaining)[0]:
                    raise TimeoutError(name + " did not announce readiness")
                data = os.read(reader, 4096)
                if not data:
                    raise RuntimeError(name + " exited before announcing readiness")
                value.extend(data)
            return value.split(b"\n", 1)[0].decode().strip()
        finally:
            os.close(reader)

    def __enter__(self):
        try:
            display = self._ready(["Xvfb", "-displayfd", "{fd}", "-screen", "0",
                                   self.screen, "-nolisten", "tcp", "-noreset"], "xvfb")
            self.environment["DISPLAY"] = ":" + display
            address = self._ready(["dbus-daemon", "--session", "--nofork",
                                   "--nopidfile", "--print-address={fd}"], "dbus")
            self.environment["DBUS_SESSION_BUS_ADDRESS"] = address
            return self
        except BaseException:
            self.close()
            raise

    @staticmethod
    def _signal_group(process, signum):
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass

    def run(self, command, timeout=30):
        process = self.start(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            output, error = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            self._signal_group(process, signal.SIGTERM)
            try:
                output, error = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                self._signal_group(process, signal.SIGKILL)
                output, error = process.communicate()
            raise subprocess.TimeoutExpired(command, timeout, output=output, stderr=error) from None
        return subprocess.CompletedProcess(command, process.returncode, output, error)

    def close(self):
        if self._closed:
            return
        with _registering_or_closing():
            self._closed = True
            try:
                # Stop clients before the bus and display. Every process was
                # started directly in its own process group.
                for process in reversed(self.processes):
                    self._signal_group(process, signal.SIGTERM)
                for process in reversed(self.processes):
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        self._signal_group(process, signal.SIGKILL)
                        process.wait(timeout=5)
                    self._signal_group(process, signal.SIGKILL)
            finally:
                for log in self.logs:
                    log.close()
                if self in _sessions:
                    _sessions.remove(self)

    def __exit__(self, *_exc):
        self.close()
