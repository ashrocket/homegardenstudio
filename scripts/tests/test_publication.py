import contextlib
import importlib.util
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("privacy_scan", SCRIPTS / "privacy_scan.py")
scanner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scanner)


class PublicationChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hgs-publication-")
        self.root = Path(self.temp.name)
        self.git("init", "--quiet")
        # Construct only synthetic fixtures; never load real credentials.
        self.secret = "-".join(("sk", "proj", "X" * 48))

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args],
                              check=True, capture_output=True)

    def scan(self):
        return subprocess.run([sys.executable, str(SCRIPTS / "privacy_scan.py"),
                               "--root", str(self.root)], capture_output=True, text=True)

    def assert_redacted_match(self, result):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("rule=openai-key", result.stdout)
        self.assertNotIn(self.secret, result.stdout + result.stderr)

    def test_spaces_and_newlines_do_not_hide_secrets(self):
        for name in ("sample note.txt", "newline\nname.txt"):
            with self.subTest(name=name):
                path = self.root / name
                path.write_text(self.secret)
                self.assert_redacted_match(self.scan())
                path.unlink()

    def test_staged_secret_is_found_after_working_copy_is_cleaned(self):
        path = self.root / "staged.txt"
        path.write_text(self.secret)
        self.git("add", "staged.txt")
        path.write_text("clean working file")
        result = self.scan()
        self.assert_redacted_match(result)
        self.assertIn("source=index", result.stdout)

    def test_secret_in_filename_is_redacted(self):
        (self.root / (self.secret + ".txt")).write_text("ordinary content")
        result = self.scan()
        self.assert_redacted_match(result)
        self.assertIn("[redacted]", result.stdout)

    def test_private_rule_matches_without_echoing_the_value(self):
        private = self.root / ".coordination"
        private.mkdir()
        (self.root / ".gitignore").write_text(".coordination/\n")
        value = "private " + "fixture address"
        (private / "private-patterns.txt").write_text(value)
        (self.root / "notes.txt").write_text(value)
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn("private-rule-1", result.stdout)
        self.assertNotIn(value, result.stdout + result.stderr)

    def test_invalid_private_rule_fails_closed(self):
        private = self.root / ".coordination"
        private.mkdir()
        (private / "private-patterns.txt").write_text("[invalid")
        result = self.scan()
        self.assertEqual(result.returncode, 2)
        self.assertIn("Invalid private rule", result.stderr)
        self.assertNotIn("[invalid", result.stdout + result.stderr)

    def test_read_error_fails_closed(self):
        (self.root / "unreadable.txt").write_text("data")
        original = Path.open

        def open_file(path, *args, **kwargs):
            if path.name == "unreadable.txt":
                raise PermissionError("synthetic read failure")
            return original(path, *args, **kwargs)

        with patch.object(Path, "open", open_file), self.assertRaises(scanner.ScanError):
            scanner.scan(self.root)

    def test_uncommitted_files_are_scanned_and_symlinks_not_followed(self):
        with tempfile.TemporaryDirectory(prefix="hgs-external-") as other:
            external = Path(other) / "external.txt"
            external.write_text(self.secret)
            (self.root / "link.txt").symlink_to(external)
            self.assertEqual(self.scan().returncode, 0)
        (self.root / "new.txt").write_text(self.secret)
        self.assert_redacted_match(self.scan())

    def test_oversized_source_is_an_error_without_large_allocation(self):
        (self.root / "large.txt").write_text("123456789")
        with patch.object(scanner, "MAX_FILE_BYTES", 8), self.assertRaises(scanner.ScanError):
            scanner.scan(self.root)

    def test_clean_staged_and_working_source_passes(self):
        (self.root / "normal.txt").write_text("Synthetic garden plan")
        self.git("add", "normal.txt")
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 index/working entries", result.stdout)

    def test_full_verification_rejects_missing_components_before_running(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copyfile(SCRIPTS / "verify.sh", scripts / "verify.sh")
        result = subprocess.run(["bash", str(scripts / "verify.sh"), "full"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Missing required core component", result.stderr)
        self.assertIn("Missing required gateway component", result.stderr)
        self.assertIn("Missing required apple component", result.stderr)
        self.assertNotIn("Running", result.stdout)
        self.assertNotIn("Passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
