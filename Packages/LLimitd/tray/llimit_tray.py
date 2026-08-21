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
from dataclasses import dataclass, field
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


@dataclass
class MenuRow:
    """One row of the popup.

    kind:
      header    account name + headline percent (bold, not clickable)
      metric    one limit under the account above it (not clickable)
      note      a status or error line (not clickable)
      separator a divider
      action    clickable; `action` names the handler
    """

    kind: str
    text: str = ""
    action: str = ""
    tooltip: str = ""


@dataclass
class TrayModel:
    label: str
    icon: str
    tooltip: str
    rows: list[MenuRow] = field(default_factory=list)


def format_metric(metric: dict[str, Any]) -> str:
    """One limit as a single line, e.g. 'Session — 62% left · resets in 3h 12m'."""
    label = metric.get("label") or metric.get("id") or "Limit"

    if metric.get("unlimited"):
        body = "unlimited"
    elif isinstance(metric.get("remainingPercent"), int):
        body = f"{metric['remainingPercent']}% left"
    elif metric.get("usageLine"):
        body = str(metric["usageLine"])
    else:
        body = "no data"

    reset = metric.get("resetIn")
    if reset and not metric.get("unlimited"):
        body = f"{body} · resets in {reset}"

    return f"{label} — {body}"


def format_account_header(account: dict[str, Any]) -> str:
    """Account name plus its headline (worst) percent, e.g. 'Claude — 8% left'."""
    name = account.get("name") or account.get("provider") or "Account"
    parts = [name]

    remaining = account.get("remainingPercent")
    if isinstance(remaining, int):
        parts.append(f"{remaining}% left")
    elif all(m.get("unlimited") for m in account.get("metrics") or [{}]):
        parts.append("unlimited")

    if account.get("stale"):
        parts.append("stale")

    return parts[0] if len(parts) == 1 else f"{parts[0]} — {' · '.join(parts[1:])}"


def build_menu_model(status: dict[str, Any] | None) -> TrayModel:
    """Turn one `llimit status --json` payload into the tray's label, icon and rows.

    Pure and total: a missing, malformed or empty payload still yields a usable
    menu, because the tray must keep working when the daemon is down.
    """
    if not isinstance(status, dict):
        return TrayModel(
            label="LLimit",
            icon=FALLBACK_ICON,
            tooltip="Could not read llimit status.",
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

    rows: list[MenuRow] = []

    # First tooltip line is the freshness stamp ("Updated 4m ago"); surface it as
    # the popup's first line so the user can tell stale data from live data.
    updated = tooltip.split("\n", 1)[0].strip() if tooltip else ""
    if updated:
        rows.append(MenuRow("note", updated))
        rows.append(MenuRow("separator"))

    if accounts:
        for index, account in enumerate(accounts):
            if index:
                rows.append(MenuRow("separator"))
            rows.append(MenuRow("header", format_account_header(account)))
            for metric in account.get("metrics") or []:
                rows.append(MenuRow("metric", format_metric(metric), tooltip=metric.get("detail") or ""))
            if not (account.get("metrics") or []):
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

    return TrayModel(
        label=status.get("text") or "LLimit",
        icon=ICON_FOR_CLASS.get(status_class, FALLBACK_ICON),
        tooltip=tooltip,
        rows=rows,
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

    gi.require_version("Gtk", "3.0")
    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3 as AppIndicator
    except (ValueError, ImportError):
        # Older distributions ship the pre-fork libappindicator instead.
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3 as AppIndicator

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

    def rebuild(model: TrayModel) -> None:
        for child in menu.get_children():
            menu.remove(child)

        for row in model.rows:
            if row.kind == "separator":
                item = Gtk.SeparatorMenuItem()
            elif row.kind == "action":
                item = Gtk.MenuItem(label=row.text)
                handler = handlers.get(row.action)
                if handler is not None:
                    item.connect("activate", handler)
            else:
                item = Gtk.MenuItem(label=row.text)
                item.set_sensitive(False)
                if row.kind == "header":
                    # Bold the account name so limits read as its children.
                    child = item.get_child()
                    if child is not None:
                        child.set_markup(f"<b>{GLib.markup_escape_text(row.text)}</b>")
                if row.tooltip:
                    item.set_tooltip_text(row.tooltip)
            item.show()
            menu.append(item)

        indicator.set_icon_full(model.icon, model.label or "LLimit")
        indicator.set_title(model.label or "LLimit")
        if args.show_label:
            indicator.set_label(model.label or "", "LLimit")

    def poll() -> bool:
        rebuild(build_menu_model(read_status(args.llimit)))
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
