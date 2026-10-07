import pathlib
import shutil
import subprocess
import tempfile
import unittest
import importlib.util

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("stamp_llimit_version", ROOT / "scripts/stamp-llimit-version.py")
STAMP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAMP)


class PackageVersionTests(unittest.TestCase):
    def test_stamp_updates_only_one_version_declaration(self):
        source = 'public enum LLimitdInfo {\n  public static let version = "1.0.1"\n}\n'
        self.assertEqual(STAMP.stamped(source, "2.3.4"), source.replace("1.0.1", "2.3.4"))
        with self.assertRaises(ValueError):
            STAMP.stamped(source, '"bad"')
        with self.assertRaises(ValueError):
            STAMP.stamped(source + source, "2.3.4")

    @unittest.skipUnless(shutil.which("dpkg-deb"), "dpkg-deb unavailable")
    def test_package_rejects_binary_with_another_version(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = pathlib.Path(directory) / "llimit"
            binary.write_text('#!/bin/sh\nprintf "llimit 1.0.1 (LLimitd, QuotaCore)\\n"\n')
            binary.chmod(0o755)
            result = subprocess.run(
                ["bash", str(ROOT / "Packages/LLimitd/packaging/build-deb.sh"), "9.9.9", str(binary), directory],
                capture_output=True, text=True, timeout=15,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("does not match", result.stderr)
            self.assertFalse(list(pathlib.Path(directory).glob("*.deb")))


if __name__ == "__main__":
    unittest.main()
