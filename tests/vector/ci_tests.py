#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the Linux vector suite and fail if a required test is absent or skipped."""

import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET


REQUIRED = {
    "vector-renderer", "vector-example", "vector-transform", "vector-controller",
    "vector-transitions", "vector-trace-writer", "vector-trace-metrics",
    "vector-resources-native", "vector-resources-windows", "vector-gui",
    "vector-gui-future-clock",
}


def check_registered(inventory):
    tests = inventory.get("tests", [])
    names = [item["name"] for item in tests]
    missing = REQUIRED - set(names)
    duplicates = [name for name, count in Counter(names).items() if count > 1]
    disabled = [item["name"] for item in tests for prop in item.get("properties", [])
                if prop["name"] == "DISABLED" and prop["value"]]
    if missing or duplicates or disabled:
        raise ValueError("Incomplete CTest registration: missing=%s duplicate=%s disabled=%s" %
                         (sorted(missing), duplicates, disabled))
    return set(names)


def check_results(root, registered):
    cases = list(root.iter("testcase"))
    names = [item.attrib["name"] for item in cases]
    if Counter(names) != Counter(registered):
        raise ValueError("CTest results do not contain each registered test exactly once")
    unsuccessful = [item.attrib["name"] for item in cases
                    if item.attrib.get("status") in ("notrun", "disabled") or
                    any(child.tag in ("skipped", "failure", "error") for child in item)]
    if unsuccessful:
        raise ValueError("CTest failed or skipped: " + ", ".join(unsuccessful))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    build = args.build.resolve()
    command = ["ctest", "--test-dir", str(build)]
    inventory = json.loads(subprocess.check_output(command + ["--show-only=json-v1"], text=True))
    registered = check_registered(inventory)
    if args.check_only:
        print("All required vector tests are registered and enabled")
        return
    results = build / "Testing/vector-results.xml"
    results.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(command + ["--output-on-failure", "--output-junit", str(results)], check=True)
    check_results(ET.parse(results).getroot(), registered)
    print("All %d registered tests ran successfully; none skipped" % len(registered))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
