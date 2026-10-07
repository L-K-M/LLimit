import pathlib
import shutil
import subprocess
import tempfile
import unittest
import importlib.util
import os
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("stamp_llimit_version", ROOT / "scripts/stamp-llimit-version.py")
STAMP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAMP)
CI_PACKAGE_VERSION = "0.0.0~ci"


class PackageVersionTests(unittest.TestCase):
    def test_stamp_accepts_ci_version_and_preserves_release_versions(self):
        source = 'public enum LLimitdInfo {\n  public static let version = "1.0.1"\n}\n'
        for version in [CI_PACKAGE_VERSION, "1.0.1", "2.3.4", "2.3.4-rc.1"]:
            self.assertEqual(STAMP.stamped(source, version), source.replace("1.0.1", version))
        with self.assertRaises(ValueError):
            STAMP.stamped(source, "0.0.0~unexpected")

    @unittest.skipUnless(shutil.which("dpkg-deb"), "dpkg-deb unavailable")
    def test_static_ci_stamps_before_build_and_packages_matching_version(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("  linux-static:\n", 1)[1].split("\n  tray-test:", 1)[0]
        version = re.search(r'^      VERSION:\s*"?([^"\s]+)"?\s*$', job, re.MULTILINE)
        self.assertIsNotNone(version, "Static CI needs one declared package version")
        self.assertEqual(version[1], CI_PACKAGE_VERSION)
        stamp = re.search(r'- name: Stamp llimit version\n\s+run: ([^\n]+)', job)
        build = re.search(r'- name: Build static llimit binary\n\s+run: ([^\n]+)', job)
        package = re.search(r'- name: Build \.deb\n\s+run: ([^\n]+)', job)
        self.assertIsNotNone(stamp, "Stamp the CI version before compiling")
        self.assertIsNotNone(build)
        self.assertIsNotNone(package)
        self.assertLess(stamp.start(), build.start())
        self.assertLess(build.start(), package.start())
        self.assertIn('"$VERSION"', package[1])
        self.assertIn('llimit_${VERSION}_amd64.deb', job)

        # Run the workflow's stamp/package commands on an isolated prebuilt fixture.
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "scripts").mkdir()
            shutil.copyfile(ROOT / "scripts/stamp-llimit-version.py", root / "scripts/stamp-llimit-version.py")
            core = root / "Packages/LLimitd/Sources/LLimitdCore"
            core.mkdir(parents=True)
            source = 'public enum LLimitdInfo {\n  public static let version = "1.0.1"\n}\n'
            (core / "Version.swift").write_text(source)
            environment = dict(os.environ, VERSION=version[1])
            stamped = subprocess.run(["bash", "-c", stamp[1]], cwd=root, env=environment,
                                     capture_output=True, text=True, timeout=15)
            self.assertEqual(stamped.returncode, 0, stamped.stderr)
            self.assertEqual((core / "Version.swift").read_text(), source.replace("1.0.1", CI_PACKAGE_VERSION))
            checked = subprocess.run([sys.executable, str(root / "scripts/stamp-llimit-version.py"), CI_PACKAGE_VERSION, "--check"],
                                     capture_output=True, text=True, timeout=15)
            self.assertEqual(checked.returncode, 0, checked.stderr)

            packaging = root / "Packages/LLimitd/packaging"
            packaging.mkdir()
            shutil.copyfile(ROOT / "Packages/LLimitd/packaging/build-deb.sh", packaging / "build-deb.sh")
            (packaging / "build-deb.sh").chmod(0o755)
            for name in ["systemd", "tray", "examples"]:
                shutil.copytree(ROOT / "Packages/LLimitd" / name, root / "Packages/LLimitd" / name)
            shutil.copyfile(ROOT / "Packages/LLimitd/README.md", root / "Packages/LLimitd/README.md")
            binary = root / "Packages/LLimitd/.build/x86_64-swift-linux-musl/release/llimit"
            binary.parent.mkdir(parents=True)
            binary.write_text(f'#!/bin/sh\nprintf "llimit {version[1]} (LLimitd, QuotaCore)\\n"\n')
            binary.chmod(0o755)
            packaged = subprocess.run(["bash", "-c", package[1]], cwd=root, env=environment,
                                      capture_output=True, text=True, timeout=15)
            self.assertEqual(packaged.returncode, 0, packaged.stderr)
            artifact = root / f"Packages/LLimitd/.build/llimit_{CI_PACKAGE_VERSION}_amd64.deb"
            result = subprocess.run(["dpkg-deb", "-f", str(artifact), "Version"], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), CI_PACKAGE_VERSION)

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
