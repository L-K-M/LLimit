# Dashboard/widget integration

## Sources

Immutable inputs: `refs/remotes/pr-review/<number>`. Features were grafted;
source branches were not merged into this batch.

| Source | Head | Integrated behavior |
| --- | --- | --- |
| #53 | `6448b85` | Normalized palette matching, picker, validated hues |
| #54 | `2b689ac` | Current account names, ordered errors, +N summary |
| #55 | `1cdc1ed` | Distinct glyphs and OpenCode name |
| #56 | `81e5f11` | Four-state account status, AX labels/reorder actions |
| #58 | `65df48f` | Weather only; unknown/stale/estimated are explicit |
| #59 | `c698e9e` | Best-account presentation on shared ranking |
| #67 | `d76dabe` | Limiting captions, matching values, full reset AX |
| #72 | `ef6fcd9` | Truthful storage/account/quota states |
| #73 | `7b124c1` | Actual light/dark surfaces, text and controls |
| #80 | `7cb3c1b` | Flexible small rows, spoken values, scheduled freshness |
| #95 | `eacfbdb` | Balanced caption-sized cells and shared ages/text |
| #96 | `dad9a2f` | Settings-order identity bars, failure/stale cues |
| #106 | `e83920e` | Opt-in Carbon shortcut, shared model, focus restoration |

Dependencies: storage `f0c8546`, CLI `9f8c1d2`, main `eeb2b8b`.
`QuotaFreshness` and `HeadroomRanking` come from the CLI dependency.
`StatusRenderer.relativeAge` forwards to `QuotaDisplayText`, retaining its
existing CLI consumers. History/trend and provider pace integration remain
separate dependencies of the parent integration.

## Automated checks

```sh
swift test --package-path Packages/QuotaCore --swift-sdk local-debian --jobs 2
swift test --package-path Packages/LLimitd --swift-sdk local-debian --jobs 2
python3 scripts/validate-palettes.py
python3 -m unittest scripts/tests/test_palette_validation.py
bash scripts/test-panel-geometry.sh
```

The geometry harness needs `swiftc` on PATH and the host's Swift SDK environment.
Swift frontend parsing covers the changed app/widget files on Linux; it does
not type-check SwiftUI, AppKit, Carbon or WidgetKit.

Regression failures were observed before fixes: stale-source/unknown-window
recommendations, unknown/unlimited and aggregate-only menu bars, missing dated
freshness entries, redundant entries, undersized captions, and out-of-range ages.

## Palette evidence

D65 CIELAB ΔE76, Machado severity-1 protan/deutan/tritan matrices in linear sRGB,
OKLCH chroma, WCAG contrast. Minimum across normal/CVD base and deep colors:

| Palette | Base ΔE | Base+deep ΔE | OKLCH chroma | Graphite contrast |
| --- | ---: | ---: | ---: | ---: |
| Standard | 12.84 | 8.82 | .112 | 3.08 |
| Ocean | 12.31 | 8.34 | .101 | 3.04 |
| Sunset | 12.45 | 8.20 | .102 | 3.03 |
| Forest | 12.35 | 8.22 | .101 | 3.06 |
| Vivid | 12.23 | 8.18 | .109 | 3.03 |

Standard and the deep/pale formulas are unchanged. Original themed palettes
failed CVD and deep contrast; hues were adjusted against those measured gates.
The validator reads the Swift literals and checks the production deep formula.

Raw identity contrast on `#5994F2` is approximately 1.00–1.15 at its minimum,
below 3:1. Dashboard marks use graphite backing/casing, whose contrast on blue
is 5.43:1. This is not a claim that raw hues pass blue contrast. Composite
provider/trend/widget rendering still needs native visual verification.
Light/dark dashboard text and status colors clear 4.5:1 on their defined surfaces.

## Native verification gaps

Run the macOS CI build on the parent integration. No native runtime or screenshots
were available on Linux. Check these offline fixtures on macOS:

- Small/medium widgets: 4/12 accounts, long names, dual estimates, hidden values,
  unknown/unlimited/balances, partial/all failures, obsolete failures, +N names.
- Remove/disable/rename accounts and test ambiguous legacy provider IDs.
  Corrupt shared files: show storage unavailable without renaming those files.
- Advance dated widget entries beyond the requested reload: badges and spoken
  freshness change without an app refresh; old percentages never imply refill.
- Dropdown/floating dashboard at 360/390/420/700pt: balanced rows, readable
  captions, same limiting gauge/caption, complete reset tooltip/VoiceOver,
  click-to-scroll, and system appearance changes while open.
- Settings VoiceOver: every hidden control is named; all four account states
  are spoken; boundary rows offer only actionable reorder commands.
- Menu bar: reordering changes bar order without changing account colors;
  current/failing/stale/unknown/zero states and native tooltip/AX delivery.
- Shortcut: default Off, preset persistence/collision errors, show/hide from
  another app, multiple screens, Settings focus, and no restoration after focus
  moves elsewhere. Foreign Carbon signature or ID must remain unhandled.

Widget kinds, twelve static slots and configuration types are preserved.
