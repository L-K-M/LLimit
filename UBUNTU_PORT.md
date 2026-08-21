# Porting LLimit to Ubuntu

An assessment of what it would take to run LLimit on Linux, and a phased plan.

**Bottom line:** `QuotaCore` already builds and passes all 97 tests on Ubuntu 24.04
with **zero source changes**. This isn't a port of the app — it's a new front end
for a core that is already portable.

---

## 1. What was verified

Not estimates. Swift 6.2.3 was installed in an Ubuntu 24.04.4 container,
`Packages/QuotaCore` was copied across untouched, and run:

```
$ swift build
Build complete! (9.58s)          # 0 errors, 0 warnings, 0 source changes

$ swift test
Executed 97 tests, with 0 failures (0 unexpected) in 0.185s

$ swift run probe                # live network + discovery check
HTTP OK   -> status 401, 141 bytes       # real TLS call to api.anthropic.com
DISCOVERY -> 2 credential(s)
  • anthropic: Claude Code (~/.claude)
  • zhipu: OpenCode (~/.local/share/opencode/auth.json)
```

Three things that could have sunk the port, and didn't:

- **Networking works.** `URLSession.data(for:)` is real on Linux Foundation — the 401
  proves TLS, headers and body all made the round trip to a live provider endpoint.
  And the whole HTTP surface is one protocol (`HTTPClient`) using exactly one method,
  so even if it hadn't, swapping transports is a ~30-line change.
- **Credential discovery is already Linux-native.** `CredentialDiscovery` reads
  `~/.claude`, `~/.codex`, `~/.config/github-copilot` and `~/.local/share/opencode` —
  the same XDG paths those tools use on Linux. Not a single `~/Library` in the package.
- **It was written portable on purpose.** Every client already carries
  `#if canImport(FoundationNetworking)`; `SnapshotStore` already guards its App Group
  initialiser behind `#if canImport(Darwin)`.

### The one language-level gap

`Combine` does not exist on Linux, so `AppModel`'s `ObservableObject` / `@Published`
pattern will not compile. Swift's `Observation` module **does** work on Linux
(verified). Converting the class to `@Observable` is a mechanical edit across
15 properties.

---

## 2. Inventory

| Component | Lines | Status |
| --- | ---: | --- |
| `Packages/QuotaCore` — sources | 4,275 | **Verified on Linux.** Moves verbatim. |
| `Packages/QuotaCore` — tests | 1,737 | **Verified on Linux.** 97/97 green. |
| `LLimitApp/WidgetStylePreset.swift` | 342 | Reuse. Imports only QuotaCore — no AppKit. |
| `LLimitApp/AppModel.swift` | 1,394 | Adapt. ~90% portable logic; 4 platform call sites. |
| `Shared/SharedConstants.swift` | 134 | Replace with ~30 lines of XDG paths. |
| `LLimitApp` — SwiftUI/AppKit shell | 2,589 | Rewrite. `MenuBarExtra`, `NSPanel`, 70 view bodies. |
| `LLimitWidgetExtension` | 2,349 | Rewrite. WidgetKit timelines, 33 view bodies. |

There are only ~28 genuine platform calls in the entire tree (`NSWindow`×5,
`SMAppService`×4, `NSApplication`×4, `SecItemCopyMatching`×2, `WidgetCenter`×1, …).
The bulk of the "macOS code" isn't API coupling at all — it's declarative SwiftUI view
bodies, which is a rewrite in any target toolkit. That's why the plan below defers all
of it.

---

## 3. The key insight: this is already a daemon plus a client

```
QuotaCoordinator  ──fetch──▶  provider APIs
        │
        └─ writes ─▶  quota-snapshot.json   (credentials redacted)
                             │
                             └─ read by ─▶  widgets / menu bar
```

The App Group container is just an agreed-upon directory. The snapshot JSON is already
a stable, versioned, credential-free IPC contract between a fetcher and one or more
renderers — the app is the only process that ever talks to a provider, and every
display surface is a read-only consumer of that file.

That is precisely the shape of a Linux status-bar integration. Waybar, polybar, eww and
Conky all work by running a command or reading a file on an interval. **The port's API
already exists.** Point it at `$XDG_DATA_HOME/LLimit/` and the contract holds unchanged.

---

## 4. Plan

Front-load everything that reuses verified code; defer everything that requires a
rewrite. Each phase ships something usable on its own.

### Phase 1 — extract `llimitd`, a headless SwiftPM executable

A new executable target next to QuotaCore that owns the settings file, the refresh timer
(already a plain `Task.sleep` loop, no AppKit involved), and the snapshot and history
stores. Reuses the verified core untouched.

- Write a Linux `SharedPaths`: `$XDG_CONFIG_HOME/LLimit/` for the mode-`600` settings
  file, `$XDG_DATA_HOME/LLimit/` for snapshot and history. Retires `SharedConstants`.
- Convert `AppModel`'s logic to `@Observable`, drop the Keychain branch (already
  `#if canImport(Security)`-guarded), replace `SMAppService` with
  `systemctl --user enable llimit.service`.
- Add a CLI for account management — `llimit accounts add|list|import` — reusing
  `AppSettings`, `CredentialField` and `CredentialDiscovery`. That's the entire
  Settings → Accounts feature without writing a single view.
- Ship a systemd user unit plus timer.

**Ships:** quota tracking on Linux, importing from Claude Code / Codex / Copilot /
OpenCode, with the same fetch logic and the same tests as macOS.

