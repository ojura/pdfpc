"""Own a private X server, session bus and the processes used by GUI tests."""
from __future__ import annotations

import os
from pathlib import Path
import select
import signal
import subprocess
import time


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

    def start(self, command, **kwargs):
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
        # Stop clients before the bus and display. Every process was started
        # directly in its own session, not hidden behind a shell wrapper.
        for process in reversed(self.processes):
            self._signal_group(process, signal.SIGTERM)
        for process in reversed(self.processes):
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._signal_group(process, signal.SIGKILL)
                process.wait(timeout=5)
            # Also stop any remaining child in the owned process group.
            self._signal_group(process, signal.SIGKILL)
        for log in self.logs:
            log.close()

    def __exit__(self, *_exc):
        self.close()
