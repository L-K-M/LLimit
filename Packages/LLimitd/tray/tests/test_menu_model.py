"""Tests for the tray's menu model.

`build_menu_model` is pure and GTK-free by design, so the interesting behavior —
including every degraded path the tray must survive — is testable without a
display, a session bus or a panel.

Run: python3 -m unittest discover -s Packages/LLimitd/tray/tests
"""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from llimit_tray import (  # noqa: E402
    FALLBACK_ICON,
    build_menu_model,
    format_account_header,
    format_metric,
    main,
)


def rows_of_kind(model, kind):
    return [row.text for row in model.rows if row.kind == kind]


def action_names(model):
    return [row.action for row in model.rows if row.kind == "action"]


class FormatMetricTests(unittest.TestCase):
    def test_bounded_metric_shows_percent_and_reset(self):
        text = format_metric({"label": "Session", "remainingPercent": 62, "resetIn": "3h 12m"})
        self.assertEqual(text, "Session — 62% left · resets in 3h 12m")

    def test_metric_without_reset_omits_the_clause(self):
        self.assertEqual(format_metric({"label": "Weekly", "remainingPercent": 8}), "Weekly — 8% left")

    def test_unlimited_metric_never_shows_a_reset(self):
        text = format_metric({"label": "Plan", "unlimited": True, "resetIn": "3h"})
        self.assertEqual(text, "Plan — unlimited")

    def test_falls_back_to_usage_line_then_to_no_data(self):
        self.assertEqual(format_metric({"label": "Credits", "usageLine": "38 / 100"}), "Credits — 38 / 100")
        self.assertEqual(format_metric({"label": "Credits"}), "Credits — no data")

    def test_missing_label_falls_back_to_id(self):
        self.assertEqual(format_metric({"id": "weekly", "remainingPercent": 5}), "weekly — 5% left")


class FormatAccountHeaderTests(unittest.TestCase):
    def test_headline_percent_is_shown(self):
        self.assertEqual(format_account_header({"name": "Claude", "remainingPercent": 8}), "Claude — 8% left")

    def test_stale_accounts_are_marked(self):
        text = format_account_header({"name": "Claude", "remainingPercent": 8, "stale": True})
        self.assertEqual(text, "Claude — 8% left · stale")

    def test_all_unlimited_account_reads_as_unlimited(self):
        text = format_account_header({"name": "Zhipu AI", "remainingPercent": None, "metrics": [{"unlimited": True}]})
        self.assertEqual(text, "Zhipu AI — unlimited")


class BuildMenuModelTests(unittest.TestCase):
    def sample(self):
        return {
            "class": "critical",
            "text": "Claude 8% · Zhipu AI",
            "tooltip": "Updated just now\nClaude: Session 62% left\nZhipu AI: Plan unlimited",
            "percentage": 8,
            "accounts": [
                {
                    "id": "a1",
                    "provider": "anthropic",
                    "name": "Claude",
                    "remainingPercent": 8,
                    "stale": False,
                    "metrics": [
                        {"id": "session", "label": "Session", "remainingPercent": 62, "resetIn": "3h 12m"},
                        {"id": "weekly", "label": "Weekly", "remainingPercent": 8, "resetIn": "4d 2h"},
                    ],
                },
                {
                    "id": "a2",
                    "provider": "zhipu",
                    "name": "Zhipu AI",
                    "remainingPercent": None,
                    "stale": False,
                    "metrics": [{"id": "plan", "label": "Plan", "unlimited": True}],
                },
            ],
        }

    def test_every_account_and_every_metric_gets_a_row(self):
        model = build_menu_model(self.sample())
        self.assertEqual(rows_of_kind(model, "header"), ["Claude — 8% left", "Zhipu AI — unlimited"])
        self.assertEqual(
            rows_of_kind(model, "metric"),
            [
                "Session — 62% left · resets in 3h 12m",
                "Weekly — 8% left · resets in 4d 2h",
                "Plan — unlimited",
            ],
        )

    def test_icon_and_label_follow_the_status_class(self):
        model = build_menu_model(self.sample())
        self.assertEqual(model.icon, "llimit-critical")
        self.assertEqual(model.label, "Claude 8% · Zhipu AI")

    def test_freshness_stamp_is_the_first_row(self):
        model = build_menu_model(self.sample())
        self.assertEqual(model.rows[0].text, "Updated just now")

    def test_actions_are_always_offered(self):
        for payload in (self.sample(), {"class": "empty", "accounts": []}, None, [], "nonsense"):
            self.assertEqual(action_names(build_menu_model(payload)), ["refresh", "quit"])

    def test_unknown_status_class_falls_back_to_a_known_icon(self):
        model = build_menu_model({"class": "banana", "accounts": []})
        self.assertEqual(model.icon, FALLBACK_ICON)

    def test_error_class_lists_the_per_account_errors(self):
        model = build_menu_model(
            {
                "class": "error",
                "text": "LLimit",
                "tooltip": "Updated 5m ago\nClaude: ERROR authentication failed (401)",
                "accounts": [],
            }
        )
        self.assertIn("Every account failed to refresh", rows_of_kind(model, "note"))
        self.assertIn("Claude: ERROR authentication failed (401)", rows_of_kind(model, "metric"))

    def test_empty_state_points_at_the_import_command(self):
        model = build_menu_model({"class": "empty", "accounts": [], "tooltip": ""})
        self.assertIn("No quota data yet", rows_of_kind(model, "note"))
        self.assertIn("Add an account: llimit accounts import", rows_of_kind(model, "metric"))

    def test_unreadable_status_still_yields_a_usable_menu(self):
        model = build_menu_model(None)
        self.assertEqual(model.icon, FALLBACK_ICON)
        self.assertIn("Could not read llimit status", rows_of_kind(model, "note"))

    def test_account_with_no_metrics_says_so(self):
        model = build_menu_model(
            {"class": "ok", "accounts": [{"name": "Copilot", "remainingPercent": 90, "metrics": []}]}
        )
        self.assertIn("No limits reported", rows_of_kind(model, "metric"))

    def test_accounts_are_separated_but_not_leading(self):
        model = build_menu_model(self.sample())
        self.assertNotEqual(model.rows[0].kind, "separator")
        # One divider between the two accounts, one before the action block.
        header_indexes = [i for i, row in enumerate(model.rows) if row.kind == "header"]
        self.assertEqual(model.rows[header_indexes[1] - 1].kind, "separator")


class IntervalValidationTests(unittest.TestCase):
    """A zero interval busy-loops GLib.timeout_add_seconds and a negative one
    wraps to an interval that never fires, so both are rejected up front."""

    def test_non_positive_intervals_are_rejected(self):
        for bad in ("0", "-1"):
            with self.subTest(interval=bad):
                with self.assertRaises(SystemExit) as caught:
                    main(["--print-menu", "--interval", bad])
                self.assertNotEqual(caught.exception.code, 0)

    def test_positive_interval_is_accepted(self):
        # --print-menu keeps this off the GTK path; llimit is absent here, so the
        # degraded menu is rendered and the command still succeeds.
        self.assertEqual(main(["--print-menu", "--interval", "1", "--llimit", "definitely-not-a-real-binary"]), 0)


if __name__ == "__main__":
    unittest.main()
