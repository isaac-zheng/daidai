"""Exercise bootstrap input validation and preservation of existing files without root."""

import pathlib
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("bootstrap.sh").resolve()


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.private = self.root / "key"
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.private)],
            check=True,
        )
        self.public = self.private.with_suffix(".pub")

    def call(self, function, *args):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; shift; "$@"', "test", str(SCRIPT), function, *map(str, args)],
            capture_output=True,
            text=True,
        )

    def test_help_and_invalid_mode(self):
        help_result = subprocess.run(["bash", str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(help_result.returncode, 0)
        result = subprocess.run(["bash", str(SCRIPT), "--install"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)

    def test_stdin_entry_used_by_ssh(self):
        result = subprocess.run(
            ["bash", "-s", "--", "--help"], input=SCRIPT.read_text(), capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage:", result.stdout)

    def test_valid_public_key(self):
        result = self.call("validate_key", self.public)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_private_key_is_rejected_without_printing_it(self):
        result = self.call("validate_key", self.private)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("BEGIN OPENSSH PRIVATE KEY", result.stderr + result.stdout)

    def test_missing_key_is_rejected(self):
        self.assertNotEqual(self.call("validate_key", self.root / "absent").returncode, 0)

    def test_multiple_keys_are_rejected(self):
        self.public.write_text(self.public.read_text() * 2)
        self.assertNotEqual(self.call("validate_key", self.public).returncode, 0)

    def test_malformed_key_is_rejected(self):
        self.public.write_text("ssh-ed25519 AAAA malformed\n")
        self.assertNotEqual(self.call("validate_key", self.public).returncode, 0)

    def test_authorized_keys_options_are_rejected(self):
        self.public.write_text('command="false" ' + self.public.read_text())
        self.assertNotEqual(self.call("validate_key", self.public).returncode, 0)

    def test_existing_keys_survive_and_repeat_add_is_idempotent(self):
        target = self.root / "authorized_keys"
        original = "# existing entry without final newline"
        target.write_text(original)
        for _ in range(2):
            result = self.call("add_public_key", self.public, target)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_text(), original + "\n" + self.public.read_text())

    def test_different_comment_does_not_duplicate_same_key(self):
        target = self.root / "authorized_keys"
        key_type, blob, _ = self.public.read_text().split(maxsplit=2)
        original = f"{key_type} {blob} a different comment\n"
        target.write_text(original)
        self.assertEqual(self.call("add_public_key", self.public, target).returncode, 0)
        self.assertEqual(target.read_text(), original)

    def test_missing_or_matching_config_is_accepted(self):
        path = self.root / "daemon.json"
        self.assertEqual(self.call("check_file", path, "{}").returncode, 0)
        self.assertFalse(path.exists())
        path.write_text("{}\n")
        self.assertEqual(self.call("check_file", path, "{}").returncode, 0)

    def test_conflicting_config_is_not_overwritten(self):
        path = self.root / "daemon.json"
        original = '{"log-driver":"json-file"}\n'
        path.write_text(original)
        self.assertNotEqual(self.call("check_file", path, "{}").returncode, 0)
        self.assertEqual(path.read_text(), original)

    def test_config_symlink_is_rejected(self):
        target = self.root / "target"
        target.write_text("{}\n")
        path = self.root / "daemon.json"
        path.symlink_to(target)
        self.assertNotEqual(self.call("check_file", path, "{}").returncode, 0)
        self.assertEqual(target.read_text(), "{}\n")


if __name__ == "__main__":
    unittest.main()
