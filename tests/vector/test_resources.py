#!/usr/bin/env python3
"""Exercise production resource precedence, including the Windows resolver branch."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ResourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pdfpc resources ")
        self.root = Path(self.temporary.name)
        self.executable = self.root / "bin/pdfpc.exe"
        self.executable.parent.mkdir()
        self.resource = Path("css/notes.css")
        self.local_resource = self.root / "share/pdfpc" / self.resource
        self.local_config = self.root / "etc/pdfpcrc"
        self.environment = {name: value for name, value in os.environ.items()
                            if name not in ("PDFPC_DATA_DIR", "PDFPC_CONFIG_DIR")}

    def tearDown(self):
        self.temporary.cleanup()

    def resolve(self, *, source=False, **overrides):
        result = subprocess.run([PROBE, str(self.executable),
                                 "source" if source else "installed", str(self.resource)],
                                env={**self.environment, **overrides},
                                capture_output=True, text=True, check=True)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 2, result.stdout)
        return tuple(Path(os.path.normpath(value)) for value in lines)

    def add_local_files(self):
        for filename in (self.local_resource, self.local_config):
            filename.parent.mkdir(parents=True, exist_ok=True)
            filename.write_text("local resource\n")

    def test_installed_and_no_install_paths(self):
        self.assertEqual(self.resolve(), (Path("configured-share") / self.resource,
                                          Path("configured-config/pdfpcrc")))
        self.assertEqual(self.resolve(source=True), (Path("configured-source") / self.resource,
                                                     Path("configured-source/rc/pdfpcrc")))

    def test_empty_overrides_use_the_normal_paths(self):
        for source in (False, True):
            self.assertEqual(self.resolve(source=source, PDFPC_DATA_DIR="", PDFPC_CONFIG_DIR=""),
                             self.resolve(source=source))

    def test_explicit_overrides_precede_local_and_source_paths(self):
        self.add_local_files()
        data = self.root / "explicit data"
        config = self.root / "explicit config"
        for source in (False, True):
            self.assertEqual(self.resolve(source=source, PDFPC_DATA_DIR=str(data),
                                          PDFPC_CONFIG_DIR=str(config)),
                             (data / self.resource, config / "pdfpcrc"))

    def test_independent_overrides_do_not_replace_the_other_kind(self):
        normal_data, normal_config = self.resolve()
        self.assertEqual(self.resolve(PDFPC_DATA_DIR="custom-data"),
                         (Path("custom-data") / self.resource, normal_config))
        self.assertEqual(self.resolve(PDFPC_CONFIG_DIR="custom-config"),
                         (normal_data, Path("custom-config/pdfpcrc")))

    def test_executable_relative_resources_follow_the_platform_policy(self):
        self.add_local_files()
        for source in (False, True):
            expected = ((self.local_resource, self.local_config) if WINDOWS_BRANCH else
                        ((Path("configured-source") / self.resource, Path("configured-source/rc/pdfpcrc"))
                         if source else (Path("configured-share") / self.resource, Path("configured-config/pdfpcrc"))))
            self.assertEqual(self.resolve(source=source), expected)
        self.local_resource.unlink()
        # Each resource falls back independently when its local file is absent.
        expected_config = self.local_config if WINDOWS_BRANCH else Path("configured-config/pdfpcrc")
        self.assertEqual(self.resolve(), (Path("configured-share") / self.resource, expected_config))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("probe", type=Path)
    parser.add_argument("--windows-branch", action="store_true")
    options, rest = parser.parse_known_args()
    PROBE = str(options.probe.resolve())
    WINDOWS_BRANCH = options.windows_branch
    unittest.main(argv=[__file__, *rest])
