"""Execute the real installer with isolated bundles, cache paths, and macOS tools."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WidgetInstallTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="llimit widget install ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.cache = self.root / "container/SystemData/com.apple.chrono"
        self.cache.mkdir(parents=True)
        (self.cache / "old.archive").write_text("old chart layout")
        self.neighbors = [self.root / "container/settings.json", self.root / "other-app/cache"]
        for path in self.neighbors:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("preserve")
        self.log = self.root / "restarts.log"
        app = self.root / "LLimit.app"
        widget = app / "Contents/PlugIns/LLimitWidgetExtension.appex"
        binary = widget / "Contents/MacOS/LLimitWidgetExtension"
        binary.parent.mkdir(parents=True)
        kinds = ["LLimit Dashboard", "ch.lkmc.llimit.widget.trend", "QuotaTrendChartWidget"]
        for slot in range(1, 13):
            kinds.extend([f"ch.lkmc.llimit.widget.provider-tile.slot{slot}", f"ProviderTileSlot{slot}Widget"])
        binary.write_text("\n".join(kinds))

        self.stub("lkm-build", 'test "$INSTALL_TEST_FAIL_BUILD" = 0')
        self.stub("lsregister", "exit 0")
        self.stub("pluginkit", "exit 0")
        self.stub("mdfind", "exit 0")
        self.stub("plutil", "echo 38")
        self.stub("codesign", '''
if [ "$INSTALL_TEST_FAIL_SIGNING" = 1 ]; then exit 25; fi
printf '%s\\n' 'com.apple.security.app-sandbox TE4M.group.ch.lkmc.llimit'
''')
        self.stub("killall", '''
if [ -e "$INSTALL_TEST_CACHE" ]; then state=present; else state=absent; fi
printf '%s cache=%s\\n' "$*" "$state" >> "$INSTALL_TEST_LOG"
''')
        self.stub("rm", '''
if [ "$INSTALL_TEST_FAIL_REMOVE" = 1 ]; then exit 23; fi
if [ "$INSTALL_TEST_BUSY_CACHE" = 1 ] && [ "$2" = "$INSTALL_TEST_CACHE" ]; then exit 23; fi
exec /bin/rm "$@"
''')
        self.stub("mv", '''
if [ "$INSTALL_TEST_FAIL_MOVE" = 1 ]; then exit 26; fi
exec /bin/mv "$@"
''')

        source = (ROOT / "scripts/build.sh").read_text()
        # Redirect the real installer before any registration or cache operation.
        # HOME is left intact; only this copied script receives fixture paths.
        overrides = {
            "LSREGISTER": self.tools / "lsregister",
            "PLUGINKIT": self.tools / "pluginkit",
            "INSTALLED_APP": app,
            "INSTALLED_WIDGET": widget,
            "CHRONO_DATA": self.cache,
        }
        marker = "DEREGISTERED=false\n"
        self.assertIn(marker, source)
        assignments = "".join(f"{key}={shlex.quote(str(value))}\n" for key, value in overrides.items())
        source = source.replace(marker, assignments + marker, 1)
        for tool in ["codesign", "plutil", "mdfind"]:
            source = source.replace(f"/usr/bin/{tool}", shlex.quote(str(self.tools / tool)))
        self.script = self.root / "build.sh"
        self.script.write_text(source)

    def stub(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def run_installer(self, *arguments, fail_build=False, fail_signing=False,
                      fail_remove=False, fail_move=False, busy_cache=False):
        environment = dict(os.environ)
        environment.update(
            PATH=str(self.tools) + os.pathsep + environment.get("PATH", ""),
            LKM_BUILD_BIN=str(self.tools / "lkm-build"),
            INSTALL_TEST_CACHE=str(self.cache),
            INSTALL_TEST_LOG=str(self.log),
            INSTALL_TEST_FAIL_BUILD=str(int(fail_build)),
            INSTALL_TEST_FAIL_SIGNING=str(int(fail_signing)),
            INSTALL_TEST_FAIL_REMOVE=str(int(fail_remove)),
            INSTALL_TEST_FAIL_MOVE=str(int(fail_move)),
            INSTALL_TEST_BUSY_CACHE=str(int(busy_cache)),
        )
        return subprocess.run(["bash", str(self.script), *arguments], cwd=self.root,
                              env=environment, capture_output=True, text=True, timeout=15)

    def test_success_invalidates_only_llimit_cache_before_restarting_hosts(self):
        result = self.run_installer("--install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.cache.exists(), "Successful installs must invalidate old widget archives")
        self.assertEqual(self.log.read_text().splitlines(), [
            "LLimitWidgetExtension cache=present",
            "chronod NotificationCenter cache=absent",
        ])
        for path in self.neighbors:
            self.assertEqual(path.read_text(), "preserve")

    def test_build_without_install_preserves_cache(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.cache / "old.archive").read_text(), "old chart layout")
        self.assertFalse(self.log.exists())

    def test_failed_build_preserves_cache(self):
        result = self.run_installer("--install", fail_build=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.cache / "old.archive").exists())
        self.assertNotIn("Registered ", result.stdout)

    def test_failed_signature_validation_preserves_cache(self):
        result = self.run_installer("--install", fail_signing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.cache / "old.archive").exists())
        self.assertNotIn("Registered ", result.stdout)

    def test_failed_cache_invalidation_is_not_reported_as_success(self):
        result = self.run_installer("--install", fail_move=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.cache / "old.archive").exists())
        self.assertNotIn("Registered ", result.stdout)

    def test_busy_live_cache_is_invalidated_by_rename(self):
        result = self.run_installer("--install", busy_cache=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.cache.exists())

    def test_retired_cache_cleanup_failure_warns_after_invalidation(self):
        result = self.run_installer("--install", fail_remove=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.cache.exists())
        self.assertIn("warn:", result.stderr)
        self.assertTrue(list(self.cache.parent.glob("com.apple.chrono.stale.*/archive/old.archive")))

    def test_missing_cache_is_already_fresh(self):
        (self.cache / "old.archive").unlink()
        self.cache.rmdir()
        result = self.run_installer("--install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("chronod NotificationCenter cache=absent", self.log.read_text())


if __name__ == "__main__":
    unittest.main()
