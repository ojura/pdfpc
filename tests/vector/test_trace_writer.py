#!/usr/bin/env python3
"""Check the production trace writer's JSON, precision, locale and reuse behavior."""

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError(f"Duplicate JSON member: {name!r}")
        result[name] = value
    return result


def reject_constant(value):
    raise ValueError(f"Non-JSON numeric constant: {value}")


def decode_lines(text):
    if not text.endswith("\n"):
        raise AssertionError("The writer did not terminate its final JSON line")
    # U+2028 and U+2029 are valid JSON string characters, not JSONL separators.
    return [json.loads(line, object_pairs_hook=unique_object, parse_constant=reject_constant)
            for line in text[:-1].split("\n")]


def invoke(locale_name, *arguments):
    return subprocess.run([str(PROBE), locale_name, *arguments], capture_output=True,
                          text=True, encoding="utf-8", timeout=10,
                          env={**os.environ, "LC_ALL": locale_name, "G_DEBUG": "fatal-criticals"})


class TraceWriterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = invoke("C")
        if result.returncode:
            raise AssertionError(result.stderr)
        cls.text = result.stdout
        cls.records = decode_lines(cls.text)
        if len(cls.records) != 133:
            raise AssertionError(f"Expected 133 records, got {len(cls.records)}")

    def test_strings_controls_utf8_and_null(self):
        value = self.records[0]
        self.assertEqual(value, {
            "event": 'quote " slash \\ newline\n ž中🙂', "clock_us": 2**63 - 1,
            "controls": "".join(map(chr, range(1, 32))),
            'key"\\\nž': 'value"\\\t\r\n',
            "unicode": "ž中🙂\u2028\u2029", "empty": "", "missing": None,
            "literal_null": "null", "yes": True, "no": False,
        })
        self.assertIn("ž中🙂", self.text)
        self.assertIs(value["yes"], True)
        self.assertIs(value["no"], False)
        first_line = self.text.split("\n", 1)[0]
        self.assertFalse(any(ord(character) < 32 for character in first_line))

    def test_integer_extrema_and_finite_double_round_trip(self):
        value = self.records[1]
        self.assertEqual(value["minimum_int"], -(2**63))
        self.assertEqual(value["maximum_int"], 2**63 - 1)
        self.assertEqual(value["beyond_double_integer"], 2**53 + 1)
        expected = {
            "decimal": 1.5, "fraction": 0.1,
            "maximum_double": sys.float_info.max,
            "minimum_normal": sys.float_info.min,
            "minimum_subnormal": float.fromhex("0x0.0000000000001p-1022"),
            "negative_maximum": -sys.float_info.max,
        }
        for name, number in expected.items():
            with self.subTest(name=name):
                self.assertTrue(math.isfinite(value[name]))
                self.assertEqual(value[name], number)
        numbers = json.loads(self.text.split("\n")[1], parse_int=float)
        self.assertEqual(math.copysign(1, numbers["positive_zero"]), 1)
        self.assertEqual(math.copysign(1, numbers["negative_zero"]), -1)

    def test_nonfinite_numbers_are_json_null(self):
        for name in ("not_a_number", "positive_infinity", "negative_infinity"):
            self.assertIsNone(self.records[1][name])

    def test_completion_order_unavailable_and_expired(self):
        self.assertEqual(self.records[2], {
            "event": "timing", "clock_us": 1234567890123456, "frame_clock_id": 2,
            "completed_timings": [
                {"counter": 2**53 + 1, "presentation_time_us": 2**63 - 1, "expired": False},
                {"counter": 8, "presentation_time_us": 0, "expired": False},
                {"counter": 9, "presentation_time_us": 0, "expired": True},
            ],
            "feedback_collected_us": 2**63 - 1,
        })

    def test_growth_reset_and_repeated_empty_arrays(self):
        self.assertEqual(self.records[3], {
            "event": "long", "clock_us": 3, "text": 'ž中🙂"\\\n' * 8192,
        })
        self.assertEqual(self.records[4], {
            "event": "empty-array", "clock_us": 4, "completed_timings": [],
        })
        for index, value in enumerate(self.records[5:]):
            expected_timings = [] if index % 2 == 0 else [{
                "counter": index, "presentation_time_us": index*1000, "expired": False,
            }]
            self.assertEqual(value, {
                "event": "reused", "clock_us": index, "index": index,
                "text": "" if index % 2 == 0 else "short",
                "completed_timings": expected_timings,
            })

    def test_non_c_numeric_locale(self):
        if not shutil.which("locale"):
            self.skipTest("The system locale inventory command is unavailable")
        result = subprocess.run(["locale", "-a"], capture_output=True, text=True, check=True)
        names = result.stdout.splitlines()
        preferred = ("hr_", "de_", "fr_", "it_", "es_", "pt_", "en_DK")
        names.sort(key=lambda name: (not name.startswith(preferred), name))
        for name in names:
            if name in {"C", "POSIX"} or name.lower().startswith("c."):
                continue
            sample = invoke(name, "--locale-only")
            if sample.returncode == 0 and "numeric-sample:1,5" in sample.stderr:
                localized = invoke(name)
                self.assertEqual(localized.returncode, 0, localized.stderr)
                self.assertEqual(decode_lines(localized.stdout), self.records)
                self.assertEqual(localized.stdout, self.text)
                print(f"Comma-decimal locale checked: {name}")
                return
        self.skipTest("No installed locale uses a comma decimal separator")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("probe", type=Path)
    options = parser.parse_args()
    PROBE = options.probe.resolve()
    unittest.main(argv=[sys.argv[0]], verbosity=2)
