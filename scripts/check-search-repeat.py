#!/usr/bin/env python3
"""CLI integration check; pass the built codeinsight executable as argv[1]."""

import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import unittest


BINARY = str(Path(sys.argv.pop(1)).resolve())
FIXTURE = Path(__file__).resolve().parents[1] / "Tests/RustExtractorTests/Fixtures/use_alias"


class SearchRepeatTests(unittest.TestCase):
    def search(self, pattern, *options):
        return subprocess.run(
            [BINARY, "search", pattern, "--project", str(FIXTURE), "--json", *options],
            capture_output=True, text=True, check=False,
        )

    def test_repeating_preserves_one_json_result_and_reports_separate_timings(self):
        baseline = self.search("connect")
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        self.assertEqual(baseline.stderr, "")
        self.assertEqual(json.loads(baseline.stdout)["totalMatches"], 2)
        for count in (2, 3):
            with self.subTest(count=count):
                repeated = self.search("connect", "--repeat", str(count))
                self.assertEqual(repeated.returncode, 0, repeated.stderr)
                self.assertEqual(json.loads(repeated.stdout), json.loads(baseline.stdout))
                self.assertEqual(repeated.stderr.count("index ready_ms="), 1)
                runs = re.findall(
                    r"search run=(\d+) first_result_ms=([\d.]+) complete_ms=([\d.]+)",
                    repeated.stderr,
                )
                self.assertEqual([int(run[0]) for run in runs], list(range(1, count + 1)))
                for _, first, complete in runs:
                    self.assertGreaterEqual(float(complete), float(first))
                    self.assertGreaterEqual(float(first), 0)
                median = re.search(
                    r"search median first_result_ms=([\d.]+) complete_ms=([\d.]+)",
                    repeated.stderr,
                )
                self.assertIsNotNone(median)
                for column in (1, 2):
                    self.assertAlmostEqual(
                        float(median[column]), statistics.median(float(run[column]) for run in runs),
                    )

    def test_no_matches_has_no_first_result_time(self):
        result = self.search("cairn_missing_repeat_probe", "--repeat", "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["totalMatches"], 0)
        self.assertEqual(result.stderr.count("first_result_ms=none"), 3)

    def test_invalid_repeat_fails_before_indexing(self):
        for value in ("0", "-1", "bad"):
            with self.subTest(value=value):
                result = self.search("connect", "--repeat", value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("index ready_ms=", result.stderr)


if __name__ == "__main__":
    unittest.main()
