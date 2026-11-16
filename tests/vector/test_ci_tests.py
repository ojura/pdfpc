#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Required native tests cannot disappear from an otherwise green CI run."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

from ci_tests import REQUIRED, check_registered, check_results


class RequiredTests(unittest.TestCase):
    def test_missing_or_disabled_registration_fails(self):
        inventory = {"tests": [{"name": name} for name in sorted(REQUIRED)]}
        self.assertEqual(check_registered(inventory), REQUIRED)
        with self.assertRaisesRegex(ValueError, "missing"):
            check_registered({"tests": inventory["tests"][:-1]})
        inventory["tests"][0]["properties"] = [{"name": "DISABLED", "value": True}]
        with self.assertRaisesRegex(ValueError, "disabled"):
            check_registered(inventory)

    def test_skipped_failed_missing_and_duplicate_results_fail(self):
        root = ET.fromstring('<testsuite><testcase name="a" status="run"/></testsuite>')
        check_results(root, {"a"})
        with self.assertRaises(ValueError):
            check_results(root, {"a", "b"})
        for tag in ("skipped", "failure", "error"):
            child = ET.SubElement(root[0], tag)
            with self.assertRaisesRegex(ValueError, "failed or skipped"):
                check_results(root, {"a"})
            root[0].remove(child)
        ET.SubElement(root, "testcase", {"name": "a"})
        with self.assertRaises(ValueError):
            check_results(root, {"a"})

    def test_actual_ctest_skip_cannot_be_reported_as_success(self):
        output = Path.cwd() / "build/tests/vector"
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ctest-results-", dir=output) as temporary:
            folder = Path(temporary).resolve()
            executable = json.dumps(sys.executable)
            (folder / "CTestTestfile.cmake").write_text(
                'add_test(passed ' + executable + ' "-c" "pass")\n'
                'add_test(skipped ' + executable + ' "-c" "import sys; sys.exit(77)")\n'
                'set_tests_properties(skipped PROPERTIES SKIP_RETURN_CODE 77)\n')
            result = subprocess.run(["ctest", "--test-dir", str(folder),
                                     "--output-junit", str(folder / "result.xml")],
                                    capture_output=True, text=True)
            # CTest itself considers the successful test plus a skip an exit0.
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with self.assertRaisesRegex(ValueError, "failed or skipped: skipped"):
                check_results(ET.parse(folder / "result.xml").getroot(), {"passed", "skipped"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
