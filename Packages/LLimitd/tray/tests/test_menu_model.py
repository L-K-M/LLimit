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
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from llimit_tray import (  # noqa: E402
    FALLBACK_ICON,
    MenuRow,
    MenuUpdate,
    TrayModel,
    build_menu_model,
    format_account_header,
    format_metric,
    main,
    plan_menu_update,
)

NOW = datetime(2026, 10, 7, 12, 0, tzinfo=timezone.utc)


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

    def test_estimated_metric_marks_percentage_and_keeps_reset(self):
        text = format_metric({"label": "Daily DIEM", "remainingPercent": 50,
                              "estimated": True, "resetIn": "3h"})
        self.assertEqual(text, "Daily DIEM — ≈50% left (estimated) · resets in 3h")

    def test_estimate_flag_without_percentage_keeps_amount(self):
        text = format_metric({"label": "Daily DIEM", "usageLine": "0.00 DIEM", "estimated": True})
        self.assertEqual(text, "Daily DIEM — 0.00 DIEM")

    def test_unlimited_metric_never_shows_a_reset(self):
        text = format_metric({"label": "Plan", "unlimited": True, "resetIn": "3h"})
        self.assertEqual(text, "Plan — unlimited")

    def test_falls_back_to_usage_line_then_to_no_data(self):
        self.assertEqual(format_metric({"label": "Credits", "usageLine": "38 / 100"}), "Credits — 38 / 100")
        self.assertEqual(format_metric({"label": "Credits"}), "Credits — no data")

    def test_missing_label_falls_back_to_id(self):
        self.assertEqual(format_metric({"id": "weekly", "remainingPercent": 5}), "weekly — 5% left")

    def test_reset_is_counted_down_from_reset_at_rather_than_fetch_time_text(self):
        metric = {"label": "Session", "remainingPercent": 62, "resetIn": "3h 12m",
                  "resetAt": "2026-10-07T13:30:00Z"}
        self.assertEqual(format_metric(metric, NOW), "Session — 62% left · resets in 1h 30m")

    def test_long_countdowns_use_days(self):
        metric = {"label": "Weekly", "remainingPercent": 8, "resetAt": "2026-10-11T14:05:00Z"}
        self.assertEqual(format_metric(metric, NOW), "Weekly — 8% left · resets in 4d 2h 5m")

    def test_passed_reset_reads_as_due_instead_of_a_frozen_countdown(self):
        metric = {"label": "Session", "remainingPercent": 62, "resetIn": "10m",
                  "resetAt": "2026-10-07T11:59:00Z"}
        self.assertEqual(format_metric(metric, NOW), "Session — 62% left · reset due")

    def test_cleared_window_of_a_failed_account_says_it_reset(self):
        metric = {"label": "Session", "resetAt": "2026-10-07T11:00:00Z",
                  "detail": "Window reset since the last successful refresh"}
        self.assertEqual(format_metric(metric, NOW), "Session — reset since the last successful refresh")

    def test_invalid_reset_at_falls_back_to_reset_in(self):
        metric = {"label": "Session", "remainingPercent": 62, "resetIn": "3h", "resetAt": "soon"}
        self.assertEqual(format_metric(metric, NOW), "Session — 62% left · resets in 3h")


