#!/usr/bin/env python3
"""Offline benchmark CLI integration tests. Pass a built llimit executable."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid


BINARY = Path(sys.argv.pop(1)).resolve() if __name__ == "__main__" and len(sys.argv) > 1 else None


@unittest.skipUnless(BINARY and BINARY.is_file(), "pass a built llimit executable")
class BenchmarkCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="llimit-bench-cli-")
        self.root = Path(self.temporary.name)
        self.environment = dict(os.environ, XDG_CONFIG_HOME=str(self.root / "config"),
                                XDG_DATA_HOME=str(self.root / "data"))
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.git("init", "-q")
        (self.repository / "fixture.txt").write_text("baseline")
        self.git("add", "fixture.txt")
        self.git("-c", "user.name=Benchmark Test", "-c", "user.email=benchmark@example.invalid",
                 "commit", "-qm", "Fixture")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.run(["/usr/bin/git", *arguments], cwd=self.repository,
                              env=self.environment, check=True, capture_output=True)

    def cli(self, *arguments, check=True):
        return subprocess.run([str(BINARY), *arguments], cwd=self.repository,
                              env=self.environment, check=check, capture_output=True,
                              text=True, timeout=45)

    def plan(self):
        plan = json.loads(self.cli("bench", "template").stdout)
        plan["repetitions"] = 2
        plan["timeoutSeconds"] = 5
        plan["taskPrompt"] = "Create solution.txt. Treat $(echo unsafe) as literal input."
        plan["rubric"] = "Create the requested file and preserve the baseline."
        plan["acceptanceCommand"] = 'test "$(cat solution.txt)" = generated'
        plan["candidates"] = [{
            "id": str(uuid.uuid4()), "name": "Offline candidate",
            "command": {"executable": "/bin/sh", "outputFormat": "text", "arguments": [
                "-c", 'cat >/dev/null; test "$(cat fixture.txt)" = baseline || exit 3; '
                'printf generated >solution.txt; printf "Task finished\\n"'
            ]}
        }]
        for judge in plan["judges"]:
            judge["command"] = {"executable": "/bin/sh", "outputFormat": "text", "arguments": [
                "-c", 'cat >/dev/null; printf \'{"accepted":true,"score":8,"explanation":"Fixture accepted"}\\n\''
            ]}
        return plan

    def write_plan(self, plan):
        path = self.root / "plan.json"
        path.write_text(json.dumps(plan))
        return path

    def test_template_is_valid_json_without_loading_accounts(self):
        plan = json.loads(self.cli("bench", "template").stdout)
        self.assertEqual(len(plan["candidates"]), 2)
        self.assertEqual(len(plan["judges"]), 2)
        self.assertTrue(all(Path(item["command"]["executable"]).is_absolute()
                            for item in plan["candidates"] + plan["judges"]))
        self.assertFalse((self.root / "config").exists())

    def test_exclusive_account_confirmation_is_required(self):
        result = self.cli("bench", "run", str(self.write_plan(self.plan())), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--exclusive-accounts", result.stderr)
        self.assertFalse((self.root / "data").exists())

    def test_offline_trials_preserve_repository_and_round_trip_reports(self):
        plan = self.plan()
        (self.repository / "fixture.txt").write_text("uncommitted edit")
        (self.repository / "untracked.txt").write_text("private untracked data")
        result = self.cli("bench", "run", str(self.write_plan(plan)), "--exclusive-accounts")
        report = json.loads(result.stdout)["report"]
        self.assertEqual(len(report["runs"]), 2)
        for run in report["runs"]:
            self.assertEqual(run["outcome"], "completed")
            self.assertTrue(run["acceptancePassed"])
            self.assertEqual(len(run["evaluations"]), 2)
            self.assertTrue(all(item["accepted"] for item in run["evaluations"]))
            self.assertIn("solution.txt", run["patch"])
        self.assertEqual((self.repository / "fixture.txt").read_text(), "uncommitted edit")
        self.assertFalse((self.repository / "solution.txt").exists())
        self.assertEqual((self.repository / "untracked.txt").read_text(), "private untracked data")
        history = json.loads(self.cli("bench", "list").stdout)
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["summaries"][0]["acceptedCount"], 2)
        shown = json.loads(self.cli("bench", "show", report["id"]).stdout)["report"]
        self.assertEqual(shown["id"], report["id"])
        directory = self.root / "data" / "LLimit" / "Benchmarks"
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((directory / (report["id"].lower() + ".json")).stat().st_mode & 0o777, 0o600)

    def test_invalid_plan_and_unknown_account_fail_before_execution(self):
        plan = self.plan()
        plan["repetitions"] = 0
        result = self.cli("bench", "run", str(self.write_plan(plan)), "--exclusive-accounts", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Repetitions", result.stderr)
        plan["repetitions"] = 1
        plan["candidates"][0]["accountID"] = "missing-account"
        result = self.cli("bench", "run", str(self.write_plan(plan)), "--exclusive-accounts", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("quota account", result.stderr)

    def test_timeout_is_preserved_as_failed_work(self):
        plan = self.plan()
        plan["repetitions"] = 1
        plan["timeoutSeconds"] = 1
        plan.pop("acceptanceCommand")
        plan["candidates"][0]["command"]["arguments"] = ["-c", "cat >/dev/null; sleep 10"]
        report = json.loads(self.cli("bench", "run", str(self.write_plan(plan)), "--exclusive-accounts").stdout)["report"]
        self.assertEqual(report["runs"][0]["outcome"], "timedOut")
        self.assertEqual(report["runs"][0]["evaluations"], [])
        history = json.loads(self.cli("bench", "list").stdout)
        self.assertEqual(history[0]["summaries"][0]["acceptedCount"], 0)


if __name__ == "__main__":
    unittest.main()
