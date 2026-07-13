#!/usr/bin/env bash
# Reports the installed widget registration and recent LLimit-specific errors.
# This does not read LLimit settings, snapshots, account names, or credentials.
set -u

APP="/Applications/LLimit.app"
WIDGET="$APP/Contents/PlugIns/LLimitWidgetExtension.appex"
WIDGET_BINARY="$WIDGET/Contents/MacOS/LLimitWidgetExtension"
METADATA="$WIDGET/Contents/Resources/Metadata.appintents/extract.actionsdata"
WIDGET_BUNDLE_ID="ch.lkmc.llimit.app.widgetextension"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
LOG_WINDOW="${1:-5m}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'error: widget diagnostics require macOS\n' >&2
  exit 1
fi

if [[ ! -d "$WIDGET" ]]; then
  printf 'error: installed widget not found at %s\n' "$WIDGET" >&2
  exit 1
fi

section() {
  printf '\n== %s ==\n' "$1"
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || printf '<missing>'
}

section "System"
/usr/bin/sw_vers

section "Installed bundles"
printf 'App:    %s (%s)\n' \
  "$(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString)" \
  "$(plist_value "$APP/Contents/Info.plist" CFBundleVersion)"
printf 'Widget: %s (%s)\n' \
  "$(plist_value "$WIDGET/Contents/Info.plist" CFBundleShortVersionString)" \
  "$(plist_value "$WIDGET/Contents/Info.plist" CFBundleVersion)"
printf 'Path:   %s\n' "$WIDGET"

section "Signatures"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 || true
/usr/bin/codesign -d --entitlements :- "$WIDGET" 2>&1 || true

section "App Intent metadata"
if [[ -f "$METADATA" ]]; then
  printf 'Metadata: %s\n' "$METADATA"
  metadata_strings="$(/usr/bin/strings "$METADATA")"
  printf '%s\n' "$metadata_strings" \
    | /usr/bin/grep -E 'SelectProviderAccountIntent|ProviderAccountEntity|ProviderAccountQuery|provider-quota' \
    | /usr/bin/sort -u || true
  if ! printf '%s\n' "$metadata_strings" | /usr/bin/grep -Fq 'SelectProviderAccountIntent'; then
    printf 'ERROR: SelectProviderAccountIntent is absent from installed metadata\n'
  fi
else
  printf 'MISSING: %s\n' "$METADATA"
fi
if [[ ! -f "$WIDGET_BINARY" ]]; then
  printf 'MISSING: %s\n' "$WIDGET_BINARY"
elif ! /usr/bin/grep -aFq 'ch.lkmc.llimit.widget.provider-quota.v3' "$WIDGET_BINARY"; then
  printf 'ERROR: provider quota v3 widget kind is absent from the installed extension binary\n'
fi

section "PlugInKit registration"
/usr/bin/pluginkit -mAvvv -p com.apple.widgetkit-extension -i "$WIDGET_BUNDLE_ID" 2>&1 || true

section "Indexed app copies"
/usr/bin/mdfind "kMDItemCFBundleIdentifier == 'ch.lkmc.llimit.app'cd" 2>/dev/null || true
/usr/bin/mdfind "kMDItemCFBundleIdentifier == '$WIDGET_BUNDLE_ID'cd" 2>/dev/null || true

section "LaunchServices records"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -dump 2>/dev/null \
    | /usr/bin/grep -E -B 8 -A 24 'ch\.lkmc\.llimit|LLimitWidgetExtension' || true
fi

section "Recent widget configuration logs ($LOG_WINDOW)"
/usr/bin/log show --last "$LOG_WINDOW" --style compact --info --debug --predicate '
  (process == "LLimitWidgetExtension") OR
  (eventMessage CONTAINS[c] "ch.lkmc.llimit") OR
  (eventMessage CONTAINS[c] "LLimitWidgetExtension") OR
  (eventMessage CONTAINS[c] "ProviderQuota") OR
  (eventMessage CONTAINS[c] "provider-quota")
' 2>&1 || true

section "Live capture (manual)"
cat <<'EOF'
To catch the Edit-flow failure as it happens, run this in a second terminal,
then right-click the tile and choose Edit:

  log stream --info --debug --predicate '(process == "NotificationCenter") OR (process == "chronod") OR (process == "appintentsd") OR (subsystem CONTAINS[c] "chrono") OR (subsystem CONTAINS[c] "appintents") OR (eventMessage CONTAINS[c] "llimit")'

If Edit stays silent and produces no LLimit-related lines at all, suspect a
wedged per-user widget stack: `killall NotificationCenter chronod WidgetCenter`
and retest; verify in a fresh macOS user account before calling it an OS bug.
EOF