class FormatAccountHeaderTests(unittest.TestCase):
    def test_headline_percent_is_shown(self):
        self.assertEqual(format_account_header({"name": "Claude", "remainingPercent": 8}), "Claude — 8% left")

    def test_stale_accounts_are_marked(self):
        text = format_account_header({"name": "Claude", "remainingPercent": 8, "stale": True})
        self.assertEqual(text, "Claude — 8% left · stale")

    def test_estimated_headline_is_marked_alongside_stale(self):
        text = format_account_header({"name": "Venice", "remainingPercent": 50,
                                      "estimated": True, "stale": True})
        self.assertEqual(text, "Venice — ≈50% left (estimated) · stale")

    def test_failed_accounts_are_marked_failed_rather_than_stale(self):
        text = format_account_header({"name": "Claude Work", "remainingPercent": 8, "stale": True, "failed": True})
        self.assertEqual(text, "Claude Work — 8% left · failed")

    def test_failure_only_account_reads_as_failed(self):
        text = format_account_header({"name": "Claude Work", "remainingPercent": None, "metrics": [],
                                      "failed": True})
        self.assertEqual(text, "Claude Work — failed")

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

    def mixed(self):
        payload = self.sample()
        payload["class"] = "warning"
        payload["accounts"][0].update(failed=True, lastKnown=True, errorKind="auth", error="token expired")
        payload["accounts"].append({
            "id": "a3", "provider": "kimi", "name": "Kimi Work", "remainingPercent": None,
            "stale": False, "failed": True, "lastKnown": False, "errorKind": "network",
            "error": "offline", "metrics": [],
        })
        return payload

    def test_failed_account_with_data_shows_its_error_under_the_header(self):
        model = build_menu_model(self.mixed(), NOW)
        texts = [row.text for row in model.rows]
        header = texts.index("Claude — 8% left · failed")
        self.assertEqual(model.rows[header + 1].kind, "error")
        self.assertEqual(model.rows[header + 1].text, "Error: token expired")

    def test_failure_only_account_gets_a_header_and_error_but_no_empty_limits_row(self):
        model = build_menu_model(self.mixed(), NOW)
        self.assertIn("Kimi Work — failed", rows_of_kind(model, "header"))
        self.assertIn("Error: offline", rows_of_kind(model, "error"))
        self.assertNotIn("No limits reported", rows_of_kind(model, "metric"))

    def test_failure_count_follows_the_freshness_stamp(self):
        model = build_menu_model(self.mixed(), NOW)
        self.assertEqual([row.text for row in model.rows[:2]],
                         ["Updated just now", "2 of 3 accounts failed to refresh"])
        self.assertEqual(model.rows[2].kind, "separator")

    def test_every_account_failed_is_said_once(self):
        payload = self.mixed()
        payload["class"] = "error"
        payload["accounts"][1]["failed"] = True
        model = build_menu_model(payload, NOW)
        self.assertEqual(rows_of_kind(model, "note").count("Every account failed to refresh"), 1)
        self.assertEqual(model.icon, "llimit-error")

    def test_error_falls_back_to_its_kind(self):
        payload = self.sample()
        payload["accounts"][0].update(failed=True, errorKind="auth")
        self.assertIn("Error: auth", rows_of_kind(build_menu_model(payload, NOW), "error"))

    def test_icon_description_is_a_sentence_with_the_failure_count(self):
        model = build_menu_model(self.mixed(), NOW)
        self.assertEqual(model.description,
                         "LLimit: needs attention. 2 of 3 accounts failed to refresh. Claude 8% · Zhipu AI")

    def test_content_rows_are_selectable(self):
        model = build_menu_model(self.mixed(), NOW)
        for row in model.rows:
            self.assertEqual(row.selectable, row.kind != "separator", row)

    def test_accounts_are_separated_but_not_leading(self):
        model = build_menu_model(self.sample())
        self.assertNotEqual(model.rows[0].kind, "separator")
        # One divider between the two accounts, one before the action block.
        header_indexes = [i for i, row in enumerate(model.rows) if row.kind == "header"]
        self.assertEqual(model.rows[header_indexes[1] - 1].kind, "separator")


class PlanMenuUpdateTests(unittest.TestCase):
    """Rebuilding the whole menu can close it or reset keyboard focus, so polls
    that change nothing, or only text, must not rebuild."""

    def model(self, *rows):
        return TrayModel(label="LLimit", icon="llimit-ok", tooltip="", rows=list(rows))

    def test_first_model_builds_the_menu(self):
        self.assertIs(plan_menu_update(None, self.model(MenuRow("note", "a"))), MenuUpdate.REBUILD)

    def test_equal_models_change_nothing(self):
        rows = (MenuRow("header", "Claude — 8% left"), MenuRow("action", "Quit", action="quit"))
        self.assertIs(plan_menu_update(self.model(*rows), self.model(*rows)), MenuUpdate.UNCHANGED)

    def test_text_only_changes_relabel_in_place(self):
        before = self.model(MenuRow("metric", "Session — resets in 3h 12m"), MenuRow("separator"))
        after = self.model(MenuRow("metric", "Session — resets in 3h 11m"), MenuRow("separator"))
        self.assertIs(plan_menu_update(before, after), MenuUpdate.RELABEL)

    def test_layout_changes_rebuild(self):
        before = self.model(MenuRow("header", "Claude"), MenuRow("metric", "Session"))
        after = self.model(MenuRow("header", "Claude"), MenuRow("error", "Error: offline"), MenuRow("metric", "Session"))
        self.assertIs(plan_menu_update(before, after), MenuUpdate.REBUILD)


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
