import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from datetime import datetime, timezone
from llimit_tray import (MenuRow, MenuUpdate, TrayModel, build_menu_model, format_account_header,
                        format_duration, format_metric, plan_menu_update)

NOW = datetime(2026, 10, 7, 12, 0, tzinfo=timezone.utc)


class StatusContractTests(unittest.TestCase):
    def test_absolute_reset_wins_over_frozen_text(self):
        metric = {"label": "Weekly", "remainingPercent": 50,
                  "resetAt": "2999-01-01T00:00:00Z", "resetIn": "99h"}
        self.assertNotIn("99h", format_metric(metric))

    def test_failed_account_header_and_error_row(self):
        account = {"name": "Claude Work", "failed": True, "lastKnown": True,
                   "stale": True, "remainingPercent": 8, "error": "token expired",
                   "metrics": [{"label": "Weekly", "remainingPercent": 8}]}
        self.assertEqual(format_account_header(account), "Claude Work — 8% left · failed")
        model = build_menu_model({"class": "error", "accounts": [account]})
        self.assertIn("Error: token expired", [row.text for row in model.rows])
        self.assertEqual([row.text for row in model.rows].count("Every account failed to refresh"), 1)

    def test_countdowns_match_quotacore_and_fallbacks(self):
        for seconds, expected in [(-5, "0m"), (59, "0m"), (60, "1m"), (3600, "1h"), (90061, "1d 1h 1m")]:
            self.assertEqual(format_duration(seconds), expected)
        metric = {"label": "Session", "remainingPercent": 62, "resetAt": "2026-10-07T13:30:00Z", "resetIn": "99h"}
        self.assertEqual(format_metric(metric, NOW), "Session — 62% left · resets in 1h 30m")
        metric["resetAt"] = "2026-10-07T11:59:00Z"
        self.assertEqual(format_metric(metric, NOW), "Session — 62% left · reset due")
        metric["resetAt"] = "invalid"
        metric["resetSeconds"] = 3600
        self.assertEqual(format_metric(metric, NOW), "Session — 62% left · resets in 1h")
        metric.pop("resetSeconds")
        metric["resetIn"] = " "
        self.assertEqual(format_metric(metric, NOW), "Session — 62% left")

    def test_cleared_failed_window_and_failure_only_account(self):
        metric = {"label": "Session", "resetAt": "2026-10-07T11:00:00Z"}
        self.assertEqual(format_metric(metric, NOW), "Session — reset since the last successful refresh")
        model = build_menu_model({"class": "error", "accounts": [{"name": "Work", "failed": True, "errorKind": "auth"}]}, NOW)
        self.assertIn("Error: auth", [row.text for row in model.rows])
        self.assertNotIn("No limits reported", [row.text for row in model.rows])
        self.assertIn("Every account failed to refresh", model.description)
        for row in model.rows:
            self.assertEqual(row.selectable, row.kind != "separator")

    def test_countdown_relabels_preserve_menu_layout(self):
        before = TrayModel("LLimit", "llimit-ok", "", [MenuRow("metric", "resets in 3h")])
        after = TrayModel("LLimit", "llimit-ok", "", [MenuRow("metric", "resets in 2h")])
        self.assertIs(plan_menu_update(None, before), MenuUpdate.REBUILD)
        self.assertIs(plan_menu_update(before, before), MenuUpdate.UNCHANGED)
        self.assertIs(plan_menu_update(before, after), MenuUpdate.RELABEL)
        after.rows.append(MenuRow("error", "offline"))
        self.assertIs(plan_menu_update(before, after), MenuUpdate.REBUILD)


if __name__ == "__main__":
    unittest.main()
