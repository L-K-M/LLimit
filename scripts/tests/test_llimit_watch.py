"""PTY watch proof. Set LLIMIT_TEST_BINARY to the built llimit executable."""
import datetime
import json
import os
import pathlib
import pty
import select
import subprocess
import tempfile
import time
import unittest

BINARY = os.environ.get("LLIMIT_TEST_BINARY")
WATCH_SECONDS = 1
DEADLINE_SECONDS = 5


@unittest.skipUnless(BINARY, "set LLIMIT_TEST_BINARY for PTY integration tests")
class WatchTerminalTests(unittest.TestCase):
    def run_watch(self, options, ready):
        with tempfile.TemporaryDirectory() as directory:
            data = pathlib.Path(directory) / "data" / "LLimit"
            data.mkdir(parents=True)
            stamp = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
            snapshot = {"version": 1, "generatedAt": stamp, "failures": [], "providers": [{
                "accountID": "fixture", "provider": "anthropic", "title": "Work",
                "fetchedAt": stamp, "metrics": [{"id": "weekly", "label": "Weekly",
                                                "remainingPercent": 62, "isUnlimited": False}],
            }]}
            snapshot_path = data / "quota-snapshot.json"
            snapshot_path.write_text(json.dumps(snapshot))
            before = snapshot_path.read_bytes()
            env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory + "/config",
                       XDG_DATA_HOME=directory + "/data", XDG_CACHE_HOME=directory + "/cache",
                       XDG_STATE_HOME=directory + "/state", TERM="xterm")
            master, slave = pty.openpty()
            process = subprocess.Popen([str(pathlib.Path(BINARY).resolve()), "status", "--watch", str(WATCH_SECONDS)] + options,
                                       stdout=slave, stderr=subprocess.PIPE, env=env)
            os.close(slave)
            output = b""
            try:
                deadline = time.monotonic() + DEADLINE_SECONDS
                while time.monotonic() < deadline and not ready(output):
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output += chunk
                self.assertTrue(ready(output), output.decode(errors="replace"))
                self.assertEqual(snapshot_path.read_bytes(), before)
                self.assertFalse((pathlib.Path(directory) / "config").exists())
            finally:
                if process.poll() is None:
                    process.terminate()
                _, error = process.communicate(timeout=DEADLINE_SECONDS)
                os.close(master)
            self.assertEqual(error, b"")
            return output

    def test_human_watch_redraws_on_real_tty(self):
        output = self.run_watch([], lambda output: b"\x1b[2A\x1b[J" in output)
        self.assertTrue(output.startswith(b"Updated "))
        self.assertNotIn(b"\x1b[2J", output)  # Scrollback stays intact.

    def test_json_watch_stays_ansi_free_even_on_tty(self):
        output = self.run_watch(["--json"], lambda output: output.count(b"\n") >= 2)
        self.assertNotIn(b"\x1b", output)
        for line in output.splitlines():
            self.assertEqual(json.loads(line)["percentage"], 62)


if __name__ == "__main__":
    unittest.main()
