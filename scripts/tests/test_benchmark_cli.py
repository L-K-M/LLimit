#!/usr/bin/env python3
"""Offline benchmark CLI integration tests. Pass a built llimit executable."""

import json
import os
from pathlib import Path
import shlex
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

    def test_models_returns_only_public_metadata_without_inference_or_accounts(self):
        fixture_catalog = {
            "id": "llimit-models", "type": "response", "command": "get_available_models",
            "success": True, "data": {"models": [{
                "provider": "fixture", "id": "offline-model", "name": "Offline model",
                "apiKey": "private-catalog-secret", "baseUrl": "https://private.invalid",
                "headers": {"Authorization": "private-catalog-secret"},
                "options": {"credential": "private-catalog-secret"},
            }]},
        }
        for harness in ("pi", "opencode"):
            with self.subTest(harness=harness):
                executable = self.root / ("fake-" + harness)
                if harness == "pi":
                    script = (
                        'test "$1" = --mode && test "$2" = rpc || exit 40\n'
                        'IFS= read -r request\n'
                        'test "$request" = \'{"id":"llimit-models","type":"get_available_models"}\' || exit 41\n'
                        "printf '%s\\n' " + shlex.quote(json.dumps(fixture_catalog)) + "\n"
                    )
                else:
                    script = (
                        'test "$#" = 2 && test "$1" = models && test "$2" = --pure || exit 42\n'
                        'test "$OPENCODE_DISABLE_MODELS_FETCH" = 1 || exit 43\n'
                        'test "$OPENCODE_DISABLE_AUTOUPDATE" = 1 || exit 44\n'
                        "printf '%s\\n' fixture/offline-model\n"
                    )
                executable.write_text("#!/bin/sh\nset -eu\n" + script)
                executable.chmod(0o700)
                result = self.cli("bench", "models", harness, "--executable", str(executable))
                models = json.loads(result.stdout)
                self.assertEqual(len(models), 1)
                self.assertEqual(set(models[0]), {"harness", "provider", "modelID", "displayName", "pluginPolicy"})
                self.assertEqual(models[0]["harness"], harness)
                self.assertEqual(models[0]["provider"], "fixture")
                self.assertEqual(models[0]["modelID"], "offline-model")
                self.assertEqual(models[0]["pluginPolicy"], "disabled")
                self.assertNotIn("private-catalog-secret", result.stdout + result.stderr)
                self.assertNotIn("private.invalid", result.stdout + result.stderr)
        self.assertFalse((self.root / "config").exists())
        self.assertFalse((self.root / "data").exists())

    def test_exclusive_account_confirmation_is_required(self):
        result = self.cli("bench", "run", str(self.write_plan(self.plan())), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--exclusive-accounts", result.stderr)
        self.assertFalse((self.root / "data").exists())

    def subscription_account(self):
        self.cli("accounts", "add", "--provider", "junie", "--name", "Offline account",
                 "--set", "junie.api_key=inert-offline-fixture")
        path = self.root / "config" / "LLimit" / "quota-settings.json"
        account = json.loads(path.read_text())["accounts"][0]
        return path, account

    def test_subscription_price_updates_preserve_credentials_and_allow_clearing(self):
        path, original = self.subscription_account()
        account_id = original["id"]
        self.cli("accounts", "update", account_id, "--subscription-cost", "240",
                 "--subscription-currency", "CHF", "--subscription-period", "yearly")
        account = json.loads(path.read_text())["accounts"][0]
        self.assertEqual(account["subscriptionPricing"],
                         {"amount": 240, "currency": "CHF", "billingPeriod": "yearly"})
        self.assertEqual(account["credentials"], original["credentials"])
        self.cli("accounts", "update", account_id, "--subscription-cost", "0",
                 "--name", "Free account")
        account = json.loads(path.read_text())["accounts"][0]
        self.assertEqual(account["subscriptionPricing"],
                         {"amount": 0, "currency": "CHF", "billingPeriod": "yearly"})
        self.assertEqual(account["displayName"], "Free account")
        self.cli("accounts", "update", account_id, "--subscription-currency", "USD")
        self.assertEqual(json.loads(path.read_text())["accounts"][0]["subscriptionPricing"]["currency"], "USD")
        self.cli("accounts", "update", account_id, "--subscription-cost", "off")
        account = json.loads(path.read_text())["accounts"][0]
        self.assertIsNone(account.get("subscriptionPricing"))
        self.assertEqual(account["credentials"], original["credentials"])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_invalid_subscription_prices_leave_settings_unchanged(self):
        path, account = self.subscription_account()
        original = path.read_bytes()
        for arguments in [
            ["--subscription-cost", "-1"], ["--subscription-cost", "nan"],
            ["--subscription-cost", "inf"], ["--subscription-cost", "10", "--subscription-currency", "usd"],
            ["--subscription-cost", "10", "--subscription-period", "weekly"],
            ["--subscription-currency", "USD"],
            ["--subscription-cost", "off", "--subscription-period", "monthly"],
        ]:
            with self.subTest(arguments=arguments):
                result = self.cli("accounts", "update", account["id"], "--name", "Must not save",
                                  *arguments, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(path.read_bytes(), original)

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
