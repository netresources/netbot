#!/usr/bin/env python3
"""Private identifier terms for tests/check_anonymous.sh.

NETBOT_PRIVATE_TERMS is optional. When it is unset, the scanner warns on stderr
and runs the generic scan only. When it names a readable file, each non-blank
line that does not start with # is an extra case-insensitive identifier regex.
When it is set but missing or unreadable, the scanner warns and still runs the
generic scan.
These tests run the scanner against a temp directory.
Run: python3 tests/test_private_terms.py
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCAN = ROOT / "tests" / "check_anonymous.sh"
NEUTRAL = "acme" + "widget"
EMAIL = "someone@" + "realcompany" + ".com"
WORD = "(?<![A-Za-z0-9])" + NEUTRAL + "(?![A-Za-z0-9])"


class PrivateTerms(unittest.TestCase):
    def scan(self, root, terms_path=None):
        env = os.environ.copy()
        env.pop("NETBOT_PRIVATE_TERMS", None)
        if terms_path is not None:
            env["NETBOT_PRIVATE_TERMS"] = str(terms_path)
        return subprocess.run(
            ["bash", str(SCAN), str(root)],
            capture_output=True, text=True, env=env, cwd=str(ROOT),
        )

    def write_pkg(self, parent, text, name="pkg"):
        root = Path(parent) / name
        root.mkdir()
        (root / "notes.txt").write_text(text, encoding="utf-8")
        return root

    def test_unset_does_not_flag_neutral_term(self):
        with tempfile.TemporaryDirectory() as d:
            root = self.write_pkg(d, NEUTRAL + "\n")
            result = self.scan(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("FAIL IDENTITY", result.stdout)
        self.assertNotIn(NEUTRAL, result.stdout)
        self.assertNotIn("warning:", result.stdout)
        self.assertIn("NETBOT_PRIVATE_TERMS is unset", result.stderr)
        self.assertIn("generic scan only", result.stderr)

    def test_unset_warns_that_only_the_generic_scan_runs(self):
        with tempfile.TemporaryDirectory() as d:
            root = self.write_pkg(d, "plain notes\n")
            result = self.scan(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            result.stderr,
            "warning: NETBOT_PRIVATE_TERMS is unset; continuing with the generic scan only\n",
        )
        self.assertNotIn("warning:", result.stdout)
        self.assertNotIn("missing or unreadable", result.stderr)
        self.assertNotIn("FAIL", result.stdout)

    def test_terms_file_flags_planted_term_and_ignores_lookalikes(self):
        with tempfile.TemporaryDirectory() as d:
            terms = Path(d) / "terms.txt"
            terms.write_text("# fixture\n\n" + WORD + "\n", encoding="utf-8")
            os.chmod(terms, 0o600)
            hit = self.write_pkg(d, "made by " + NEUTRAL + "\n", name="hit")
            clean = self.write_pkg(d, NEUTRAL + "x hash a1" + NEUTRAL + "b\n", name="lookalike")
            flagged = self.scan(hit, terms)
            ignored = self.scan(clean, terms)
        self.assertNotEqual(flagged.returncode, 0, flagged.stdout + flagged.stderr)
        self.assertEqual(flagged.stdout.count("FAIL IDENTITY"), 1)
        self.assertIn(NEUTRAL, flagged.stdout)
        self.assertEqual(flagged.stderr, "")
        self.assertEqual(ignored.returncode, 0, ignored.stdout + ignored.stderr)
        self.assertNotIn("FAIL IDENTITY", ignored.stdout)
        self.assertEqual(ignored.stderr, "")

    def test_missing_terms_file_warns_and_generic_scan_still_flags_email(self):
        with tempfile.TemporaryDirectory() as d:
            root = self.write_pkg(d, NEUTRAL + "\n" + EMAIL + "\n")
            missing = Path(d) / "missing-terms.txt"
            self.assertFalse(missing.exists())
            generic = self.scan(root)
            warned = self.scan(root, missing)
        self.assertEqual(generic.returncode, warned.returncode)
        self.assertNotEqual(warned.returncode, 0)
        self.assertIn("EMAIL", warned.stdout)
        self.assertIn(EMAIL, warned.stdout)
        self.assertNotIn("FAIL IDENTITY", warned.stdout)
        self.assertIn("EMAIL", generic.stdout)
        self.assertIn("NETBOT_PRIVATE_TERMS is unset", generic.stderr)
        self.assertIn("generic scan only", generic.stderr)
        self.assertNotIn("missing or unreadable", generic.stderr)
        self.assertIn("NETBOT_PRIVATE_TERMS", warned.stderr)
        self.assertIn("missing or unreadable", warned.stderr)
        self.assertNotIn(NEUTRAL, warned.stderr)
        self.assertNotIn("warning:", warned.stdout)

    def test_unreadable_terms_file_warns_and_generic_scan_still_runs(self):
        if os.geteuid() == 0:
            self.skipTest("root can read a mode 000 file")
        with tempfile.TemporaryDirectory() as d:
            root = self.write_pkg(d, NEUTRAL + "\n" + EMAIL + "\n")
            terms = Path(d) / "terms.txt"
            terms.write_text(WORD + "\n", encoding="utf-8")
            os.chmod(terms, 0)
            try:
                warned = self.scan(root, terms)
            finally:
                os.chmod(terms, 0o600)
        self.assertNotEqual(warned.returncode, 0)
        self.assertIn("EMAIL", warned.stdout)
        self.assertIn(EMAIL, warned.stdout)
        self.assertNotIn("FAIL IDENTITY", warned.stdout)
        self.assertIn("missing or unreadable", warned.stderr)
        self.assertNotIn(NEUTRAL, warned.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
