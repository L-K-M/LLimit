# CLI consolidation sources

Integrated on `integrate/linux-cli-status`, from `origin/main` e73c0f6.
All source commits below are authored by Claude <noreply@anthropic.com>.
Their reviewed behavior and regression scenarios are retained or consolidated;
source branches remain untouched.

| PR | Source head | Retained contribution |
| --- | --- | --- |
| #104 | 17f970db34dbb60810232ea3f8e1573b12e640ea | Account transactions, update/rename/reimport, failed-load guards, primary-secret import matching |
| #108 | e0a63d769b4bff1fd2e9bc1664199bdd506cd72a | Check/pick parser, headroom ranking, templates, account/window selection, examples |
| #105 | 5e1dec28fb7c66e2179549ccd4319c40f2ca7270 | Honest failed/lastKnown rendering, elapsed carried windows, bounded errors, accessible tray updates |
| #50 | 48e88ebb87fc41b012b7e36136daabc167e6079d | Live reset dates/seconds, tray countdowns, interval-aware freshness |
| #51 | e4d60a5a5554cb9992f0b48c8026e62e06a5835d | Horizon-validated radar, deterministic order, no-data/empty distinction, failure caveats |
| #61 | 55493e5922703a8d5430072b168dd9524e9403fa | Radar amount/window context and additive status resets |
| #64 | 54ecf9459b46181214c2d0e7995581ef4c1cc53e | Named failed-only accounts, actionable failure priority, clean tooltip |
| #66 | 245c7cce84411a72396116973ddde25d341af26f | Snapshot-only subprocess proof and failed-load preservation |
| #83 | b0191a94d1fc97a48c4aa1ef5d3464428c1a883e | Version command and account quota summaries |
| #88 | bab9b99f709c2e0f645d3d1d9962dd6d6c86f711 | Compact balances, history-only CSV/JSON export, formula hardening |
| #97 | e51dfe428815b5271b3f53b620090623b4095ea7 | No-target whole-snapshot check |
| #99 | 9890e6a06e044b48afc833b1e6fd6d7dc87f604c | TTY redraw, bounded watch intervals, plain pipe/JSON frames |

## Integration decisions

- One display loader (`StatusReader`), renderer account view, classification,
  headroom ranker and reset detector. Provider/account keys are compound.
- Failure JSON is `failed`/`lastKnown`; no competing `failing` key.
- `QuotaFreshness` is public in QuotaCore. Optional snapshot cadence uses a
  60-minute floor and two intervals; legacy fallback is 2h. Explicit max age wins.
- Check/pick share exits 0/1/2/3/64. Whole-snapshot check uses failure/stale,
  no-data, low-quota priority and requires every account to pass.
- Replacing credentials clears cached usage for every provider. Publication
  validates the fetch's complete credential set against a fresh locked read.
  Snapshot/history publication shares that lock; provider requests never do.
- CSV export does not use the widget's history cap. Whitespace-masked formulas
  are neutralized. Radar uses #51's horizon rather than #61/#88's duplicate scans.
- `5e18` fits Int64. The overflow regression uses longer digit strings.
- Version starts at 1.0.1 and is stamped through the shared release hook and tag
  build. Packaging verifies the binary version before constructing a package.

## Cross-batch seams

- Storage foundations 1a6d685 are merged. Display/history export explicitly use
  `.preserve`; owned daemon bootstrap/refresh and history mutations use `.recover`.
  Account listing uses `ConfigurationAccess.inspect`, preserving snapshots and
  skipping reconciliation writes while retaining settings-load error guards.
  Private store sidecars serialize owner recovery and archive mutations; preserve
  reads stay lock-free. Corrupt/missing and FIFO process tests cover bytes,
  permissions and filenames. DisplayReadOnlyTests retains its process proof and
  expects the bounded malformed-snapshot stderr warning for status only; account
  listing remains silent. Both process cases preserve bytes and directory entries.
- Provider cancellation: skip publication only for a cancelled, empty result;
  preserve completed failures. Targeted retries pass the current snapshot back
  to the coordinator.
- Alerts: preserve `runDaemon(args)`, `DaemonAlertOptions`, `--notify`,
  `--on-event`, `--thresholds` and `LLIMIT_NOTIFY` when merging command dispatch.
  Account mutations in tests now throw and require `try`.
- History: add `runTrend` to dispatch later. Preserve cadence metadata in new
  snapshot transforms and history filtering.
- Display text: #95 may relocate `StatusRenderer.relativeAge` to
  `QuotaDisplayText`; keep all CLI callers wired to that shared implementation.
- Settings #86: publication validation must compare latest resolved runtime
  credentials, not stored `env:NAME` references. The settings batch owns that
  merge regression. Keep whole-credential merging, without per-key grant splicing.
