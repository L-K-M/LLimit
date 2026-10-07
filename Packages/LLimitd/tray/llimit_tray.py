#!/usr/bin/env python3
"""LLimit tray icon — the Linux counterpart of the macOS menu-bar item.

Shows remaining quota in the system tray and, on click, a popup listing every
account and every limit within it. It is a *display surface only*: it shells
out to `llimit status --json` and never reads the settings file, so it never
touches credentials. Account management stays in the `llimit` CLI.

Why Python rather than Swift: the tray protocol is StatusNotifierItem over
D-Bus, and the popup is a second protocol (com.canonical.dbusmenu). Swift has
no D-Bus binding, so a native implementation means hand-marshalling both.
PyGObject wraps them already. See Packages/LLimitd/README.md.

The menu model (`build_menu_model`) is a pure function over the parsed JSON and
is unit-tested without GTK; everything below it is thin GTK wiring.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any

DEFAULT_POLL_SECONDS = 60
# `llimit status` only reads the snapshot file, so this is generous.
STATUS_TIMEOUT_SECONDS = 10

# Tray icon per status class, matching the names of the shipped SVGs and the
# ok/warning/critical/error/empty classes StatusRenderer emits.
ICON_FOR_CLASS = {
    "ok": "llimit-ok",
    "warning": "llimit-warning",
    "critical": "llimit-critical",
    "error": "llimit-error",
    "empty": "llimit-empty",
}
FALLBACK_ICON = "llimit-empty"

RESET_DUE = "reset due"

# Read out by screen readers for the tray icon, per status class.
STATUS_SENTENCES = {
    "ok": "LLimit: quota OK.",
    "warning": "LLimit: needs attention.",
    "critical": "LLimit: a quota is nearly used up.",
    "error": "LLimit: refresh failed.",
    "empty": "LLimit: no quota data yet.",
}


@dataclass
class MenuRow:
    """One row of the popup.

    kind:
      header    account name + headline percent (bold)
      metric    one limit under the account above it
      error     why the account above it failed to refresh
      note      a status line
      separator a divider
      action    clickable; `action` names the handler

    Content rows stay enabled, so keyboard and screen reader users can reach
    them; activating one does nothing.
    """

    kind: str
    text: str = ""
    action: str = ""
    tooltip: str = ""

    @property
    def selectable(self) -> bool:
        return self.kind != "separator"


@dataclass
class TrayModel:
    label: str
    icon: str
    tooltip: str
    rows: list[MenuRow] = field(default_factory=list)
    # The icon's accessible description: one sentence a screen reader can read out.
    description: str = ""


class MenuUpdate(Enum):
    """How the GTK menu follows a new model (see plan_menu_update)."""

    UNCHANGED = "unchanged"
    RELABEL = "relabel"
    REBUILD = "rebuild"


def plan_menu_update(previous: TrayModel | None, current: TrayModel) -> MenuUpdate:
    """Plans the menu rows only; the caller applies the icon, label and
    description on every update, whatever this returns.

    Rebuilding replaces every item, which can close an open menu or reset its
    keyboard focus. Countdowns change the text every minute, so a menu with the
    same row layout is relabeled in place instead."""
    if previous is None:
        return MenuUpdate.REBUILD
    if previous.rows == current.rows:
        return MenuUpdate.UNCHANGED
    if [(row.kind, row.action) for row in previous.rows] == [(row.kind, row.action) for row in current.rows]:
        return MenuUpdate.RELABEL
    return MenuUpdate.REBUILD


def format_duration(seconds: int) -> str:
    """Matches QuotaCore's formatShortDuration: days, hours and minutes, each only
    when non-zero, and '0m' when all are, e.g. '4d 2h 5m', '3h', '12m', '0m'."""
    seconds = max(0, seconds)
    days, hours, minutes = seconds // 86_400, (seconds % 86_400) // 3_600, (seconds % 3_600) // 60
    parts = [f"{value}{unit}" for value, unit in ((days, "d"), (hours, "h")) if value]
    if minutes or not parts:
        parts.append(f"{minutes}m")
    return " ".join(parts)


def parse_timestamp(value: Any) -> datetime | None:
    """An ISO 8601 timestamp from the status JSON, or None when absent or invalid."""
    if not isinstance(value, str):
        return None
    try:
        # Python before 3.11 does not accept the "Z" suffix.
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def aware_now(now: datetime | None) -> datetime:
    """`now` as an aware datetime. A naive value is taken as local time, which is
    what datetime.now() returns."""
    if now is None:
        return datetime.now(timezone.utc)
    return now if now.tzinfo is not None else now.astimezone()


def reset_clause(metric: dict[str, Any], now: datetime) -> str:
    """'resets in 3h 12m', counted down from `resetAt` so the popup stays right
    between snapshot reads, or 'reset due' once it has passed. Older payloads
    without `resetAt` fall back to the fetch-time `resetIn`."""
    reset_at = parse_timestamp(metric.get("resetAt"))
    if reset_at is not None:
        seconds = (reset_at - now).total_seconds()
        return f"resets in {format_duration(int(seconds))}" if seconds > 0 else RESET_DUE
    reset_in = metric.get("resetIn")
    return f"resets in {reset_in}" if reset_in else ""


def format_metric(metric: dict[str, Any], now: datetime | None = None) -> str:
    """One limit as a single line, e.g. 'Session — 62% left · resets in 3h 12m'."""
    label = metric.get("label") or metric.get("id") or "Limit"
    reset = "" if metric.get("unlimited") else reset_clause(metric, aware_now(now))

    if metric.get("unlimited"):
        body = "unlimited"
    elif isinstance(metric.get("remainingPercent"), int):
        prefix = "≈" if metric.get("estimated") is True else ""
        suffix = " (estimated)" if metric.get("estimated") is True else ""
        body = f"{prefix}{metric['remainingPercent']}% left{suffix}"
    elif metric.get("usageLine"):
        body = str(metric["usageLine"])
    elif reset == RESET_DUE:
        # A failing account's window reset after its last good reading.
        return f"{label} — reset since the last successful refresh"
    else:
        body = "no data"

    if reset:
        body = f"{body} · {reset}"

    return f"{label} — {body}"


def format_account_header(account: dict[str, Any]) -> str:
    """Account name plus its headline (worst) percent, e.g. 'Claude — 8% left'."""
    name = account.get("name") or account.get("provider") or "Account"
    parts = [name]

    remaining = account.get("remainingPercent")
    if isinstance(remaining, int):
        prefix = "≈" if account.get("estimated") is True else ""
        suffix = " (estimated)" if account.get("estimated") is True else ""
        parts.append(f"{prefix}{remaining}% left{suffix}")
    elif all(m.get("unlimited") for m in account.get("metrics") or [{}]):
        parts.append("unlimited")

    # A failed account's numbers are last known, so "failed" subsumes "stale".
    if account.get("failed"):
        parts.append("failed")
    elif account.get("stale"):
        parts.append("stale")

    return parts[0] if len(parts) == 1 else f"{parts[0]} — {' · '.join(parts[1:])}"


def format_account_error(account: dict[str, Any]) -> str:
    """Why a failed account's latest refresh failed. The renderer has already
    reduced the message to one short plain-text line."""
    return f"Error: {account.get('error') or account.get('errorKind') or 'refresh failed'}"


def failure_note(failed: int, total: int) -> str:
    if failed and failed >= total:
        return "Every account failed to refresh"
    return f"{failed} of {total} accounts failed to refresh"


def describe_status(status_class: str, label: str, failed: int, total: int) -> str:
    """The tray icon's accessible description, e.g. 'LLimit: needs attention.
    1 of 2 accounts failed to refresh. Claude 82%! · ChatGPT 45%'. It carries the
    same failure note as the menu."""
    sentences = [STATUS_SENTENCES.get(status_class, "LLimit.")]
    if failed:
        sentences.append(f"{failure_note(failed, total)}.")
    if label:
        sentences.append(label)
    return " ".join(sentences)


def build_menu_model(status: dict[str, Any] | None, now: datetime | None = None) -> TrayModel:
    """Turn one `llimit status --json` payload into the tray's label, icon and rows.

    Pure and total: a missing, malformed or empty payload still yields a usable
    menu, because the tray must keep working when the daemon is down.
    """
    if not isinstance(status, dict):
        return TrayModel(
            label="LLimit",
            icon=FALLBACK_ICON,
            tooltip="Could not read llimit status.",
            description="LLimit: could not read llimit status.",
            rows=[
                MenuRow("note", "Could not read llimit status"),
                MenuRow("note", "Is llimit installed and on PATH?"),
                MenuRow("separator"),
                MenuRow("action", "Refresh now", action="refresh"),
                MenuRow("action", "Quit", action="quit"),
            ],
        )

    status_class = status.get("class") or "empty"
    accounts = status.get("accounts") or []
    tooltip = status.get("tooltip") or ""
    failed = sum(1 for account in accounts if account.get("failed"))

    rows: list[MenuRow] = []

    # First tooltip line is the freshness stamp ("Updated 4m ago"); surface it as
    # the popup's first line so the user can tell stale data from live data.
    updated = tooltip.split("\n", 1)[0].strip() if tooltip else ""
    if updated:
        rows.append(MenuRow("note", updated))
    if failed:
        rows.append(MenuRow("note", failure_note(failed, len(accounts))))
    if updated or failed:
        rows.append(MenuRow("separator"))

    if accounts:
        for index, account in enumerate(accounts):
            if index:
                rows.append(MenuRow("separator"))
            rows.append(MenuRow("header", format_account_header(account)))
            if account.get("failed"):
                rows.append(MenuRow("error", format_account_error(account)))
            for metric in account.get("metrics") or []:
                rows.append(MenuRow("metric", format_metric(metric, now), tooltip=metric.get("detail") or ""))
            if not (account.get("metrics") or []) and not account.get("failed"):
                rows.append(MenuRow("metric", "No limits reported"))
    elif status_class == "error":
        rows.append(MenuRow("note", "Every account failed to refresh"))
        # The tooltip's remaining lines carry the per-account error text.
        for line in tooltip.split("\n")[1:]:
            if line.strip():
                rows.append(MenuRow("metric", line.strip()))
    else:
        rows.append(MenuRow("note", "No quota data yet"))
        rows.append(MenuRow("metric", "Add an account: llimit accounts import"))

    rows.append(MenuRow("separator"))
    rows.append(MenuRow("action", "Refresh now", action="refresh"))
    rows.append(MenuRow("action", "Quit", action="quit"))

    label = status.get("text") or "LLimit"
    return TrayModel(
        label=label,
        icon=ICON_FOR_CLASS.get(status_class, FALLBACK_ICON),
        tooltip=tooltip,
        rows=rows,
        description=describe_status(status_class, label, failed, len(accounts)),
    )


def read_status(llimit_binary: str = "llimit") -> dict[str, Any] | None:
    """Run `llimit status --json`. Returns None on any failure — the caller renders
    a degraded menu rather than crashing the tray."""
    if shutil.which(llimit_binary) is None and not os.path.isabs(llimit_binary):
        return None
    try:
        completed = subprocess.run(
            [llimit_binary, "status", "--json"],
            capture_output=True,
            text=True,
            timeout=STATUS_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0 or not completed.stdout.strip():
        return None
    try:
        parsed = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def trigger_refresh(llimit_binary: str = "llimit") -> None:
    """Fire `llimit refresh` without blocking the GTK main loop. The daemon holds
    the settings lock during its own refresh, so this can wait a few seconds; the
    tray picks the result up on its next poll either way."""
    try:
        subprocess.Popen(
            [llimit_binary, "refresh"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def _run_tray(args: argparse.Namespace) -> int:
    try:
        import gi
    except ImportError:
        # Most often this is not a missing package but the wrong interpreter: the
        # bindings are a distro package, so a pyenv/conda python3 cannot load the
        # compiled _gi built for the distro's minor version.
        print(
            "The tray needs PyGObject, which could not be imported.\n"
            "  Install it:  sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1\n"
            f"  Running as:  {sys.executable}\n"
            "  If that is not the system python, run the tray with /usr/bin/python3.\n"
            "  No GTK? `llimit status` and the bar modules need none.",
            file=sys.stderr,
        )
        return 1

    # The typelibs are Suggests, not Depends, so "gi imports but the indicator
    # is missing" is an expected state and must not surface as a traceback.
    try:
        gi.require_version("Gtk", "3.0")
        try:
            gi.require_version("AyatanaAppIndicator3", "0.1")
            from gi.repository import AyatanaAppIndicator3 as AppIndicator
        except (ValueError, ImportError):
            # Older distributions ship the pre-fork libappindicator instead.
            gi.require_version("AppIndicator3", "0.1")
            from gi.repository import AppIndicator3 as AppIndicator
    except (ValueError, ImportError):
        print(
            "The tray needs GTK and an AppIndicator library, which could not be loaded.\n"
            "  Install them: sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1\n"
            "  No GTK? `llimit status` and the bar modules need none.",
            file=sys.stderr,
        )
        return 1

    from gi.repository import GLib, Gtk

    icon_dir = args.icon_dir or os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")

    indicator = AppIndicator.Indicator.new(
        "llimit",
        FALLBACK_ICON,
        AppIndicator.IndicatorCategory.APPLICATION_STATUS,
    )
    if os.path.isdir(icon_dir):
        indicator.set_icon_theme_path(icon_dir)
    indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)

    menu = Gtk.Menu()
    indicator.set_menu(menu)

    def on_refresh(_item: Any) -> None:
        trigger_refresh(args.llimit)

    def on_quit(_item: Any) -> None:
        Gtk.main_quit()

    handlers = {"refresh": on_refresh, "quit": on_quit}
    # The items on screen, parallel to `shown.rows`, so a relabel can reach them.
    items: list[Any] = []
    shown: TrayModel | None = None

    def set_row_text(item: Any, row: MenuRow) -> None:
        if row.kind == "header":
            # Bold the account name so limits read as its children.
            child = item.get_child()
            if child is not None:
                child.set_markup(f"<b>{GLib.markup_escape_text(row.text)}</b>")
        else:
            item.set_label(row.text)
        item.set_tooltip_text(row.tooltip or None)

    def rebuild(model: TrayModel) -> None:
        nonlocal shown
        update = plan_menu_update(shown, model)

        if update is MenuUpdate.REBUILD:
            for child in menu.get_children():
                menu.remove(child)
            items.clear()

            for row in model.rows:
                if row.kind == "separator":
                    item = Gtk.SeparatorMenuItem()
                else:
                    # Content rows stay sensitive: insensitive items are skipped by
                    # keyboard navigation and screen readers.
                    item = Gtk.MenuItem(label=row.text)
                    set_row_text(item, row)
                    handler = handlers.get(row.action) if row.kind == "action" else None
                    if handler is not None:
                        item.connect("activate", handler)
                item.show()
                menu.append(item)
                items.append(item)
        elif update is MenuUpdate.RELABEL:
            for item, row in zip(items, model.rows):
                if row.selectable:
                    set_row_text(item, row)
        shown = model

        indicator.set_icon_full(model.icon, model.description or model.label or "LLimit")
        indicator.set_title(model.label or "LLimit")
        if args.show_label:
            indicator.set_label(model.label or "", "LLimit")

    # `llimit status` only reads the snapshot file, but it is still a subprocess:
    # running it on the GTK main loop would freeze the whole tray — menu, clicks
    # and Quit included — for as long as it takes, up to STATUS_TIMEOUT_SECONDS.
    # Read off-thread and marshal the result back with idle_add, which runs on
    # the main loop, so rebuild() is still only ever called from the main thread.
    poll_in_flight = threading.Event()

    def poll() -> bool:
        if poll_in_flight.is_set():
            # A previous read is still running (wedged `llimit`); skip this tick
            # rather than piling up subprocesses.
            return True

        poll_in_flight.set()

        def worker() -> None:
            # read_status swallows its own failures and build_menu_model is total,
            # so this should not raise — but a dead poll thread that never cleared
            # the flag would freeze updates permanently, so be explicit.
            try:
                model = build_menu_model(read_status(args.llimit))
            except Exception:  # noqa: BLE001 - keep polling whatever happens
                model = build_menu_model(None)
            finally:
                poll_in_flight.clear()
            GLib.idle_add(rebuild, model)

        threading.Thread(target=worker, daemon=True).start()
        return True  # keep the timeout registered

    poll()
    GLib.timeout_add_seconds(args.interval, poll)
    Gtk.main()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="LLimit tray icon")
    parser.add_argument("--llimit", default="llimit", help="path to the llimit binary")
    parser.add_argument(
        "--interval",
        type=int,
        default=DEFAULT_POLL_SECONDS,
        help="seconds between snapshot reads (default: %(default)s)",
    )
    parser.add_argument("--icon-dir", default="", help="directory holding the llimit-*.svg icons")
    parser.add_argument(
        "--show-label",
        action="store_true",
        help="show the quota text next to the icon (panel support varies)",
    )
    parser.add_argument(
        "--print-menu",
        action="store_true",
        help="print the menu the tray would show, then exit (no GTK needed)",
    )
    args = parser.parse_args(argv)
    # GLib.timeout_add_seconds(0) reschedules every main-loop iteration, and a
    # negative value wraps to a huge unsigned interval that never fires again.
    if args.interval < 1:
        parser.error("--interval must be a positive number of seconds")

    if args.print_menu:
        model = build_menu_model(read_status(args.llimit))
        print(f"icon:  {model.icon}")
        print(f"label: {model.label}")
        for row in model.rows:
            print("  ---" if row.kind == "separator" else f"  [{row.kind}] {row.text}")
        return 0

    return _run_tray(args)


if __name__ == "__main__":
    sys.exit(main())