### Phase 2 — desktop integration, cheapest surface first

**Status: shipped** (branch `claude/ubuntu-port-phase2`), with two deviations from
the text below:

- `providerTileSlotCount` and slot-pinning were **kept**: they live in QuotaCore's
  `AppSettings` and the macOS widgets depend on them. The Linux side simply ignores
  slots — `StatusRenderer` emits every account and the bar config chooses.
- The SNI tray icon was assessed and cut; see "Tray icon: assessed, not built" in
  `Packages/LLimitd/README.md`. Bar modules are the supported display surface.

What shipped:

- **Status bar modules** — `Packages/LLimitd/examples/`: waybar (`custom` module +
  CSS for the emitted `ok`/`warning`/`critical`/`error`/`empty` classes), polybar
  (`custom/script` + jq renderer), and an eww `defpoll` widget. All consume
  `llimit status --json` and were verified running (headless sway + Xvfb).
- **Packaging** — fully static musl build (`--swift-sdk x86_64-swift-linux-musl`),
  `packaging/build-deb.sh` producing a `.deb` with the binary, systemd user units
  and examples, and a `release-linux` job in `release.yml` attaching it to tags.
- **Hardening from review** — flock-based settings locking (`SettingsLock`) across
  daemon and CLI read-modify-write, and a SIGTERM/SIGINT handler that cancels the
  daemon loop instead of cutting off an in-flight refresh.

Original text (for the record):

Don't reproduce WidgetKit. Map onto what Linux desktops actually offer:

- **Status bar modules** — a waybar or polybar `custom` module pointed at
  `llimit status --json`. Config, not code, and it covers most of what the desktop
  widgets do.
- **Tray icon** — the menu bar's true equivalent is a StatusNotifierItem (the
  SNI/AppIndicator protocol GNOME and KDE both speak), driven over D-Bus. Gives you the
  dropdown without a window toolkit.
- **Richer tiles** — eww widgets or a GNOME Shell extension, if the arc-and-ring
  rendering matters enough to rebuild.

**Ships:** at-a-glance quota in the panel, which is the app's core daily value.

### Phase 3 — a settings GUI, only if the CLI proves insufficient

By this point the daemon does the work and the panel shows it. A GUI is a convenience,
not a prerequisite, and the toolkit can be chosen on its merits.

---

## 5. If and when you want a GUI

The ~103 SwiftUI view bodies do not survive any of these paths. That's the real cost of
the port, and why Phase 3 is last.

| Route | Trade-off |
| --- | --- |
| **GTK4/libadwaita via Swift bindings** *(recommended if a GUI is required)* | One language throughout; settings UI links `QuotaCore` and `WidgetStylePreset` directly, no serialisation boundary. Bindings are community-maintained and less stable than SwiftUI. |
| **Separate front end in another language** | Tauri/Qt/GTK-Python over the same JSON files the widgets read. Mature toolkit, total decoupling. Costs a second language and build chain. |
| **Cross-platform rewrite (Electron/Flutter)** | Eventually unifies both platforms, but discards the verified portable Swift core and turns a scoped port into a full rebuild. Not recommended. |

---

## 6. Don't carry these across

| On macOS | Why it exists | On Linux |
| --- | --- | --- |
| 8 provider-tile slots | WidgetKit demands one compile-time widget *kind* per placeable tile, so the count can't be dynamic (see `AGENTS.md`). | No such limit. Emit every enabled account and let the bar config choose. ~~Drop `providerTileSlotCount` and slot-pinning.~~ **Correction (Phase 2):** kept — they live in QuotaCore's shared `AppSettings` and the macOS widgets read them; Linux just ignores them. |
| App Group container | The only directory a sandboxed widget extension may share with its host app. | No sandbox, no extension. A plain XDG directory does the job. |
| Keychain import for Claude | Claude Code stores its token in the macOS Keychain, hence the "Always Allow" prompt. | Nothing to port — Linux Claude Code writes `~/.claude/.credentials.json` directly, which `scanClaudeCode` already reads. Import is *simpler* here. |
| Signing, notarization, entitlements | Gatekeeper and the App Group entitlement chain. | Gone. `scripts/build.sh`, `RELEASING.md` and the signing half of CI have no Linux counterpart. |

**Worth adding on Linux:** credentials currently live in a mode-`600` JSON file — a
reasonable default matching macOS. But `libsecret` is available if LLimit's own tokens
should go in the desktop keyring, the inverse of the Keychain code being deleted.

---

## 7. Build and distribution

- **No Xcode, no XcodeGen.** The daemon is a plain SwiftPM package; `swift build` is the
  whole build. `project.yml` stays for the macOS targets only.
- **Add a Linux CI job.** A `swift-actions/setup-swift` step on `ubuntu-latest` running
  `swift test` in `Packages/QuotaCore` catches Linux regressions immediately — and it
  passes today, so it goes green from the first commit.
- **Package it.** Build with `--static-swift-stdlib` so users don't need a Swift runtime
  installed, then ship a `.deb` carrying the binary and the systemd unit.
- **Platform floor is fine.** `Package.swift` declares `platforms: [.macOS(.v14)]`. That
  doesn't block Linux — it only sets the macOS minimum — so it needs no change.

---

*Assessed against commit `bf20196`. Build, test, network and discovery results reproduced
in an Ubuntu 24.04.4 container with Swift 6.2.3; line counts measured from the working
tree.*
