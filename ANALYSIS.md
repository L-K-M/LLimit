# LLimit project analysis and remaining work

This is the single living list of shovel-ready work for LLimit. Each open item gives
its evidence, a proposal, and tests or an acceptance condition, so it can be picked
up without rereading the source reviews. Implemented-but-unmerged work is not
repeated as a task: the Implementation ledger records it (this pass's open PRs, the
six MAIN-owned slices and the PRs MAIN reports), and the entry for a partly
implemented issue describes only what is left. Update this document as work lands
instead of starting another one.

**Date:** 2026-10-07. **Baseline:** origin/main `2d6ac1e`
(`2d6ac1e652ac33724961a5a8bf8f43f0f8d31d2f`, "Add twelve widget slots and a
resizable dropdown (#48)"). Line references are baseline starting points, not
guaranteed current offsets. Check them, and the ledger's implementation references,
before coding overlapping work.

**Sources consolidated.** Entries name their sources with three labels:

- **MAIN**: the `ANALYSIS.md` on origin/main before this merge. MAIN was
  consolidated on 2026-10-07 from the full pre-implementation review in its
  `tmp.md`, the earlier document at `756ce3c`, and fetched `origin/main:ANALYSIS.md`
  at `8b11179` (including `e2d5e02`, pass C at `54d423e`, and pass D). The #72 scope
  correction is preserved in commit `c1d0d19`. Its source reviews examined the same
  baseline: the macOS app, widgets, QuotaCore, the Linux CLI, daemon and tray,
  scripts, CI and release, and `BACKLOG.md`. Its `tmp.md` recorded four independent
  GPT-6.1 Sol reviews (a different file from TMP below), and the incoming main
  document recorded four review passes (A to D). MAIN's consolidation was
  documentation-only, not a new code or PR review. MAIN was published directly to
  main and kept its original review evidence so that its temporary `tmp.md` could
  be removed; that evidence is carried here (Evidence section, ledger table 2).
- **TMP**: the 2026-10-06 Opus 5.5 review of baseline `2d6ac1e`, with eleven area
  reviewers, two gap critics, adversarial verification of every finding, and an
  ideation pass on 2026-10-07. Its IDs are `R-<SECTION>-NN` for findings and
  `R-IDEA-NN` for ideas. Its `tmp.md` was deleted after this merge; every finding,
  idea and refuted claim in it is carried here, and the source ID index at the end
  maps each `R-*` ID to its entry.
- **LEDGER**: this pass's PR ledger: open PRs #89, #90, #92-#96 and #101-#110, what
  each implements, and the follow-ups each deferred. Its final update (2026-10-07)
  adds each PR's CI-green head after the last review round, what the review rounds
  changed, the measured pairwise merge conflicts and an integration check.
- **TRACKING**: this pass's local work-tracking notes (per-PR review rounds,
  applied and deferred findings, CI heads; not in the repository). Only LNX-01 and
  LNX-10 cite it, and the facts they use are written out in those entries.

This consolidation merged the three section by section. It is documentation-only:
it ran no tests and read no GitHub PR, review or CI state. Where a section writer
re-read code while merging, the entry says so ("Source check", "Worktree check").

**Path prefixes.** Other paths (`Shared/`, `scripts/`, `.github/`, `BACKLOG.md`,
`AGENTS.md`) are repository-relative. A bare file name or `:NN` refers to the file
last named in the same entry.

| Prefix | Path |
|---|---|
| `QC/` | `Packages/QuotaCore/Sources/QuotaCore/` (MAIN wrote `Core/`) |
| `QCT/` | `Packages/QuotaCore/Tests/QuotaCoreTests/` |
| `LD/` | `Packages/LLimitd/Sources/LLimitdCore/` (MAIN wrote `Linux/`) |
| `LDT/` | `Packages/LLimitd/Tests/LLimitdCoreTests/` |
| `CLI/` | `Packages/LLimitd/Sources/llimit/` |
| `TRAY/` | `Packages/LLimitd/tray/` |
| `EX/` | `Packages/LLimitd/examples/` |
| `SD/` | `Packages/LLimitd/systemd/` |
| `APP/` | `LLimitApp/` |
| `WX/` | `LLimitWidgetExtension/` |

**How to use the IDs.** Every item has a cluster ID whose prefix names its section:

| Prefix | Section | What an entry is |
|---|---|---|
| LED | Implementation ledger | an implemented issue, listed for traceability only |
| BND | Boundaries every follow-up must preserve | a standing constraint, not a task |
| COR | Correctness, privacy and persistence | open work |
| PRV | Providers, managed sign-in and account setup | open work |
| PRF | Performance, networking and scheduling | open work |
| MAC | macOS usability, visuals and accessibility | open work |
| WID | Widgets, trend chart, color identity and freshness | open work |
| LNX | Linux daemon, CLI and tray | open work |
| BLD | Build, release, packaging and documentation | open work |
| SEC | Security | open work |
| DEBT | Tech debt | open work |
| PRD | Product features, aesthetics and delight | proposal |
| IDEA | New ideas (ideation pass) | proposal |
| BKL | Stale BACKLOG.md entries | documentation edit |
| LES | Retained lessons | rule still in force |
| REF | Refuted claims and rejected ideas | do not re-propose without new evidence |
| ORD | Suggested follow-up order | sequencing step |

- **One home per issue.** An implemented issue appears only in the ledger. A
  partly implemented issue keeps its remaining work in one topical cluster, whose
  status names the PR that did the rest. BND and ORD entries also list source IDs,
  but they hold constraints and sequencing, not separate work.
- **Cite cluster IDs** in branches, commits and later edits. When an item lands,
  record it in the ledger and shrink or remove its entry; do not reuse the ID.
- **Source IDs** keep the evidence traceable; each entry's Sources line lists them.
  - TMP: findings `R-BUG`, `R-PERF`, `R-VIS`, `R-UX`, `R-A11Y`, `R-FEAT`, `R-THM`,
    `R-NOV`, `R-LNX`, `R-BLD`, `R-SEC`, `R-DEBT`, `R-BKL`, and ideas `R-IDEA`. Names
    in parentheses such as `CLIENT-2` or `AUTH-7` are TMP's original reviewer IDs
    (CORE, CLIENT, AUTH, APPMODEL, MENU, SETTINGS, WIDGET, LINUX, BUILD, PRODUCT,
    THEME, GAPA, GAPB). Refuted findings keep their reviewer ID (for example
    `CLIENT-7`), rejected sub-claims are `SUB-…`, and rejected ideas `RJ-IDEA-…`.
  - MAIN: `C01`-`C12` (correctness), `A01`-`A09` (providers), `F01`-`F12`
    (performance), `L01`-`L12` (Linux), `M01`-`M13` (macOS), `W01`-`W14` (widgets).
    `AM-<SECTION>-n` numbers MAIN's unnumbered bullets in order within one MAIN
    section: `AM-PROD` (product), `AM-BUILD` (build), `AM-LESSON` (retained
    lessons), `AM-ORDER` (follow-up order), `AM-MAC-NL` (native layout hypotheses),
    `AM-WID-VC` (widget visual and runtime checks). `BOUNDARY-1` to `-6` and
    `EVIDENCE-1` to `-7` number MAIN's boundary and evidence bullets.
  - PRs: #89, #90, #92-#96 and #101-#110 are this pass's (LEDGER); #66, #67, #69,
    #70, #72 and #75 are MAIN-owned; the other numbers from #50 to #100 are
    MAIN-reported and unverified. All are pull requests in the `L-K-M/LLimit`
    GitHub repository (`https://github.com/L-K-M/LLimit/pull/<number>`, the form
    MAIN linked).
- **To find the work for a source ID**, search for it, or use the source ID index
  at the end, which lists every TMP and MAIN ID with the clusters whose Sources line
  names it. Some cross-references inside entries cite a source ID (for example
  "R-BUG-22") instead of a cluster; the index resolves them.

**How to read an entry.** Topical entries use the same fields: Status / severity /
effort / platform, Sources, Problem and evidence, Proposal, Tests / acceptance, and
Relations. BND, LES, REF and ORD entries adapt them.

- **Status:** "open"; "partial" (a named PR implements the rest, and the entry lists
  only what remains); "implemented" appears only in the ledger. For BND and LES,
  "open" means the rule is in force.
- **Severity:** TMP's high/medium/low (defined in the Evidence section) or MAIN's
  rating; where they differ, both are given. "Proposal" marks product items;
  "unrated" or "not rated" means no source gave a severity.
- **Effort:** S (about a day in one area), M (one to three days, or several
  files), L (more than one PR). "(estimate)" marks an effort added while merging
  where no source gave one.
- **Platform:** "Linux-testable" means `swift test` in QuotaCore or LLimitd, or the
  tray's Python tests, can cover the fix; otherwise only the macOS CI build plus a
  manual check verifies it.
- **Provenance labels:** "Source check" marks a location re-read in the baseline
  checkout while merging. "Worktree check" marks a read of a local PR worktree,
  which may differ from the PR head. "Verified" in Security means rechecked against
  the baseline source. "Unverified" or "(unverified: why)" marks a claim nobody
  confirmed. "MAIN-reported" PRs are reports whose code, CI and merge state were
  not checked.

**Contents.** Evidence and validation limits; Implementation ledger (LED-01 to
LED-62); Boundaries (BND-01 to BND-09); Correctness, privacy and persistence (COR-01
to COR-13); Providers, managed sign-in and account setup (PRV-01 to PRV-29);
Performance, networking and scheduling (PRF-01 to PRF-12); macOS usability, visuals
and accessibility (MAC-01 to MAC-35); Widgets, trend chart, color identity and
freshness (WID-01 to WID-21); Linux daemon, CLI and tray (LNX-01 to LNX-17); Build,
release, packaging and documentation (BLD-01 to BLD-11); Security (SEC-01 to
SEC-07); Tech debt (DEBT-01 to DEBT-06); Product features (PRD-01 to PRD-21); New
ideas (IDEA-01 to IDEA-18); Stale BACKLOG.md entries (BKL-01 to BKL-11); Retained
lessons, refuted claims and rejected ideas (LES-01 to LES-05, REF-01 to REF-37);
Suggested follow-up order (ORD-01 to ORD-08); Assembly notes and source ID index.
To pick up work, start with the order (ORD), check the ledger and the boundaries,
then open the entry.

## Evidence and validation limits

What the sources and this consolidation verified, what they did not, and how to
read their labels. Reports by other workers stay reports: their PRs, reviews, CI
and merge status were not checked, and a source document's "fixed", "landed" or
"merged" does not establish status.

### How the sources were produced

- **TMP method.** Baseline origin/main `2d6ac1e`, checked out read-only. Eleven
  area reviewers each read one part: QuotaCore models and storage; provider
  clients; authentication and credentials; AppModel and refresh flow; menu-bar
  dropdown; Settings; widgets; Linux daemon, CLI and tray; build, CI and release;
  product gaps; theming and color. Two gap critics then looked for areas the others
  missed. One or two adversarial verifiers checked every finding against the code,
  CI logs, upstream docs and installed binaries.
- **TMP verdicts.** Confirmed (reproduced, or proven from the code); plausible (the
  mechanism is real, but the trigger or impact is unproven); disputed (verifiers
  disagreed); refuted (the core claim is false; kept only in the REF list). TMP
  merged duplicates across reviewers and applied verifier corrections (severity,
  lines, better fixes), using the corrected line numbers. Unmarked TMP claims are
  confirmed; "(unverified: why)" marks plausible or disputed ones.
- **TMP scales.** Severity: high = wrong data on a primary surface, a broken
  feature, a release break, or credential exposure; medium = a real defect with a
  narrower trigger, or a clear UX or visual failure; low = polish, hardening, or a
  rare trigger. Effort: S, M, L as above. Linux test: "yes" means `swift test` in
  QuotaCore or LLimitd, or the tray's Python unit tests, can cover the fix; "no"
  means only the macOS CI build plus a manual check. Backlog: each finding was
  marked "new", "extends <BACKLOG section>" or "duplicates <section>"; those notes
  survive in the entries and in BKL. Placement: TMP filed items that affect only the
  Linux daemon, CLI, tray or bar examples under Linux, except security and packaging
  items; this document keeps that split (LNX versus SEC and BLD).
- **TMP shortlist.** TMP ranked sixteen focused PRs by user-visible value per unit
  of risk; all are now this pass's PRs (ORD intro; ratings in the assembly notes).
  None needed new provider API evidence: R-BUG-01 relies on two independent
  third-party sources and keeps legacy single-entry payloads unchanged, and R-BUG-02
  relies on the generated proto descriptor. All candidates respect the AGENTS.md
  hard constraints.
- **TMP ideation pass (2026-10-07).** Three ideators (delight, power-user and visual
  lenses) proposed 34 ideas. Each was checked against the code at `2d6ac1e`,
  BACKLOG.md and the findings; near-duplicates were merged, ideas already covered by
  an R-NOV, R-LNX or BACKLOG entry were dropped or kept as extensions, and rejected
  ideas are in REF. Claude Code status line and hooks behavior was checked against
  the official docs on 2026-10-07 (details in the IDEA intro). Claims about the
  `feat/reset-celebration` branch (`4768e74`) could not be checked, because that
  branch was not in the review checkout; they are marked unverified.
- **MAIN method.** See "Sources consolidated" above. MAIN's evidence bullets follow
  as EVIDENCE-1 to EVIDENCE-7. All incoming references in MAIN, including the
  pass-C and pass-D references, are retained as reports.
- **This pass's PRs.** LEDGER records scope and deferrals; its final update also
  records each PR's CI-green head, the measured merge conflicts and an integration
  check (ledger table 1). This document did not check CI or reviews itself. Some
  entries cite local worktree heads ("Worktree check"): #89 `30e0299`, #90
  `4cdbdab`, #92 `53350b7`, #93 `4f1aede`, #104 `17f970d`, #110 `e72725c`, and the
  #105 and #108 worktrees. The first five are the final PR heads. #110's final head
  is `0f0907c`, and the #105 and #108 worktree heads were not recorded, so those
  checks may differ from the final PRs.

### Test and CI results

- **Baseline tests (EVIDENCE-1).** The baseline in MAIN's `tmp.md` passed **416
  QuotaCore**, **49 LLimitd** and **23 tray** tests, plus shell syntax checks for
  build, release, widget diagnostics, Linux installation and packaging. Historical
  main CI run **37509656521** passed macOS build/integration and Linux checks. TMP
  adds, from the same run on `2d6ac1e`, that the macOS job ran and passed the
  panel-geometry step (REF-03), and that the CI token had write access to Actions,
  Contents, Issues, Deployments and PullRequests (SEC-04). TMP counts 416 QuotaCore
  test methods at baseline.
- **Other CI runs (TMP).** Run 37363625985 failed to acquire hosted runners for both
  the macOS and the Ubuntu jobs, so it is not brownout evidence (BLD-01, REF-03).
  Run 36306682635 was cancelled after 7 s, so commit `4ecaaba` has no CI result
  (BLD-09).
- **Swift 6 (EVIDENCE-2).** QuotaCore built in Swift 6 language mode. LLimitd's
  optional Swift 6 build failed at `LD/StatusRenderer.swift:222` on a non-Sendable
  stored comparator; supported-mode tests passed. Async test fixtures also need
  synchronization work (DEBT-04, LES-04).
- **Incoming passes A-C (EVIDENCE-3).** They lacked Swift and relied on CI. They
  report tray tests increasing from **23 to 27** after countdown work. Their CI
  description includes macOS `xcodebuild`, QuotaCore tests, Linux QuotaCore/LLimitd
  tests, and `python3 -m unittest discover -s Packages/LLimitd/tray/tests`.
  `scripts/test-panel-geometry.sh` and `scripts/test-limit-colors.sh` cover pure
  logic.
- **Incoming pass D (EVIDENCE-4).** Reports **426 QuotaCore** and **52 LLimitd**
  tests on Linux **Swift 6.2.3**, observing each regression test fail before its
  fix. Widget changes were reportedly parse-checked locally and compile-gated on
  macOS CI. These are source-document reports, not results independently verified
  in MAIN's worktree or here.
- **Six MAIN heads together (EVIDENCE-5).** The coordinating agent verified all six
  final PR heads together on 2026-10-07: **496 QuotaCore** and **57 LLimitd** tests
  passed on Linux Swift 6.3.3 with the supplied SDK and `--jobs 2`. The temporary
  integration merge was not published. #69's additional checks are in ledger
  table 2.
- **This pass's 17 heads together (LEDGER final update).** Branch
  `opus/integration-check` (head `7ed4c7b`; draft PR #111, closed after CI) merges
  all 17 final heads onto origin/main. CI was green (macOS Build & Test, Linux
  SwiftPM, Linux static .deb, Linux tray), and **665 QuotaCore**, **134 LLimitd**
  and **46 tray** tests passed locally. Details in ledger table 1.

### Toolchain notes

- CI uses Swift 6.2.3, and the shipped `.deb` is built with the Swift 6.2.3 static
  (musl) SDK. Its `Task.sleep` uses the continuous clock, so the daemon does not
  pause during system sleep. On macOS the sleep pause applies only to the Swift 6.1
  or older runtime (macOS 14 and 15); on macOS 26 (Swift 6.2) a sleep fires right on
  wake, possibly before the network is back (PRF-01, REF-12).
- TMP verified that swift-corelibs URLSession on Swift 6.1.2 throws
  `NSURLErrorCancelled` at once when the daemon's loop task is cancelled (COR-04).
- The 6.2.3 static SDK also ships an aarch64 sysroot, but only amd64 is built
  (BLD-05).
- The `macos-15` arm64 runner image ships Xcode 16.2, with 16.4 as the default, so
  the existing 16.2 pin keeps working. TMP notes Xcode 16.2 in CI and 26.x locally
  (BLD-01, BLD-07). The README's "65 tests on Swift 6.0.3" is stale (BKL-02).
- Linux measurements in the sources used different toolchains: MAIN's pass D Swift
  6.2.3, MAIN's coordinator Swift 6.3.3, and TMP's one benchmark Linux
  swift-foundation (below).

### Not exercised

- **Runtime checks (EVIDENCE-6).** Native rendering, Instruments, VoiceOver, live
  authentication, installed widgets, systemd upgrades, and packaged TLS were not
  exercised in MAIN's consolidation, and neither TMP nor this consolidation reports
  exercising them. Source counterexamples, reported implementations, and runtime
  hypotheses remain distinct. MAIN inspected no credentials, other workers, or their
  PRs.
- MAIN's native layout and lifecycle items are hypotheses, not reproduced defects
  (MAC-30 to MAC-35). The installed-widget validation matrix is WID-21.
- **Provider contracts.** Provider APIs are undocumented and unstable. MAIN's
  original review found no additional code-established Venice, OpenCode Go, Kimi,
  Devin or Zhipu client defect that warranted speculative API changes. Later pass-D
  reports are separate evidence, and #65, #81 and #84 were not independently
  validated. New field or endpoint semantics need sanitized fixtures (BND-09).

### Performance claims

- **What source inspection proves (EVIDENCE-7).** Source inspection proves blocking
  work and full decoding, not measured stuttering, multi-second hangs, OOM, or a
  fixed WidgetKit memory limit. A 32-character paste normally causes one binding
  update, not 32 saves. The older **30 MB** widget budget is unverified; measure
  platform and process limits before using it as a crash threshold.
- **TMP's only timing.** Linux swift-foundation, 3,000 snapshots x 4 accounts (about
  8 MB): about 0.28 s per decode and 0.33 s per encode, so roughly 2.4 s per typed
  Venice-key character at baseline (R-BUG-09, LED-12). macOS was not measured, and
  R-PERF-01's cost depends on archive size.

## Implementation ledger

Record of what is already implemented, so the topical sections describe only open
work. It has three tables: this pass's open PRs (#89-#110, from LEDGER), the six
MAIN-owned open slices, and the implementations MAIN reports (#50-#100 plus an
unnumbered badge change). Then come the overlaps between the two PR sets and the
implemented-issue clusters (LED-01 to LED-62), one per implemented issue, listed
without detail. An implemented issue has no entry elsewhere. Where an issue is only
partly implemented, its topical cluster holds the remaining work and its status
names the PR. Deferred follow-ups are open work; each row names the cluster that
now owns them where the sources identify one. Line references are baseline
`2d6ac1e` starting points, not current offsets.

None of these PRs is merged. Every PR in tables 1 and 2 is open and left for the
user to review. Table 3 entries are reports from MAIN, whose PR, CI and merge status
neither document checked.

### 1. This pass's open PRs (#89-#110)

All open and unmerged, for the user to review. All 17 reached the review stopping
rule; "CI-green head" is each PR's final head, with CI green, from LEDGER's final
update. "Implements" uses TMP ids; LED ids point to the cluster list below; from
its second sentence on, an "Implements" cell lists what the review rounds added.
Partly implemented TMP ids keep their remaining work in the named topical cluster.

| PR | Branch | CI-green head | Implements | Deferred follow-ups (owner) |
|---|---|---|---|---|
| #89 | `opus/devin-exhausted-windows` | `30e0299` | R-BUG-02 incl. hide flags, credits rule, `overageBalanceMicros` (LED-01). Credit-billed plans never infer an exhausted window from a reset alone; a sub-cent negative overage shows "$0.00"; the implicit-presence premise was verified against the oh-my-pi descriptor. | Top-level `planInfo` copy not read (oh-my-pi treats it as authoritative); overage balance probed only in `planStatus` proto field 16 (PRV-27). |
| #90 | `opus/zai-weekly-tokens` | `4cdbdab` | R-BUG-01 (LED-02). A present but non-numeric `unit` becomes a neutral `tokens-uunknown-n<number>` entry; a malformed TOKENS_LIMIT entry fails the refresh (keeping the last good usage) instead of silently dropping a window. | Whether `open.bigmodel.cn` (Zhipu) returns a weekly entry is unverified (PRV-27); unknown (unit, number) pairs not logged because QuotaCore has no logger (DEBT-01). |
| #92 | `opus/release-unblock` | `53350b7` | R-BLD-02 (LED-03); most of R-BLD-01 (BLD-01), R-SEC-01 (SEC-07), ubuntu-24.04 pin from R-SEC-03 (SEC-05); new "Linux (static .deb)" CI job; PTY secret-input test. The PTY test has a bounded exit wait (`EXIT_TIMEOUT_SECONDS`) and asserts that the packaged binary is statically linked. | Remainders in BLD-01, SEC-05, SEC-07: checksum/PGP verification of the Swift toolchain in all three installs via a shared composite action (rest of R-SEC-03) and CI toolchain caching, both declined in review and still open; run `scripts/test-panel-geometry.sh` in the Linux job; the three geometry tests, which the final head does not add (BLD-01); v1.0.1 release note about scrollback; restore terminal echo on signal; Musl branch in the `SettingsLock.swift`/`main.swift` import blocks (harmless today). Merge first (ORD-02). |
| #93 | `opus/anthropic-windows` | `4f1aede` | R-BUG-05 (LED-04); R-BUG-06 (partial, PRV-14); amount-only `extra_usage` metric of R-FEAT-01 (partial, WID-16). The "empty" placeholder is dropped when an extra-usage amount exists. | Non-USD extra-usage amounts (needs a capture); extra usage on ring tiles and the dashboard widget (WID-16); `maxUsagePercent` nil when no window parsed (R-BUG-34), covered for Anthropic by #84 (COR-10). |
| #94 | `opus/publish-perf` | `b57db7f` | R-PERF-01 (LED-05): one decode + one encode per publish; `QuotaHistoryStore.remove` no-op skip. The App Group history is a byte mirror of the local archive, and an unreadable widget copy is replaced on the next publish (`ifUnreadable: .replace`). | R-BUG-33: the 3,000-entry cap truncates the 30-day trend, needs a retention decision (PRF-03). A corrupt local archive still blocks local appends forever; needs quarantine, rebuild and surfacing (PRF-04; #78 likely covers). |
| #95 | `opus/dropdown-layout` | `eacfbdb` | R-VIS-01, R-VIS-08, R-VIS-11, R-UX-06 (LED-06 to LED-09); R-UX-03 (partial, WID-05); dashboard part of R-UX-24 (partial, MAC-21). Dashboard padding constants are shared with the geometry harness. | Visual check on a Mac: 360/420 pt, floating window, long subtitles, "≈100%" ring (DEBT-06); optional "oldest N min ago" header note (WID-05). Ages are English-only by design. |
| #96 | `opus/status-item-health` | `dad9a2f` | R-UX-05, R-VIS-07 (LED-10, LED-11). Reset staleness requires `resetAt` later than `fetchedAt` and counts only percentage windows; a 60 s timer re-evaluates staleness; the failure orange is a fixed sRGB value; the tooltip is retried at launch. | R-UX-04, dashboard order vs bars (MAC-13). Share level/stale/failure-matching rules between `MenuBarGraph`, the dashboard's `MenuBarQuotaStyling` and the provider tile; re-apply the tooltip on display changes; manual Mac check of tooltip and light/dark bars (DEBT-06). Re-test the menu-icon hypothesis after merge (MAC-35). |
| #101 | `opus/venice-key-commit` | `92693f8` | R-BUG-09 (LED-12): drafts commit on submit, focus loss, selection change, close and quit; `PendingEdits` in QuotaCore. Commits return an outcome enum, and a rejected draft is kept with an inline reason (`PendingEdits<Key>`, 8 tests). | Drop `@discardableResult` on `updateAccount`; trim legacy stored credentials for display; SwiftUI commit-trigger wiring untested; manual Mac checks of close/quit with a draft (DEBT-06). A rejected draft for an account that became connected is never shown and is dropped at quit (COR-03). |
| #102 | `opus/refresh-during-signin` | `daf9943` | R-BUG-11 (LED-13); R-UX-18 Refresh controls only (partial, MAC-15). Per-account Refresh Now is disabled during that account's own sign-in; the header keeps the data age next to the reason; an imported OpenAI account with only a refresh token or account id counts as refreshable. | R-BUG-22: ticks dropped during single-account refreshes, scheduler (PRF-01). Disabled Connect/Remove reasons, rest of R-UX-18 (MAC-15). Tooltip on a disabled button unverified on macOS 14. |
| #103 | `opus/quota-pace` | `f0dc31d` | R-NOV-01 (partial): `windowSeconds`, `QuotaPace`, ticks on bar and tile ring. The text reads "N% over pace", "on pace" or "N% under pace", and the reset chip keeps its width. | `paceDelta` in Linux JSON; window lengths for Muse weekly and Devin windows; `GlossBar` spring ignores Reduce Motion (pre-existing, MAC-07). Converge with #87 and #109 (PRD-01, PRD-02). |
| #104 | `opus/linux-account-integrity` | `17f970d` | R-BUG-04 macOS guard + daemon guard (LED-14); R-LNX-03, R-LNX-05, R-LNX-06, R-LNX-09. Settings mutations are reachable only through a `SettingsTransaction` handle passed to `editingSettings` (nesting traps); interactive import re-prompts; `--set key` without a value fails on a non-TTY; decode errors are built only from the error case, path and expected type; `reimport` scans before taking the lock. | `remove` confirmation/`--yes`; 4-character minimum prefix; stored import source; carry Claude `expiresAt`; R-LNX-10 (an in-flight refresh can re-save an old Venice estimate). Name every prompted key in the non-TTY error (SEC-06). Its `makeDaemon` status warning becomes dead once #108 makes `status` snapshot-only; dropping it is an integration fix (below; LNX-03). |
| #105 | `opus/linux-honest-status` | `5e1dec2` | R-LNX-02, R-LNX-07, R-BUG-08 (LED-15 to LED-17); R-LNX-01 (LNX-01); tray part of R-A11Y-04. Error text neutralizes polybar `%{`, and the polybar script sanitizes its text; the regex scan is capped at 16,384 characters with precompiled patterns; trailing unclosed tag fragments are dropped after each cut; carried windows are cleared only when read before their reset; stale accounts cap the class at `warning`; tray hardening (naive `now`, failure note). | R-LNX-16 light-panel tray icons. Record `refreshIntervalMinutes` in the snapshot so the stale threshold follows the real interval; #105 uses a 6 h constant (2x the maximum interval; baseline was 2 h). #50 reports interval-aware staleness (LNX-01). Also strip a lone trailing `<` and repeat the fragment strip until stable; sample one `now` per tray menu build (DEBT-06). |
| #106 | `opus/global-hotkey` | `e83920e` | R-NOV-04 (LED-18). `AppModel.shared` owns the model (no second AppModel on re-init); the key code is `DashboardHotkey.keyCode`, checked against Carbon's `kVK_ANSI_L` in tests; the picker is labeled; failures are logged with `os.Logger`. | `@ObservedObject` for `AppModel.shared`; check the hot key id, not only the signature, in the Carbon handler; the remembered app can go stale if the user switches apps before dismissing (DEBT-06). |
| #107 | `opus/managed-cli-path` | `0807ded` | R-BUG-03 (partial, PRV-05); R-BUG-42, R-PERF-05 (LED-19, LED-20). Also nvm discovery (`$NVM_DIR` or `~/.nvm`, `alias/default` first, then `versions/node/*` by semantic version), fnm, Volta with `VOLTA_HOME`, a distinct excessive-output failure, tailored timeout advice, a process-group kill on probe timeout, and re-probing only when a start failure implicates the executable. | A Settings override for custom CLI paths (PRV-05). |
| #108 | `opus/llimit-check-pick` | `e0a63d7` | R-NOV-03 (LED-21); R-LNX-20: `check`, `pick`, `status --format/--account/--worst/--kind/--watch`, tmux/starship/agent-wrapper examples (partial, LNX-10); status part of R-BUG-04 (LED-14): `status` is snapshot-only. Failures match on (provider, account id); `check` and `pick` exit 3 for a provider with no accounts; a blank `--format` is a usage error; `--watch` warns once per distinct message; the tmux example shows "(stale)"; the starship `when` hides the module without data. | Presets (`short`, `tmux`, `i3blocks`) and `--worst N`; share the `{class}` cutoffs with StatusRenderer after #95 and #105 land (LNX-10). Deterministic order for failure-only rows that share an account id (DEBT-06). Snapshot merge and macOS still match failures by account id only (pre-existing, DEBT-06). |
| #109 | `opus/trend-widget` | `5cec752` | R-BUG-12, R-BUG-13, R-A11Y-02, R-VIS-06, R-UX-21 (LED-22 to LED-26); R-UX-22; most of R-VIS-05. Warnings also use a guarded recent pace (remaining at most 25%, span max(2 h, 3 refresh intervals), at least 4 raw samples); the refresh interval is floored at 15 min; day ticks are end-anchored; the DST fall-back hour is deduplicated; forecast keys are deduplicated; a fourth same-hue line gets dash-dot. Decided: an early large burn that projects depletion keeps warning (no idle gate). | "Store unavailable" empty state in `QuotaTimelineProvider` (WID-03). Rest of R-VIS-05: primary window only in the small widget, nudging overlapping flat lines apart, short-term limits off by default (WID-10). A stale doc comment on `recentPaceDepletion` (DEBT-06). |
| #110 | `opus/linux-alerts` | `0f0907c` | R-LNX-21 (LED-27); Linux part of R-NOV-02: `QuotaEvents` detector in QuotaCore, `--notify`, `--on-event`, `LLIMIT_NOTIFY`, hook examples. Hooks that leave their process group are still killed (signals to pid and group; bounded reap); the state file is fsynced before rename; the failure latch tracks the latest kind; state for accounts absent from two snapshots is pruned. | `expiringUnused` flag in `status --json`; macOS "use it" chip and macOS notifications reusing `QuotaEvents` (PRD-04, WID-04); alerts from `llimit refresh` and the timer units; alerts path in `llimit paths` (DEBT-06). Its `AlertDelivery` Darwin branches are never compiled in CI (BLD-08). Info: a hook stuck in uninterruptible I/O after SIGKILL pins one background thread until it exits. |

**Measured merge conflicts and integration check** (LEDGER final update; this
replaces the earlier expected-conflict list):

- Pairwise `git merge-tree` of all 17 heads: only 8 pairs conflict. Code:
  `LD/StatusRenderer.swift` (#95 x #105) and `APP/LLimitApp.swift` (#95 x #102).
  Docs: `AGENTS.md` in all six pairs among #104, #105, #108 and #110, plus
  `Packages/LLimitd/README.md` (#108 x #110). `CLI/main.swift` and
  `APP/AppModel.swift` merge cleanly across all PRs.
- Integration check: branch `opus/integration-check`, head `7ed4c7b` (draft PR
  #111, closed after CI), merges all 17 heads onto origin/main with every conflict
  resolved keeping both sides. CI green (macOS Build & Test, Linux SwiftPM, Linux
  static .deb, Linux tray); locally 665 QuotaCore, 134 LLimitd and 46 tray tests
  pass.
- Integration-only fixes the second PR of each pair must carry:
  - #95 + #108: #108's `StatusTemplate.swift` and `ScriptCommands.swift` call
    `StatusRenderer.relativeAge`, which #95 removes; point them at
    `QuotaDisplayText.relativeAge` (build break otherwise).
  - #104 + #110: two `QuotaAlertsTests` calls to `QuotaDaemon.addAccount` need `try`
    once #104 makes it throw (test build break otherwise).
  - #104 + #108: #104's `makeDaemon` branch that warns for `status` becomes dead
    once #108 makes `status` snapshot-only; drop it and the README sentence about
    the stderr warning.
- Conflict text: combine the layout entries in `AGENTS.md` and
  `Packages/LLimitd/README.md`; merge #105's StatusRenderer rewrite with #95's
  `relativeAge` move; combine the dropdown header subtitle (#102's reason and age
  cases with #95's wording and formatter). The resolutions are on the integration
  branch.
- Suggested landing order: #92 first; then #104, #108, #105, #110; #95 after #105
  and #108; #95 and #102 in either order; the other ten (#93, #89, #90, #94, #101,
  #96, #103, #109, #107, #106) any time.
- New follow-ups found by integration, open once both PRs land: #108's template
  `{class}` does not apply #105's rule that failed or stale accounts raise the
  class to `warning` at most (LNX-10); template `{stale}` and `check`/`pick` use
  2 h (`HeadroomRanking.defaultMaxAge`) while #105's status output uses 6 h
  (LNX-01); #108's `StatusTemplate` and `HeadroomRanking` name an account with no
  usage by provider display name and ignore #105's `ProviderFailure.title`
  (LNX-10).
- Against MAIN PRs (expected, not measured): `APP/LLimitApp.swift` with #67;
  `QC/QuotaHistoryStore.swift` (#94) with #52/#76; the `AnthropicClient` parser
  (#93) with #84; `mergingStaleUsage` (#105) with #77; limit-color drawing code
  (#96, #109) with #53.

### 2. MAIN-owned open slices (#66, #67, #69, #70, #72, #75)

The coordinating agent checked all six on 2026-10-07. Each is open and unmerged,
with latest-head macOS Build & Test, Linux SwiftPM, Linux tray and GLM checks green.
Two completed GLM rounds per PR were assessed with no agreed important production
findings; findings came from review comments, not from successful reviewer jobs.
This is the requested review stop, **not merge approval**. Integrate
**#70 before #69** (overlapping Muse guard and parser changes). Native layout, AX,
live providers and installed-widget behavior still need runtime verification.

| PR | Branch | Verified head | Retired MAIN ids and scope | Remaining (owner) |
|---|---|---|---|---|
| #66 | `sol/snapshot-only-status-20261006` | `245c7cc` | L01 fully; Linux C03. Snapshot-only `status`, clean JSON stdout, no credential-settings read, failed-settings reconciliation guard preserving cached bytes (LED-14). | Overlaps #104/#108; keep one Linux implementation. macOS C03 is in #104. Recovery UI in COR-07. |
| #67 | `sol/bottleneck-context-20261006` | `d76dabe` | Bottleneck caption fully: gauge and caption identify the same actual limiting metric and reset, including ties and unknown, unlimited and balance-only states, with accessible context and no extra poll (LED-28). | Relevant to MAC-04, MAC-13, MAC-26. |
| #70 | `sol/failure-redaction-20261006` | `543e0e9` | New-failure part of C01: safe provider/OAuth messages, configured-secret redaction, message bounds (LED-29). | Historical failure migration, structured metadata, widget-safe DTO (COR-06); compare #63. |
| #69 | `sol/quota-schema-validation-20261006` | `c1554af` | A01/A02 fully. Cline recognized windows require finite `percentUsed`: missing/null fails decoding; explicit zero, bare objects and `data:null` stay valid. Muse separates absent from malformed subscription windows and requires a recognizable completion; valid pay-as-you-go completion still supported. Stacked on #70 (LED-30). | Muse parsing interacts with PRV-13. |
| #72 | `sol/dashboard-truth-20261006` | `ef6fcd9` | W01/W02 fully; dashboard W03. Attributable bounded values only; distinct unknown/unlimited/zero; current enabled membership and names before sorting/limiting; conservative legacy ownership; truthful dashboard no-account/awaiting/failure/storage states (LED-31). | Per-account age (WID-05); tile and trend load outcomes (WID-03); reconcile with #54/#80 (ORD-01). |
| #75 | `sol/fetch-time-history-20261006` | `c9afb8b` | C02 fully. Source-fetch-time extraction/append/chart semantics exclude failed, carried and sibling observations, retain fresh equal readings, canonicalize only unambiguous legacy ownership without destroying archives. Collapses same-account readings within one persisted fetch-second; disabled siblings do not establish legacy ownership (LED-32). | History half of R-BUG-27 covered (COR-08); reconcile with #52/#76 (LED-34). |

- **#69 extra checks:** its final follow-up passed 72 focused tests and all 443
  QuotaCore tests on its own branch. The fixture-route and nil-URL regressions were
  observed failing before the fixture fix. Terminal-error/last-good and
  spec-compliant multiline SSE coverage preserve policy.
- **Rejected review suggestions:** accepting a terminally failed Muse stream as fresh
  success; treating present malformed/null windows as absent; exempting short
  configured secrets from redaction; inventing observed-now history endpoints.
  Synthetic-token blockers were inert test fixtures. Minor inherited copy,
  diagnostic and metadata suggestions are deferred; cancellation and publication
  remain open (MAIN C10).
- **Retired baseline evidence** (traceability only, not tasks):
  - L01: `CLI/main.swift:45-48,332-337` opened settings for `status`; bootstrap
    reconciliation could erase usage, and save logs contaminated JSON.
  - Linux C03: `LD/QuotaDaemon.swift:78-91,525-536` (in #66). The macOS half,
    `APP/AppModel.swift:120-154,1712-1727`, is covered by #104.
  - C02: `QC/SnapshotMerge.swift:12-30` kept the original `fetchedAt`, but history
    stored merged snapshots; `APP/LLimitApp.swift:426-442` and
    `WX/LLimitQuotaWidget.swift:773-775` plotted `generatedAt`;
    `APP/LLimitApp.swift:1427-1440` added a point at now. Failures and targeted
    sibling polls invented flat observations, inflated forecasting evidence and could
    bypass source-time windows.
  - A01: `QC/Clients/ClineQuotaClient.swift:325-340,95-102` turned missing/null
    `percentUsed` into 0% used, 100% remaining.
  - A02: `QC/Clients/MetaMuseQuotaClient.swift:85-127,189-217` could call a
    malformed `weekly:{}` or an arbitrary HTTP-200 `{}` pay-as-you-go.
  - W01: an unknown Google aggregate zero produced full bars and lowest 100%
    alongside `--` rows (`WX/LLimitQuotaWidget.swift:415-416,495-514,635-650`).
    W02: snapshot names and membership survived edits (`:357-373,439-442`).
    Dashboard W03: initial failures and unreadable stores became no-account states
    (`:357-391,439-466`).

### 3. MAIN-reported implementations (#50-#100, badges)

Reports only. Neither document checked their PRs, reviews, CI or merge status. Do
not infer status from the incoming document's words "fixed", "landed" or "merged".
Verify each before building overlapping work, and reuse rather than rebuild it.

| PR | Branch | Reported scope | Remaining, caveats (owner) | LED |
|---|---|---|---|---|
| #50 | `linux-live-resets` | Live `UsageMetric.resetCountdown(at:)` in status/tooltips; ISO `resetAt` and recomputed `resetSeconds` in metric JSON; ticking tray countdowns; configured-interval staleness instead of a hardcoded 2 h. | Overlaps #105; reconcile additive key names (LNX-01). | LED-15 |
| #51 | `linux-reset-radar` | `llimit resets [--json] [--days N]`; pure `QuotaSnapshot.upcomingResets(now:within:)`; total ordering; 1-90 day validation; `snapshot`/`generatedAt` metadata; missing data distinct from an empty schedule; stale-schedule flag (reported older-than-one-day policy). | macOS and tray surfaces (PRD-07, LNX-17). #88 also reports a reset listing. | LED-33 |
| #52 | `history-skip-unchanged` | Skips repeated accounts/failures while still advancing retention. | Reconcile with #75 and #76 (LES-02); conflicts with #94 in `QuotaHistoryStore`; fewer appends ease R-BUG-33 (PRF-03). | LED-34 |
| #53 | `limit-color-palettes` | `LimitKindPalette` Standard/Ocean/Sunset/Forest/Vivid; Settings > Appearance picker across rings, bars, sparklines, menu, widgets and trend; `matching` defensively canonicalizes a copy. | Contradicts TMP's rejected color-pack idea: the pale variant fails the chroma floor, so every palette needs contrast/CVD validation (WID-09). Canonical writes (MAC-20); theme preview (PRD-14). Shares drawing code with #96 and #109. | LED-35 |
| #54 | `widget-failure-states` | Cause-specific failures, shared dashboard empty view, unavailable account names, order-preserving dedup, medium-family "+N more". | Coordinate with #72 and #80 (ORD-01). Check whether it also changes the trend empty state #109 touches. | LED-36 |
| #55 | `provider-glyphs` | Distinct Copilot/OpenCode Go/Cline and Zhipu/Z.ai symbols; compact OpenCode name "OpenCode", not "Go". | Fully covers TMP R-THM-05 if it lands. The compact name is one of the six exhaustive switches. | LED-37 |
| #56 | `settings-accessibility` | Explicit hidden-control labels, described account-status dots, textual "Refreshing". | Not widget semantics or native AX coverage (MAC-04, MAC-08). | LED-38 |
| #57 | not given | Venice-only coordinator estimate dispatch. | MAIN could not establish the incoming "critical cross-provider bug": the helper already guarded non-Venice providers. | LED-39 |
| #58 | not given | Calm/cloudy/stormy dashboard header from headroom, failures and estimates. | Per-account outlook and Fog (IDEA-13). | LED-40 |
| #59 | not given | Trophy-tagged overview recommendation: highest bounded remaining headroom. | Share one ranking with #108's `HeadroomRanking` (PRD-06). | LED-41 |
| #63 | `fix/provider-error-body-excerpt` | Bounded decoding; about 200-character whitespace-folded excerpts; Bearer/JWT/API-key-shaped token scrubbing via `bodyExcerpt`/`sanitizeFailureText`. | Scrubbing does not make unknown reflected secrets or old persisted errors safe; reconcile with #70's allowlisted public messages (COR-06). | LED-42 |
| #64 | `fix/status-renderer-account-identity` | Failure title fallback (recorded title, then cached usage title, then provider); additive account JSON `failing`/`error`/`errorKind`; most-actionable duplicate collapse; failure escalation from green to warning; full error tooltips in the tray. | Cross-account severity/recency ordering and all-failed health need separate checks. Overlaps #105; pick one additive key set (LNX-01). | LED-43 |
| #65 | `fix/client-hardening-glm` | Shared `errorKind(forStatusCode:)` maps Zhipu/OpenAI/Copilot billing 429 to `.rateLimit`; Copilot quota non-401/403/404 and token-exchange 5xx no longer fall through to `.auth`; missing/unparseable Antigravity `remainingFraction` becomes unknown, with nil `maxUsagePercent` when no bounded data exists; transport rethrows `CancellationError`/`URLError.cancelled`; Zhipu accepts success without a numeric `code`; exact OpenAI 45-minute, 25-hour and N-second labels with classifier tests; `parseNumeric` scan replaces a per-call regex. | Incoming copy says `.api` includes response bodies: reconcile with #63/#70 (COR-06). End-to-end cancellation remains (MAIN C10). Touches COR-04, PRV-10, PRV-15, PRV-23, PRV-27, PRF-12; consistent with REF-02. Does not establish live contracts. | LED-44 |
| #68 | `fix/venice-key-invalidation` | Deferred/debounced invalidation, termination flush, estimate key fingerprint preventing attachment to a replacement key. | Overlaps #101. Whole-archive purge cost remains (PRF-03). | LED-12 |
| #71 | `fix/settings-secure-save` | Credential settings: `O_CREAT\|O_EXCL` at `0600`, `fchmod`, file `fsync`, same-directory rename, `stat` type/mode verification, directory `fsync`; failure removes the intermediate and throws. The polling test reports thousands of intermediate `0644` samples before, only `0600` after, a large save. | Directory restriction, owner/symlink checks, shared-container compatibility (SEC-02). Reuse this helper. | LED-45 |
| #73 | not given | Floating dashboard follows system appearance after removing forced dark mode. | Different fix from TMP R-VIS-13 (force `darkAqua` chrome); either removes the mismatch. Needs light-surface palette validation (MAC-16); invalidates TMP's dark-only contrast numbers (MAC-06). | LED-46 |
| #74 | `fix/store-file-permissions` | `writeOwnerOnlyAtomically` creates a `0600` temporary file before rename for snapshot/history; chmod/write errors reach stderr. | Local directories, owner/type checks, shared access (SEC-02). | LED-45 |
| #76 | `fix/history-dedup` | Skips content-equivalent points when the newest is under 1 h old; folds a newer timestamp into stale points to keep flat stretches recent. | Publication time must not become observation time and fresh equal readings must survive; timestamp folding conflicts with #75 (LES-02). Sparse archives need preservation tests. Conflicts with #94. | LED-34 |
| #77 | `feat/retry-after-cooldown` | Delta-seconds and IMF-fixdate `Retry-After`, capped at 24 h, into `ProviderClientError.retryAfter` and additive Codable `ProviderFailure.retryAt` (old records decode nil). Coordinator skips cooling accounts and carries the failure so `mergingStaleUsage` keeps last usage; Anthropic copy names the wait. | Other clients (Copilot internal API, Kimi) and GitHub headers (PRF-05); broader scheduling (PRF-01). Reuse `retryAt`, no duplicate field (COR-06). #105 also edits `mergingStaleUsage`. | LED-47 |
| #78 | `fix/store-corruption-quarantine` | Undecodable snapshot/history moves to `<name>.corrupt`; `reportPersistenceIssue` via os.Logger (Darwin) or stderr (Linux). | Not settings recovery (COR-07) or serialized read-modify-write. Likely covers #94's corrupt local archive (PRF-04). Starting point for DEBT-01. | LED-48 |
| #79 | `fix/app-group-store-nil` | Failable App Group `SnapshotStore` convenience init with an NSLog breadcrumb instead of a force unwrap. | TMP R-DEBT-04 found no caller and also offered deletion. Tile/trend explicit load outcomes and recovery remain (WID-03). | LED-49 |
| #80 | `fix/widget-dashboard-states` | All-failed/no-data/no-accounts states (complements #54, overlaps #72). Header orange-clock stale badge at 2x the refresh interval, even with the clock setting off. Flexible systemSmall name/percent columns replace fixed 58 pt plus 40/72 pt columns reported to collapse dual-mode bars. Dashboard rows speak unlimited/unknown instead of `INF`/`--`. Dead `resetSummaries`/`dashboardBarPercents` removed. | Badge is aggregate, not per-account age (WID-05). Medium fixed columns, capacity and full semantics remain (WID-12, MAC-04, DEBT-03); dead-helper cleanup relates to MAC-24. Native layout unverified. | LED-50 |
| #81 | `fix/opencode-go-rate-limited` | `GoUsageWindow.isExhausted`/`effectivePercent` render `rate-limited` windows as exhausted at any reported percent instead of failing the fetch. | An exhausted window outside the fixed tile pair is still hidden on tiles (WID-01). | LED-51 |
| #82 | not given (reported in reset-radar work) | Near-reset pulsing ring glow within five minutes. | Probably the same work as `4768e74` on `feat/reset-celebration`; verify. TMP (unverified): glows whenever `abs(resetAt - entry.date) < 300 s`, even on stale data, and adds a `repeatForever` animation widgets never run (MAC-07). Anticipates a reset, does not observe one (IDEA-06). | LED-52 |
| #83 | `feat/cli-polish` | `llimit version`/`--version`/`-v`; `accounts list` data-state summaries from pure snapshot-only `StatusRenderer.accountQuotaSummary` (worst remaining %, estimate marker, balance, failure kind, or no data). | JSON listing and other CLI gaps (LNX-11). Keep the credential-free projection; do not load settings for display health. | LED-53 |
| #84 | `fix/schema-drift-hardening` | Anthropic fails `.decoding` when every window is unparsable/non-dictionary instead of a healthy-looking "No usage data"/zero, and keeps readable windows on partial drift. Kimi coerces heterogeneous `limits[]` element-wise instead of losing all rolling windows. | Same parser as #93 (rebase); covers #93's nil-aggregate deferral (COR-10). Verify sanitized fixtures. | LED-54 |
| #85 | `fix/settings-save-debounce` | 400 ms coalescing for keystrokes and color drags; synchronous `willTerminate` flush (observer queue nil; async hops may be dropped on quit); resign-active flush. | Not off-main-actor I/O or measured responsiveness (PRF-02). Partial overlap with #101. | LED-55 |
| #86 | `feat/env-credential-references` | `env:NAME` settings references resolved at runtime; OpenAI grant rotation and live-file adoption keep the reference. | Resolved values stay local, out of display stores and logs; preserve provenance. Partial answer to secrets on argv (SEC-06). Must survive #104 account updates, COR-05 and SEC-01. | LED-56 |
| #87 | `feat/pace-eta` | `PaceEstimator`/`UsageMetric.paceEstimate` in QuotaCore; macOS dropdown burn-rate/ETA. | CLI/tray/widget surfaces remain. Prove reset/gap correctness before reuse or treating it as forecast validation. Converge with #109 and #103 (PRD-01, PRD-02). | LED-57 |
| #88 | `feat/cli-surface` | `llimit compact`, a reset listing, JSON/CSV `llimit export`. | Verify exact flags. Partial overlap with #108 `status --format` (LNX-10). | LED-58 |
| #91 | `fix/claude-ua-version` | Cached detected Claude Code version in the Anthropic usage UA instead of a frozen `claude-code/1.0.110`. | Synthetic sequencing does not prove every CLI version works (PRV-28). Detection depends on finding the CLI, which #107 changes (PRV-05). | LED-59 |
| #97 | `feat/llimit-check` | `llimit check [--below pct] [--stale-hours h]`, exit 1 with reasons for low metrics, failures and stale data; `llimit check \|\| notify-send` hooks. | Incompatible with #108's `check`; choose one before either merges. | LED-21 |
| #98 | `feat/llimit-trend` | `llimit trend [--days N]`: per-account, normalized, forward-filled sparklines. | Forward fill is decorative, not an observation or forecast evidence; normalization must not imply comparable capacities. Coordinate with #75. | LED-58 |
| #99 | `feat/llimit-watch` | `llimit status --watch [seconds]`, ANSI clear/home repaint following daemon refreshes. | Overlaps #108's `--watch`; keep one. | LED-60 |
| #100 | `feat/threshold-alerts` | `QuotaAlertEvaluator`, `QuotaAlertSettings`, persisted dedup keys, warning/critical band crossings and per-kind failure notifications via `UNUserNotificationCenter`, rearm on recovery, thresholds in Settings > General. | Quiet hours, Focus awareness, reset notices, shared status policy (PRD-04, WID-04). Overlaps #110's `QuotaEvents`. | LED-61 |
| none | not given | AUTO/ESTIMATED badges: 8 pt text, 0.85-opacity foreground, explicit VoiceOver labels. | Covers the badge part of R-THM-07 (PRD-15). Full metric/freshness/failure summaries remain separate. | LED-62 |

### Overlaps between the two PR sets

Decide each before merging the second PR of the pair.

1. **Snapshot-only `llimit status`:** #108 (status part of R-BUG-04) vs #66 (L01,
   MAIN-owned). Both stop reading settings and keep JSON stdout clean; keep one.
2. **Linux unreadable-settings guard:** #104 (daemon part of R-BUG-04) vs #66 (Linux
   C03 failed-settings reconciliation guard). #104 also adds the macOS guard (MAIN's
   open C03), which no MAIN PR covers.
3. **Live reset countdowns and `resetAt` in the bar JSON:** #105 (R-LNX-02, plus
   per-account `fetchedAt`/`ageSeconds`) vs #50 (`resetAt`, recomputed
   `resetSeconds`, ticking tray countdowns). #50 also reports the interval-aware
   stale threshold that #105 deferred. Reconcile the additive key names.
4. **Failing and stale accounts in `status --json` and the tray:** #105 (R-LNX-01
   failure keys, failure-only accounts, class elevation, tray error rows) vs #64
   (`failing`/`error`/`errorKind`, failure title fallback, green-to-warning
   escalation, tray error tooltips). Choose one additive key set.
5. **`llimit check`:** #108 (`--min`/`--max-age`; exits 0 ok, 1 below minimum, 2
   stale or failing, 3 no data) vs #97 (`--below`/`--stale-hours`; exits 1 with
   reasons). Incompatible script contracts.
6. **`llimit status --watch`:** #108 vs #99.
7. **Compact status output for prompts and bars:** #108 (`status --format`
   templates with tmux/starship examples) vs #88 (`llimit compact`). Partial
   overlap.
8. **Headroom recommendation:** #108 (`llimit pick` with `HeadroomRanking` in
   QuotaCore) vs #59 (overview trophy for the highest bounded headroom). Different
   surfaces; share one ranking.
9. **Venice key edits purging history:** #101 (drafts commit on submit, focus loss,
   close and quit) vs #68 (debounced invalidation, termination flush, estimate key
   fingerprint).
10. **Settings edit persistence:** #101 (`PendingEdits` draft commits) vs #85
    (400 ms save debounce with `willTerminate` and resign-active flushes). Same
    AppModel edit path; partial overlap.
11. **Depletion forecast engine:** #109 (`QuotaForecast` in QuotaCore for the trend
    warning) vs #87 (`PaceEstimator`/`UsageMetric.paceEstimate` with the dropdown
    ETA).
12. **Pace model on `UsageMetric`:** #103 (`windowSeconds`, `QuotaPace`,
    over/under-pace ticks) vs #87 (`PaceEstimator` burn rate and ETA). Partial
    overlap.
13. **Threshold alerts:** #110 (`QuotaEvents.detect`, 20%/5% crossings,
    deduplicated state, Linux notify and hooks) vs #100 (`QuotaAlertEvaluator`, band
    crossings, persisted dedup, macOS notifications). Two engines with two threshold
    sets.
14. **Corrupt store handling:** #94 (self-repairing App Group widget copy; the
    corrupt local archive was deferred) vs #78 (moves undecodable snapshot/history
    to `.corrupt`). Partial overlap; #78 likely covers #94's deferral.
15. **Anthropic parsing:** #93 (deferred making `maxUsagePercent` nil when no window
    parsed) vs #84 (fails with `.decoding` when every window is unreadable, keeps
    partial windows). Same parser; #84 covers #93's deferral.
16. **Trend widget empty states:** #109 (R-UX-22 empty-state reasons) vs #54 and
    #80 (cause-specific and all-failed/no-data/no-accounts widget states). #54 and
    #80 target the dashboard; check whether they also change the trend widget.

Further code contacts across the sets: #110's hook examples repeat #97's
`llimit check || notify-send` pattern; #105 and #77 both edit `mergingStaleUsage`;
both #94 and #52/#76 edit `QuotaHistoryStore`; #96/#109 and #53 share limit-color
drawing; #67 and five of this pass's PRs edit `APP/LLimitApp.swift`; #91's CLI
version detection depends on the CLI discovery #107 changes; #86's `env:` references
must survive #104's in-place account updates.

### Implemented issue clusters

One row per implemented issue. Scope details live in the PR tables above; notes
name the open cluster that owns each deferred follow-up.

| ID | Implemented issue | Sources | Status | Notes |
|---|---|---|---|---|
| LED-01 | Devin exhausted windows omitted as proto3 zeros | TMP R-BUG-02 | implemented: #89 | Also hide flags, credits rule and `overageBalanceMicros`. Deferred `planInfo` and field-16 probing: PRV-27. |
| LED-02 | Z.ai/Zhipu weekly TOKENS_LIMIT entry read | TMP R-BUG-01 | implemented: #90 | Zhipu weekly entry unverified (PRV-27); no logger for unknown pairs (DEBT-01). Rejected sub-claims: REF-08. |
| LED-03 | Musl-safe Glibc imports and a static musl CI build | TMP R-BLD-02 | implemented: #92 | Release blocker; merge first (ORD-02). #92 also does most of R-BLD-01 (BLD-01), R-SEC-01 (SEC-07) and the R-SEC-03 ubuntu-24.04 pin (SEC-05), plus a PTY secret-input test; remainders stay in those clusters. |
| LED-04 | Anthropic model-specific windows (`seven_day_sonnet` and others) | TMP R-BUG-05 | implemented: #93 | Also R-BUG-06 (PRV-14, partial) and the amount-only `extra_usage` metric of R-FEAT-01 (WID-16, partial). Shares the parser with #84, whose all-unreadable `.decoding` failure covers the nil-aggregate deferral (COR-10). SUB-CLIENT-4 rejected (REF-09). |
| LED-05 | One history decode and encode per publish | TMP R-PERF-01 | implemented: #94 | Also the self-repairing App Group mirror and the `remove` no-op skip. Retention: PRF-03. Corrupt local archive: PRF-04 (#78 may cover). Conflicts with #52/#76. |
| LED-06 | Overview gauges pack into the left columns since #48 | TMP R-VIS-01 | implemented: #95 | `columns = min(count, fit)`. Manual Mac check at 360/420 pt and in the floating window: DEBT-06. |
| LED-07 | Card gauge stroke spills outside its frame | TMP R-VIS-08 | implemented: #95 | Stroke inset by `lineWidth/2`. |
| LED-08 | Provider name repeated in subtitles and failure cards | TMP R-VIS-11 | implemented: #95 | `accountDetailParts` de-duplication; duplicate failure provider line hidden. |
| LED-09 | Subtitle truncation hid the fetched age | TMP R-UX-06 | implemented: #95 | #95 also partly covers R-UX-03 (WID-05) and R-UX-24 (MAC-21). `APP/LLimitApp.swift`: measured conflict with #102 only among this pass's PRs; #67 was not measured. |
| LED-10 | Status-item graph shows failures and stale data | TMP R-UX-05 | implemented: #96 | R-UX-04: MAC-13. Shared rules, tooltip re-apply, manual check: DEBT-06. Re-test the menu-icon hypothesis (MAC-35) after merge. |
| LED-11 | Menu-bar bars get a track and distinguishable low values | TMP R-VIS-07 | implemented: #96 | Also an exhausted-account danger cue. Same drawing code as #53 palettes. |
| LED-12 | Venice key edits purged history on every keystroke | TMP R-BUG-09; MAIN F09, ledger #68 | implemented: #101; #68 (MAIN-reported, unverified) | OVERLAP: choose one mechanism; #68's key fingerprint could sit on top of #101. F09 acceptance: one purge per committed replacement, no old estimate on the new key, durable final edit, in-flight old-key results rejected. A committed change still rewrites the whole archive once (PRF-03). MAIN: a paste is one binding update. Interacts with #85. #101 deferrals: DEBT-06. |
| LED-13 | An OpenAI browser sign-in no longer suspends all refreshes | TMP R-BUG-11; MAIN A08 | implemented: #102 | Other accounts keep refreshing during a Codex sign-in with visible busy feedback (meets A08's acceptance). Dropped auto ticks during targeted refreshes and catch-up scheduling: PRF-01. Disabled Refresh explanations: MAC-15. |
| LED-14 | Unreadable settings never wipe the snapshot; status reads only the snapshot | TMP R-BUG-04; MAIN C03, L01, ledger #66 | implemented: #104 (macOS and daemon guard) + #108 (snapshot-only status); #66 (MAIN-owned) | OVERLAP on Linux (#108/#66 status; #104/#66 guard): keep one. #104 covers MAIN's open macOS C03; check its acceptance (failed bootstrap preserves cached snapshot bytes with no reconciliation writes; intentionally empty settings still prune). Severity: MAIN high, TMP medium (one verifier high). Dead `makeDaemon` warning: LNX-03. Recovery UI: COR-07. Rejected sub-claims: REF-22. |
| LED-15 | Live reset countdowns and `resetAt` in the bar contract | TMP R-LNX-02; MAIN L04, ledger #50 | implemented: #105; #50 (MAIN-reported, unverified) | OVERLAP: both render `resetCountdown(at: now)` with ISO `resetAt`; #105 adds `fetchedAt`/`ageSeconds` and "reset due"; #50 adds `resetSeconds`, ticking tray countdowns, interval-aware staleness (LNX-01). Reconcile key names; add, never rename. L04 acceptance: expired dates say "reset due"; whitespace-only legacy `resetIn` disappears; `--stale-after` only as a scoped contract change. |
| LED-16 | Waybar example escapes untrusted text | TMP R-LNX-07 | implemented: #105 | `escape: true` plus sanitized one-line failure text. |
| LED-17 | Carried usage expires at its reset | TMP R-BUG-08 | implemented: #105 | `mergingStaleUsage` takes `now`; expired carried metrics become unknown, not the pre-reset value or an assumed refill (BND-08). #77 also edits it; rebase. Prerequisite for IDEA-01. |
| LED-18 | Global hotkey toggles the floating dashboard | TMP R-NOV-04 | implemented: #106 | Off by default; Carbon `RegisterEventHotKey`, no Accessibility permission. Nits: DEBT-06. |
| LED-19 | Claude child environment keeps proxy and CA variables | TMP R-BUG-42 | implemented: #107 | One allowlist shared with Codex; `ANTHROPIC_*` and `CLAUDE_*` stay excluded. |
| LED-20 | Codex CLI probe accepts prereleases, caches results, no longer busy-waits | TMP R-PERF-05 | implemented: #107 | Cache misses a byte-identical npm downgrade, recovers on launch failure (PRV-05). |
| LED-21 | `llimit check` and `llimit pick` | TMP R-NOV-03; MAIN ledger #97 | implemented: #108; #97 (MAIN-reported, unverified) | OVERLAP with incompatible contracts (see overlap 5); scripts will depend on one, so choose before either merges. `HeadroomRanking` reusable in PRD-06, IDEA-04, IDEA-09. #110's hooks overlap #97's pattern. |
| LED-22 | Trend depletion warning gated on live, current-window data | TMP R-BUG-12; MAIN W06 | implemented: #109 | `QuotaForecast` in QuotaCore checks live, fresh data, uses window pace plus a guarded recent pace (table 1), requires depletion after now, orders warnings. Decided in review: an early large burn that projects depletion keeps warning (no idle gate). Verify W06 acceptance: estimate from fresh current-reset-segment observations before display sampling; 10% before a reset, 100% at it and 20% now must warn about current depletion; stale, gapped or single-point data is not confident. Converge with #87 in PRD-01. |
| LED-23 | Trend series keyed by positional metric id | TMP R-BUG-13 | implemented: #109 | Trigger unverified. Root fix (duration-based OpenAI/Codex metric ids): PRV-29, DEBT-03. SUB-WIDGET-2 rejected (REF-17). |
| LED-24 | Trend warning chip and axis labels legible on the default background | TMP R-A11Y-02 | implemented: #109 | Gutters, a scrim, a dark capsule with `#FFD60A`. Was rated high. |
| LED-25 | Butt line caps keep dash gaps visible | TMP R-VIS-06 | implemented: #109 | Restores the secondary encoding for same-hue series. |
| LED-26 | Trend time-axis ticks | TMP R-UX-21 | implemented: #109 | Pure `TrendAxisTicks`. |
| LED-27 | Linux threshold, reset and auth alerts | TMP R-LNX-21 | implemented: #110 | `QuotaEvents.detect` (20%/5% crossings, resets, auth failures), dedup state in a `0600` file, opt-in `--notify`/`--on-event`/`LLIMIT_NOTIFY`, hook examples. Converge with #100 on one QuotaCore evaluator (PRD-04, WID-04). Refresh/timer alerts and `llimit paths`: DEBT-06. `QuotaEvents.observedReset` is the building block for IDEA-02, IDEA-06, IDEA-11. |
| LED-28 | Bottleneck caption names the actual limiting metric | MAIN ledger #67 | implemented: #67 (MAIN-owned) | Relevant to MAC-04, MAC-13, MAC-26. `APP/LLimitApp.swift` conflicts with #95/#96/#102/#103/#106. |
| LED-29 | Safe messages for new failures | MAIN ledger #70 | implemented: #70 (MAIN-owned) | Integrate before #69 (Muse overlap). Historical migration, structured fields, widget DTO: COR-06; compare #63's excerpts. |
| LED-30 | Quota schema validation: Cline `percentUsed` and Muse windows | MAIN ledger #69, A01, A02; TMP R-BUG-37 | implemented: #69 (MAIN-owned) | TMP R-BUG-37 is the same defect as A01; no separate work. Stacked on #70. Muse parsing interacts with PRV-13. |
| LED-31 | Dashboard widget shows attributable values and truthful states | MAIN ledger #72, W01, W02, W03 (dashboard) | implemented: #72 (MAIN-owned) | Overlaps #54, #80 (ORD-01). Per-account age: WID-05. Tile and trend load outcomes: WID-03. |
| LED-32 | History stores source fetch time, not publication time | MAIN ledger #75, C02 | implemented: #75 (MAIN-owned) | Covers the history half of R-BUG-27 (COR-08). Reconcile with #52/#76 (LED-34). |
| LED-33 | `llimit resets` | MAIN ledger #51 | implemented: #51 (MAIN-reported, unverified) | macOS and tray surfaces: PRD-07, LNX-17. #88 also reports a reset listing. |
| LED-34 | History skips repeated readings | MAIN ledger #52, #76 | implemented: #52, #76 (MAIN-reported, unverified) | Reconcile with #75 before integrating (LES-02); #76's timestamp folding conflicts. Eases PRF-03. Conflicts with #94. |
| LED-35 | Selectable limit-color palettes | MAIN ledger #53 | implemented: #53 (MAIN-reported, unverified) | CONTRADICTION with TMP's rejected color-pack idea; validate every palette (WID-09). Canonical writes: MAC-20. Theme preview: PRD-14. Shares drawing code with #96, #109. |
| LED-36 | Cause-specific widget failure states | MAIN ledger #54 | implemented: #54 (MAIN-reported, unverified) | Overlaps #72, #80. Check the trend empty state #109 touches (overlap 16). |
| LED-37 | Distinct provider glyphs | MAIN ledger #55; TMP R-THM-05 | implemented: #55 (MAIN-reported, unverified) | Fully covers R-THM-05 if #55 lands. TMP evidence to check #55 against: `ProviderMark` (`APP/LLimitApp.swift:1489-1514`) gave Copilot, OpenCode Go and Cline `chevron.left.forwardslash.chevron.right` and Zhipu and Z.ai `bolt.fill`, tinted by account accent. TMP proposed macOS 14 symbols (Copilot `airplane` or the chevrons, OpenCode Go `curlybraces`, Cline `point.3.connected.trianglepath.dotted`, Z.ai `z.square.fill`) and an optional debug assertion that no two providers share a symbol. |
| LED-38 | Settings accessibility labels | MAIN ledger #56 | implemented: #56 (MAIN-reported, unverified) | Widget semantics and native AX: MAC-04, MAC-08. |
| LED-39 | Venice-only estimate dispatch | MAIN ledger #57 | implemented: #57 (MAIN-reported, unverified) | Claimed cross-provider bug not confirmed. |
| LED-40 | Quota weather dashboard header | MAIN ledger #58 | implemented: #58 (MAIN-reported, unverified) | Per-account outlook and Fog: IDEA-13. |
| LED-41 | Overview recommendation trophy | MAIN ledger #59 | implemented: #59 (MAIN-reported, unverified) | Share one ranking with #108 (PRD-06). |
| LED-42 | Bounded, scrubbed provider error excerpts | MAIN ledger #63 | implemented: #63 (MAIN-reported, unverified) | Reconcile with #70's allowlist (COR-06). |
| LED-43 | Status renderer account identity and failure keys | MAIN ledger #64 | implemented: #64 (MAIN-reported, unverified) | OVERLAP with #105 (LNX-01): one additive key set. |
| LED-44 | Client hardening batch | MAIN ledger #65 | implemented: #65 (MAIN-reported, unverified) | Touches COR-04, COR-06 (`.api` bodies), PRV-10, PRV-15, PRV-23, PRV-27, PRF-12. Consistent with REF-02. |
| LED-45 | Owner-only atomic writes for settings, snapshot and history | MAIN ledger #71, #74 | implemented: #71, #74 (MAIN-reported, unverified) | Directories, owner/symlink checks, App Group mode: SEC-02. |
| LED-46 | Floating dashboard chrome matches its content | MAIN ledger #73; TMP R-VIS-13 | implemented: #73 (MAIN-reported, unverified) | Different fix from TMP's; either removes the mismatch. TMP's alternative, if #73 is dropped: `panel.appearance = NSAppearance(named: .darkAqua)`, `panel.backgroundColor` set to `DashboardPalette.backgroundTop`, optionally `.fullSizeContentView` with a hidden title and about 28 pt for the traffic lights; manual check in Light, Dark and Increase Contrast (baseline evidence in MAC-16). Light-surface validation: MAC-16; dark-only contrast numbers: MAC-06. |
| LED-47 | Retry-After cooldown | MAIN ledger #77 | implemented: #77 (MAIN-reported, unverified) | Reuse `retryAt` (COR-06). Other clients and scheduling: PRF-05, PRF-01. |
| LED-48 | Corrupt snapshot/history quarantine | MAIN ledger #78 | implemented: #78 (MAIN-reported, unverified) | Likely covers #94's deferral (PRF-04). Settings recovery: COR-07. Logging: DEBT-01. |
| LED-49 | App Group SnapshotStore init no longer force-unwraps | MAIN ledger #79; TMP R-DEBT-04 | implemented: #79 (MAIN-reported, unverified) | Tile/trend load outcomes: WID-03. |
| LED-50 | Dashboard widget all-failed/no-data/no-accounts states | MAIN ledger #80 | implemented: #80 (MAIN-reported, unverified) | Overlaps #72, complements #54. Owners: WID-05 (per-account age), WID-12, MAC-04, DEBT-03, MAC-24. |
| LED-51 | OpenCode Go rate-limited windows render as exhausted | MAIN ledger #81 | implemented: #81 (MAIN-reported, unverified) | Hidden exhausted window on tiles: WID-01. |
| LED-52 | Near-reset ring glow | MAIN ledger #82 | implemented: #82 (MAIN-reported, unverified) | Probably `4768e74`; verify. Reduce Motion: MAC-07. Observed reset: IDEA-06. |
| LED-53 | `llimit version` and account data-state summaries | MAIN ledger #83 | implemented: #83 (MAIN-reported, unverified) | JSON listing and other CLI gaps: LNX-11. |
| LED-54 | Anthropic and Kimi schema-drift hardening | MAIN ledger #84 | implemented: #84 (MAIN-reported, unverified) | Same parser as #93 (rebase); covers COR-10. |
| LED-55 | Settings save debounce | MAIN ledger #85 | implemented: #85 (MAIN-reported, unverified) | Partial overlap with #101. Off-main-actor I/O: PRF-02. |
| LED-56 | `env:NAME` credential references | MAIN ledger #86 | implemented: #86 (MAIN-reported, unverified) | Partial answer to SEC-06; must survive #104, COR-05, SEC-01. |
| LED-57 | PaceEstimator and dropdown burn-rate ETA | MAIN ledger #87 | implemented: #87 (MAIN-reported, unverified) | OVERLAP with #109 `QuotaForecast` and #103 `QuotaPace`: three estimators in QuotaCore; converge (PRD-01, PRD-02). |
| LED-58 | Linux history readers and compact output | MAIN ledger #88, #98; TMP R-LNX-22 | implemented: #88, #98 (MAIN-reported, unverified) | Together they resolve R-LNX-22 (history is now readable). TMP's R-LNX-22 acceptance to check them against: history rows (time, account, provider, metric, remaining, resetAt) deduped by (account, metric, `fetchedAt`) (BND-08); a 24 h sparkline of 12 to 24 buckets (last value per bucket) with an ASCII fallback outside UTF-8; tests for bucketing, reset jumps, carried-value dedupe and CSV escaping. TMP's fallback if neither ships: stop appending history on Linux (`LD/QuotaDaemon.swift:319-323`). Compact output partly overlaps #108 (LNX-10). Verify exact flags. |
| LED-59 | Detected Claude Code version in the usage User-Agent | MAIN ledger #91 | implemented: #91 (MAIN-reported, unverified) | CLI discovery: PRV-05 (#107). Version compatibility: PRV-28. |
| LED-60 | `llimit status --watch` | MAIN ledger #99 | implemented: #99 (MAIN-reported, unverified) | OVERLAP with #108; keep one. |
| LED-61 | macOS threshold and failure notifications | MAIN ledger #100 | implemented: #100 (MAIN-reported, unverified) | OVERLAP with #110. Quiet hours, Focus, reset notices, shared policy: PRD-04, WID-04. |
| LED-62 | AUTO/ESTIMATED badge legibility | MAIN ledger (unnumbered badge change) | implemented: unnumbered MAIN-reported change (unverified) | Covers the badge part of R-THM-07 (PRD-15). |

## Boundaries every follow-up must preserve

These entries are standing constraints, not tasks. They merge MAIN's six boundary
bullets (BOUNDARY-1..6), the AGENTS.md hard constraints, and cross-cutting rules
that TMP states inside individual findings. They have no inventory sources;
"open" means the rule is in force. Check every follow-up in the later sections
against them before coding and again in review. Code lines refer to baseline
`2d6ac1e`; AGENTS.md lines refer to the baseline copy of that file.

### BND-01 Credentials stay local; every display surface is credential-free

- **Status / severity / effort / platform:** open (rule in force) / standing
  constraint on every change that writes, displays, logs, exports or copies data /
  no effort of its own / both platforms. Redaction and store checks are
  Linux-testable in QuotaCore and LLimitd; App Group and widget checks are macOS-only.
- **Sources:** AGENTS.md hard constraints (`AGENTS.md:102-108`); MAIN BOUNDARY-1,
  C01, C06, C09, reported #63, #65, #70, #71, #74, #86; TMP R-FEAT-01, R-LNX-01,
  R-LNX-06, R-LNX-07, R-LNX-14, R-LNX-21, R-DEBT-01, R-DEBT-02, R-SEC-07, R-UX-07,
  R-IDEA-02, R-IDEA-03, R-IDEA-04, R-IDEA-05, R-IDEA-09, R-IDEA-10.
- **Problem and evidence:**
  - The rule: the settings file is LLimit's only credential store
    (`~/Library/Application Support/LLimit/` on macOS,
    `$XDG_CONFIG_HOME/LLimit/quota-settings.json` on Linux, mode 600). Managed
    Claude/Codex profiles are the only exception (BND-04). Anything written to the
    App Group/widget store, snapshot/history files, `llimit status` output or logs
    goes through `AppSettings.redactedCredentials()`. Display surfaces never need
    credentials.
  - Redaction covers only the settings copy. `ProviderAccount.redactedCredentials()`
    empties `credentials` (`QC/Models.swift:477-485`); `AppSettings.redactedCredentials()`
    keeps interval, accounts, styles, visibility and tile slots (`:1477-1487`). The
    app syncs it at `APP/AppModel.swift:173`, `:454`, `:480`, `:885`, `:1052`.
    QuotaCore tests assert empty credentials (`ClaudeCodeProfileTests.swift:200`,
    `CodexAccountProfileTests.swift:150`, `VeniceIntegrationTests.swift:46`,
    `ClineIntegrationTests.swift:42`, `OpenCodeGoIntegrationTests.swift:30`,
    `PrimaryLimitColorTests.swift:46`).
  - Failure text is the path redaction does not cover. `QC/QuotaCoordinator.swift:59-81`
    copies `ProviderClientError.message` and `error.localizedDescription` into
    `ProviderFailure`; `QC/Clients/ChatGPTOAuth.swift:41-46` included refresh
    response text (MAIN C01). TMP R-DEBT-02 lists the body-echo sites: Anthropic
    `:58`, OpenAI `:53`, ChatGPTOAuth `:45`, Copilot `:79`/`:220`/`:278`, Devin
    `:85`/`:87`, Google `:112`/`:138`, Kimi `:68`/`:71`, Zhipu `:40`/`:50`, Muse
    `:73`/`:75`/`:123`. Snapshots and history persist these strings.
  - Baseline file modes: `QC/SnapshotStore.swift:43` and `QC/QuotaHistoryStore.swift:52`
    chmod 0644 although the files hold account names and raw failure bodies;
    `QC/SettingsStore.swift:24-33` creates parents unrestricted, writes atomically,
    then ignores a failed chmod 600 (R-SEC-07, MAIN C09). Ubuntu 21.04+ homes are
    0750, which limits exposure.
  - `ProviderUsage.subtitle` can hold an email (Antigravity), so it is not
    display-safe outside the dropdown card (R-FEAT-01 verifier correction).
  - Reported, not verified here: #70 safe provider/OAuth messages, configured-secret
    redaction and bounds for new failures; #63 about 200-character whitespace-folded
    excerpts with Bearer/JWT/API-key scrubbing (scrubbing alone does not cover
    unknown reflected secrets or old persisted errors); #65 says `.api` includes
    response bodies, which conflicts with #70; #71 settings `O_CREAT|O_EXCL` 0600,
    `fchmod`, fsync, rename and `stat` check; #74 0600 temporary file before rename
    for snapshot/history; #86 `env:NAME` references resolved at runtime and
    preserved through OpenAI rotation and adoption. Historical archives are not
    migrated (COR-06).
- **Proposal (rules every follow-up obeys):**
  1. Never put a credential, a resolved `env:NAME` value, a subtitle, a raw failure
     message or a response body into App Group data, widgets, snapshot/history,
     new state files, Linux JSON, notifications, hook environments, status lines,
     MCP results, exports or the clipboard. New state files (`usage-ledger.json`,
     `alerts-state.json`, `hook-state.json`, the macOS snapshot mirror) are
     credential-free and mode 600.
  2. Failures cross a display boundary only as kind, status code, fixed or
     allowlisted public text, and account title. Any remaining text is sanitized:
     first line only, control characters stripped, whitespace collapsed, capped at
     about 160 characters with "…" (R-LNX-07). MAIN's target is a bounded
     widget/display DTO with raw diagnostics kept transient. Client errors use
     fixed text with `statusCode` always set and never a body (R-DEBT-02).
  3. Logs: error kinds and status codes public; paths, names and descriptions
     private (`os.Logger`); never credentials, settings file contents or response
     bodies (R-DEBT-01, R-LNX-06, R-LNX-14). Sync diagnostics go through a
     `reportPersistenceIssue`-style logger with safe structured fields, not stdout
     (MAIN C06). Hooks are exec'd without a shell and receive only `LLIMIT_EVENT`,
     `LLIMIT_ACCOUNT_ID`, `LLIMIT_ACCOUNT_NAME`, `LLIMIT_PROVIDER`, `LLIMIT_METRIC`,
     `LLIMIT_REMAINING`, `LLIMIT_RESET_AT`, `LLIMIT_FAILURE_KIND` (R-LNX-21).
  4. Do not exempt short configured secrets from redaction (rejected in #70 review).
  5. Copying failure text to the clipboard waits for COR-06 ("Copy failure text
     only after the redaction boundary lands", R-UX-07). A credential-free Copy
     Usage Summary formatter in QuotaCore, shared with StatusRenderer, is fine now.
  6. Reuse the #71/#74 secure-write helpers instead of rebuilding them. Local
     credential directories are 0700; the App Group keeps the narrowest mode the
     sandboxed widget can read (MAIN C09).
  7. Agent-facing outputs (R-IDEA-09) tell the agent's model provider which
     subscriptions exist, and some free models train on prompts: default to
     aliases and minimal fields.
  8. Cross-process writes to the settings file go through `SettingsLock`, held
     only around the load and the merge-save, never across a network fetch
     (AGENTS.md layout; MAIN C04).
- **Tests / acceptance:** for any change that touches a boundary, a sentinel placed
  in credentials, an `env:NAME` value, a subtitle and a response body never appears
  in persisted snapshot/history/state files, App Group settings, `status` or
  `status --json`, notifications, hook environments or captured logs. Existing
  `redactedCredentials()` tests keep passing. Store files are 0600, directories
  0700, and no public temporary file appears (R-SEC-07, MAIN C09). Old Codable
  records still decode.
- **Relations:** COR-06 (historical failure migration, structured fields, display
  DTO); SEC-02 (file and directory modes, systemd `UMask`); DEBT-01 (structured
  logging); BND-02, BND-04. Reconcile #63, #65 and #70 before adding any new
  failure-text surface. #105 (R-LNX-07 sanitizing) and #64 (`error` key) both add
  failure text to Linux JSON; #110's hook variables follow rule 3.

### BND-02 The Linux bar contract is snapshot-only and additive

- **Status / severity / effort / platform:** open (rule in force) / standing
  constraint on every Linux display change / no effort of its own / Linux;
  Linux-testable (`StatusRendererTests`, tray `unittest`).
- **Sources:** AGENTS.md data flow (`AGENTS.md:97-100`) and LLimitd layout; MAIN
  BOUNDARY-1, L01 (#66), L02, L11; TMP R-LNX-01, R-FEAT-01, R-BUG-04, R-LNX-02,
  R-LNX-06, R-LNX-07, R-LNX-14, R-UX-09, R-IDEA-01, R-IDEA-03, R-IDEA-04, R-IDEA-06,
  R-IDEA-07, R-IDEA-08, R-IDEA-09, R-IDEA-13, R-IDEA-17, Shared building blocks
  (snapshot enrichment); LEDGER #104, #105, #108.
- **Problem and evidence:**
  - The rule: bars poll `llimit status --json`, which renders the snapshot, never
    the settings file, into the waybar-style contract (`text`, `tooltip`, `class`,
    `percentage`, plus `accounts`). The example modules are pure config: adding a
    key is fine, renaming is not.
  - Baseline violation: `CLI/main.swift:45-49` (`makeDaemon()` loads configuration)
    and `:332-339` (`runStatus` builds a full daemon), so every bar poll loads
    credentials. With an unreadable settings file the first poll wiped the
    snapshot, reproduced with the built binary: `status --json` returned
    `class: empty` and the snapshot on disk had `providers: []` (R-BUG-04, MAIN
    L01). Bootstrap reconciliation could erase usage and save logs contaminated
    JSON stdout (MAIN L01); `[llimitd]` log lines went to stdout (R-LNX-14).
  - ERROR lines print `failure.message` verbatim (`LD/StatusRenderer.swift:55-57`).
    Waybar's custom module defaults to `escape: false` (upstream `custom.cpp`), and
    `Packages/LLimitd/examples/waybar/llimit.jsonc:11-19` omits it, so an HTML error
    body or an account name containing "&" or "<" blanks the label or tooltip
    exactly when there is an error to show (R-LNX-07).
  - Open PRs: #66 (MAIN-owned, L01 and the Linux C03 guard) and #108 (status part
    of R-BUG-04) both make `status` snapshot-only with clean JSON stdout; keep one.
    #104's `makeDaemon` status warning becomes dead code once #108 lands; the
    second of the two to land drops it (integration fix, ledger table 1). #105
    adds `"escape": true`, sanitizes text and neutralizes polybar `%{` in error
    text (its polybar script also sanitizes its text).
- **Proposal (rules):**
  1. Display consumers (`status` in every format, `check`, `pick`, `--watch`, the
     tray, bar examples, and future status line, MCP, brief, `--explain` and macOS
     helper) read only the snapshot and credential-free sidecars. A settings-load
     error reaches `status` through a credential-free `daemon-state.json` rendered
     as class `error` (R-LNX-06), not by reading settings. Values that need
     settings or history (badges, forecasts, pace, reset stamps) are stamped into
     the snapshot by the daemon or a pure `SnapshotEnrichment` stage (R-IDEA-08,
     R-FEAT-02, Shared building blocks). Prompt-speed readers never wait on
     `SettingsLock` (R-IDEA-07).
  2. Keys are additive and optional. New `ProviderUsage` fields need explicit
     `decodeIfPresent` because its coding is custom (`QC/Models.swift:357-381`);
     `UsageMetric` uses synthesized Codable, so new optionals decode as nil.
     Keep the class strings `ok`, `warning`, `critical`, `error`, `empty`. Moving
     the 40/15 thresholds is a product decision that also updates the examples
     README (R-UX-09). A breaking shape, such as `class` as an array, stays behind
     an opt-in flag (`--class-array`) because it breaks eww and polybar readers;
     confirm the minimum waybar accepts an array (R-IDEA-06). Unverified: whether
     an added `alt` changes `{icon}` selection when `format-icons` is a
     percentage-indexed array (R-IDEA-13).
  3. Never put subtitles (Antigravity's is an email) or raw failure bodies in Linux
     JSON. Failure arrays carry id, provider, name and kind only (R-LNX-01).
  4. Text that waybar parses as Pango: the example ships `"escape": true`, failure
     text is sanitized per BND-01 rule 2, and markup output (`--graph --markup
     pango|polybar|tmux`) emits only fixed glyphs and validated `#RRGGBB` values,
     escaping names (R-IDEA-17).
  5. JSON stdout stays clean; logs go to stderr.
  6. One renderer with golden tests keeps Linux and any macOS helper output
     identical (R-IDEA-03).
- **Tests / acceptance:** corrupt settings plus a valid snapshot leave the snapshot
  bytes unchanged and `status` still renders the accounts (R-BUG-04). A
  file-access spy proves display commands never open the settings file (R-IDEA-03,
  R-IDEA-09). Old snapshot fixtures decode. Existing keys keep their names and
  types. A multi-line HTML body renders as one capped line in human output and
  tooltip; names with "&" or "<" render. stdout parses as JSON while logs are
  emitted.
- **Relations:** LNX-01, LNX-03, LNX-16; BND-01, BND-08. Overlaps to settle: #108
  vs #66 (snapshot-only status); additive key names for failures in #105 vs #64
  (`failing`/`error`/`errorKind`) and for resets/age in #105 vs #50 (`resetAt`,
  `resetSeconds`, `fetchedAt`, `ageSeconds`). Deferred additive keys: `paceDelta`
  (#103), `expiringUnused` (#110).

### BND-03 Imports are copied, LLimit-owned accounts with verified identity

- **Status / severity / effort / platform:** open (rule in force) / standing
  constraint on import, discovery, adoption and refresh-acceptance changes / no
  effort of its own / both platforms; the QuotaCore identity rules are
  Linux-testable, Keychain discovery is macOS-only.
- **Sources:** AGENTS.md overview and hard constraints (`AGENTS.md:115-117`); MAIN
  BOUNDARY-2, C07, A05, A06, A07; TMP R-SEC-06, R-BUG-40, R-LNX-03, R-IDEA-04;
  LEDGER #104.
- **Problem and evidence:**
  - The rule: LLimit owns account management. `CredentialDiscovery` is only an
    optional import shortcut; an import is copied into a new LLimit-owned account
    and needs no source tool at runtime. Linux Claude accounts use saved access
    tokens; expired imports and manual tokens need explicit reimport or replacement.
  - Claude already follows it: `ClaudeCodeProfile.adoption`
    (`QC/ClaudeCodeProfile.swift:212-243`) requires matching stored account and
    organization UUIDs, a fresher unexpired token, and either the matching profile
    id or a `linkedImport` without a profile id. An unverified legacy import cannot
    opt itself in.
  - OpenAI does not: `QC/OpenAICredentialSync.swift:36-41` matches only
    `openAIAccountID`, which is the shared workspace id for Team, Business and
    Enterprise. The daemon adopts at `LD/QuotaDaemon.swift:411-425`, and
    `refreshOpenAIAccount` (`:435-448`) overwrites the stored account id without
    comparing it (`:446-447`); app side `APP/AppModel.swift:675-714`. If `~/.codex`
    is later logged in as another user of the same workspace, LLimit adopts and
    later rotates that user's grant (R-SEC-06, MAIN C07). Managed accounts are
    excluded (`OpenAICredentialSync.swift:31`). Pasting a new OpenAI access token
    keeps the old hidden refresh token, so a later refresh undoes the edit (R-BUG-40).
- **Proposal (rules):**
  1. Never replace every Claude account with the global CLI token, and never bind
     a token or observation to "the only Claude account" (R-IDEA-04).
  2. Managed profiles match the profile UUID plus verified account and organization
     UUIDs. Identity mismatch and missing identity never merge; an older observation
     never overwrites a newer fetch (R-IDEA-04).
  3. Imports without verified identity stay unchanged until an explicit reimport.
     An established identity is immutable (MAIN C07).
  4. OpenAI adoption and refresh acceptance bind workspace and user: compare
     `chatgpt_user_id`, then `user_id`, then `sub`, as `CodexAccountProfile.parseIdentity`
     already does (`QC/CodexAccountProfile.swift:100`; TMP cites `:14-16`). Reject
     when both tokens carry the claim and it differs. If the stored token cannot be
     decoded, adopt only when exactly one candidate exists. Discard refresh results
     whose account or user id changed (SEC-01).
  5. Keep global, imported and managed provenance separate; never adopt global
     Codex/OpenCode tokens into managed accounts (BND-04); preserve `env:NAME`
     references through adoption (#86).
  6. In-place replacement (Linux reimport/`accounts set`, #104) is an explicit user
     action that keeps the account id, history, tile slots and color identity.
- **Tests / acceptance:** same account id with different user ids adopts nothing
  (R-SEC-06); a same-user fresher token is still adoptable; missing identity cannot
  retarget an account; Claude adoption fixtures reject wrong account, organization
  or profile; discovering a new global login changes no unverified import.
- **Relations:** SEC-01; BND-04. MAIN A05 (shared metadata blocks distinct imports;
  compare keyed provider-specific authenticators), A06 (an OpenCode Anthropic
  candidate suppresses Keychain discovery), A07 (Antigravity custom XDG roots and
  several accounts). TMP R-BUG-38 (Claude imports from OpenCode and the Keychain
  ignore expiry), R-BUG-41 (discovery ignores `CLAUDE_CONFIG_DIR`), R-UX-16
  (duplicate import names). #104 deferred the stored import source and carrying
  Claude `expiresAt`.

### BND-04 Managed Claude/Codex: the official CLI owns renewal

- **Status / severity / effort / platform:** open (rule in force) / standing
  constraint on managed-profile, renewal, scheduling, quit and cancellation changes
  / no effort of its own / macOS today, Linux once LNX-06 lands. The QuotaCore
  pieces (`ClaudeCodeRenewal`, `CodexProfileStore`, `CodexAccountService`) are
  Linux-testable; Keychain and terminal flows are macOS-only.
- **Sources:** AGENTS.md overview and hard constraints (`AGENTS.md:109-114`,
  `:118-127`); MAIN BOUNDARY-3, C05, C08, C10, A04; TMP R-BUG-14, R-BUG-15,
  R-BUG-16, R-BUG-17, R-BUG-43, R-SEC-05, R-LNX-04, R-LNX-18, rejected `llimit exec`.
- **Problem and evidence:**
  - The rules: Claude Code is the sole owner of refresh-token rotation and storage
    in an account-specific `CLAUDE_CONFIG_DIR` under
    `~/Library/Application Support/LLimit/ClaudeProfiles/`. LLimit caches the access
    token and verified account/organization identity, never saves Claude refresh
    tokens in settings, never alters the user's normal CLI login, passes renewal
    material only to that CLI process and never logs it. Codex owns storage and
    renewal in a private `CODEX_HOME` under `.../CodexProfiles/`; LLimit stores the
    profile reference and verified identity, never copies Codex tokens or
    app-server authentication material into settings, logs, snapshots or widgets,
    never rotates their refresh tokens itself, and verifies identity before
    committing a login or publishing usage. Directories 0700, credential files 0600.
  - Baseline mechanisms: `QC/CodexProfileStore.swift:38-62` acquires an
    `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW` 0600 `Operations/<id>.pending` record with
    fsync before launch; release is owner-only after observed child exit;
    directories 0700 at `:99-105`. `QC/CodexAccountService.swift` acquires at `:128`
    and releases at `:161`. `QC/ClaudeCodeRenewal.swift:90-92` persists
    `anthropicRenewalPending` before launching `claude auth login`; only a
    `StartFailure` (`:95-100`) removes this attempt's marker; an inherited marker
    throws `reconnectRequired` (`:74-75`). `APP/Services/ClaudeProfileService.swift:55-61`
    (0700), `:87`, `:129`, `:156` (0600).
  - Known pressure on the rule: the Claude pending marker is not an exclusive claim
    (`QC/ClaudeCodeRenewal.swift:65-94`, `APP/AppModel.swift:1035-1093`); duplicate
    launch windows are source-confirmed, server revocation was not observed (MAIN
    C05). Concurrent Linux refreshes exchange the same imported OpenAI refresh token;
    unverified whether OpenAI revokes the grant on reuse (R-LNX-04). Quitting during
    a managed fetch strands the record (R-BUG-14). Offline renewal forces a reconnect,
    a deliberate tradeoff; unverified whether Claude Code exits non-zero offline
    without reaching the token endpoint (R-BUG-15). `account/read {refreshToken: true}`
    (`QC/CodexAccountService.swift:95`) makes Codex rotate on every poll; unverified
    whether `account/rateLimits/read` refreshes by itself after a 401 (R-BUG-17).
    A leftover lock counts as live forever; Claude Code 2.1.291 uses
    proper-lockfile with `stale: 60000` (R-BUG-43). Retained profiles are never
    swept (R-SEC-05).
- **Proposal (rules):**
  1. Acquire an exclusive durable operation record before launching a CLI or
     reading renewal material (in place for Codex; COR-02 extends it to Claude and
     Linux refreshes).
  2. Timeouts, cancellation and quit keep the child and its record or marker until
     the child exits. Never replay a possibly rotated grant. A losing owner never
     clears the winner's record (MAIN C05, C10).
  3. An orphaned Codex record requires reconnecting into a fresh profile.
  4. Never delete a namespace with a pending operation; sweepers skip
     marker-bearing namespaces and live sessions (R-SEC-05).
  5. Mitigations TMP proposes that keep the rule: drain on quit with
     `applicationShouldTerminate`/`.terminateLater` and a `waitUntilIdle` that never
     kills a child, keeping the record on timeout (R-BUG-14); a network preflight
     before the marker is written (R-BUG-15); `refreshToken: false` unless expiry
     is within about 10 minutes, one forced retry, identity re-checks kept
     (R-BUG-17); lock liveness by mtime under 60 s while pending markers still
     block replay (R-BUG-43). A Linux CLI that launches app-server waits for or
     reaps the child before exiting (R-LNX-18).
  6. Keep settings locks short, persist each rotated grant before awaiting the next
     account, retain unsaved replacement material, and never overwrite `env:NAME`
     references (MAIN C08).
  7. Do not run user sessions inside managed profiles. `llimit exec` and "Open
     Terminal as…" were rejected (REF-29): a user session races renewal markers and
     lock handling (R-BUG-16, R-BUG-43), conflicts with Codex's exclusive operation
     records, and puts user transcripts in a directory that account removal deletes.
  8. Map domain failures to actionable kinds without weakening any pending-operation
     guarantee (MAIN A04).
- **Tests / acceptance:** with a slow fake app-server, drain waits for release and
  on timeout returns false with the record intact; two-process barriers launch one
  exchange or renewal; losing owners cannot clear records or delete namespaces;
  cancellation writes no snapshot/history and keeps pending children; a sweep over
  referenced, unreferenced and marker-bearing namespaces removes only the
  unreferenced unmarked ones; preflight false means no persist, no renew, no marker.
- **Relations:** applies to PRV-02..PRV-09, COR-02, SEC-03 and LNX-06; also COR-04
  (cancellation) and COR-05 (rotated grant durability). #107 (child PATH, proxy/CA
  variables, Codex probe) and #102 (refresh during sign-in) touch the launch and
  busy paths. REF-29.

### BND-05 QuotaCore stays Foundation-only, and shared rules live there

- **Status / severity / effort / platform:** open (rule in force) / standing
  constraint on where new logic lives / no effort of its own / both platforms;
  Linux-testable by construction.
- **Sources:** AGENTS.md layout (`AGENTS.md:38`) and code design (`:383`); MAIN
  BOUNDARY-4, F02, C12, build item 6 (provider metadata); TMP R-NOV-03, R-BUG-12,
  R-LNX-21, R-UX-09, R-BUG-24, R-BUG-22, R-UX-03, R-UX-05, R-UX-11, R-UX-12, R-THM-01,
  R-THM-02, R-THM-03, R-BUG-35, R-BLD-02, R-BLD-12, R-DEBT-01, R-IDEA-17, Shared
  building blocks; LEDGER #90, #92, #101, #108, #109, #110.
- **Problem and evidence:**
  - QuotaCore is a pure-Foundation package with no dependencies
    (`Packages/QuotaCore/Package.swift`); nothing under `Packages/` imports SwiftUI,
    AppKit or WidgetKit. Baseline imports are Foundation (38 files),
    FoundationNetworking (13) and Darwin/Glibc behind `#if canImport(Darwin)` in
    `QC/CodexCLIProbe.swift:2-6`, `QC/CodexProfileStore.swift:2-6` and
    `QC/CodexRPCSession.swift:2-6`. That guard had no Musl branch, so the shipped
    static `.deb` build failed with `no such module 'Glibc'` (R-BLD-02, fixed in
    #92; Musl branches in `SettingsLock.swift`/`main.swift` deferred, harmless
    because Foundation re-exports Musl).
  - The macOS app links only QuotaCore, not LLimitdCore (R-NOV-03 verifier
    correction), so a rule both platforms need must live in QuotaCore.
  - Rules stranded in UI targets escape Linux tests: `defaultPrimaryKind` sits in
    the app with `default: .weekly` and missed OpenCode Go's monthly primary
    (`APP/AppModel.swift:1500-1510`, R-BUG-35); color math in
    `Shared/LimitKindColorScheme.swift` is SwiftUI-only (R-IDEA-17);
    `AppModel.effectiveStyle` duplicates tile style (R-BUG-24); the depletion
    forecast lives in the widget (R-BUG-12).
  - QuotaCore has no logger; `QuotaDaemon(log:)` already takes a closure (R-DEBT-01).
    #90 could not log unknown Z.ai (unit, number) pairs for that reason.
- **Proposal (rules):**
  1. Put pure, shared logic in QuotaCore so `swift test` on Linux covers it. TMP's
     placements: `HeadroomRanking.rank(snapshot:filter:now:)` (R-NOV-03, #108),
     `QuotaForecast.depletionWarnings(...)` (R-BUG-12, #109), `QuotaEvents.detect`
     and `observedReset` (R-LNX-21, #110), `QuotaSeverity` (R-UX-09),
     `AppSettings.effectiveTileStyle(for:)` (R-BUG-24), `RefreshSchedule.nextDue`
     (R-BUG-22), the shared `relativeAge` (R-UX-03), `MenuBarGraph.bars` (R-UX-05),
     `AppSettings.providerTileResolution(forSlot:)` (R-UX-11), `ColorDistance` and
     the reserved accent constants (R-UX-12), the preset table (R-THM-01),
     `LimitKindColors.steppedHex` and a WCAG luminance helper (R-THM-02, R-THM-03),
     an exhaustive `defaultPrimaryWindowKind(for:)` (R-BUG-35),
     `CredentialDiscovery.supportedSources` (R-BLD-12), `BlockState`,
     `SnapshotEnrichment`, and `PendingEdits` (#101). Foundation data may live in
     QuotaCore; rendering stays in the UI (MAIN provider metadata).
  2. Platform C imports chain `canImport(Darwin)`, `canImport(Glibc)`,
     `canImport(Musl)`; the musl CI job from #92 proves it.
  3. QuotaCore takes injected log closures rather than a platform logger.
  4. UI and controllers use application services, never subprocesses, sockets,
     files or the Keychain directly; persistence is serialized behind an
     application service (MAIN F02). Fix the responsible boundary; no broad
     architecture rewrite is implied, and no layers that only forward calls.
  5. Adding a `QuotaProvider` case breaks six exhaustive switches
     (`Models.displayName`, `Models.credentialFields`,
     `ProviderMetricSelection.defaultRingMetrics`, the widget's `compactProviderName`,
     `ProviderTile.palette`, `ProviderMark.symbolName`); `defaultPrimaryKind(for:)`
     still has a `default:` (R-BUG-35 proposes making it exhaustive and updating
     the AGENTS.md list). Consolidate provider metadata one genuine duplication at
     a time (DEBT-05).
- **Tests / acceptance:** each new shared rule ships QuotaCore unit tests that run
  in Linux CI; the static musl release build stays green; no SwiftUI, AppKit or
  WidgetKit import appears under `Packages/`.
- **Relations:** one ranking for #108 `HeadroomRanking` and #59's overview trophy;
  one forecast for #109 `QuotaForecast` and #87 `PaceEstimator`; one pace model for
  #103 and #87; one event engine for #110 `QuotaEvents` and #100
  `QuotaAlertEvaluator` (two engines, two threshold sets today). DEBT-01, DEBT-02
  (MAIN C12 registration), DEBT-05; BND-06 (color math move).

### BND-06 Color is window and account identity, never danger or brand

- **Status / severity / effort / platform:** open (rule in force) / standing
  constraint on color, palette, ordering and account-identity changes / no effort
  of its own / both platforms. Order and step logic in QuotaCore is Linux-testable;
  rendering is macOS-only; the palette validator is a script today (TMP suggests
  porting it to a Linux-runnable test under R-THM-03).
- **Sources:** AGENTS.md color semantics (`AGENTS.md:300-333`); MAIN BOUNDARY-5, M07,
  M08, M11, M13, W04, product notes; TMP R-UX-01, R-UX-04, R-UX-05, R-UX-10,
  R-UX-12, R-THM-01, R-THM-02, R-THM-03, R-A11Y-01, R-BUG-34, R-BUG-44, R-VIS-02,
  R-NOV-01, R-NOV-02, R-IDEA-01, R-IDEA-08, R-IDEA-12, R-IDEA-13, R-IDEA-17,
  rejected "Validated limit-color packs".
- **Problem and evidence:**
  - The rule: identity surfaces (chart lines, sparklines, quota bars, tile and
    dropdown rings, the menu bar graph) wear the metric's window color from
    `LimitKindColors` via `QuotaWindowKind.classify` and
    `Shared/LimitKindColorScheme`, never repainted by the current value. Each
    account wears a variant (`accountColorStep`: base/deep/pale) ranked over all
    accounts in `stableAccountOrder` (`QC/ProviderMetricSelection.swift:168-209`:
    provider, then display name, then id; `index % 3`). Tiles double as the trend
    legend; the chart deliberately has no legend. Menu bar bars wear the account's
    primary (longest bounded window) color, follow the persisted Settings order and
    carry level in height. Magnitude is geometry; danger is the reserved accents.
    `WidgetRingColors` (`QC/Models.swift:564`) is compatibility-only.
  - `primaryLimitSlot` (`QC/ProviderMetricSelection.swift:87`) picks the longest
    bounded window from the full metric list; `ProviderStyleSettings.primaryHexColor`
    (`QC/Models.swift:1116`) renders exactly as chosen on that slot across rings,
    bars, sparklines and trend lines; other slots keep automatic colors and
    variants; unlimited and warning colors stay reserved.
  - Validation: CVD all-pairs ΔE at least 12 for the six base hues and at least 8
    with secondary encoding for the base+deep twelve, chroma at least 0.10, at
    least 3:1 on graphite. The deep formula in `LimitKindColorScheme.steppedColor`
    (`Shared/LimitKindColorScheme.swift:66-119`: darken 36% toward near-black,
    re-spread channels 1.5x) is part of what was validated.
  - Known gaps whose fixes must respect the rule: adding or renaming accounts
    recolors others and a fourth account repeats the first, which conflicts with
    "never share an exact scheme" (rename stability is not promised; AGENTS.md
    covers reorder and toggle only) (R-UX-01); raising the modulus fails because
    higher steps all become pale (MAIN W04); deep variants measure 1.03 to 1.09:1
    on `#5994F2` (R-THM-02); five of six pale variants have chroma 0.060 to 0.086,
    below the 0.10 floor (blend at `Shared/LimitKindColorScheme.swift:83-84`,
    R-THM-03); vibrant and monochrome widget rendering turns session (luminance
    0.564) and weekly (0.598) into the same gray (R-A11Y-01); the "empty"
    placeholder takes the primary slot and paints `#B8A8FF` (R-BUG-34); both
    Antigravity rings get `#B8A8FF` and aux colors shift when a model is missing
    (R-VIS-02); a provider-keyed legacy style copies one primary to two
    same-provider accounts (MAIN M13); presets ship ring palettes that are never
    drawn (R-THM-01, MAIN M07); direct `LimitKindColors` assignments bypass
    normalization (MAIN M08).
- **Proposal (rules):**
  1. Never use hue for danger, freshness or brand. Severity uses the reserved
     accents on text, chips, caps, outlines or footers: reserved red only for an
     outline and chip, never a ring fill (R-IDEA-01); failing or stale menu bars at
     reduced alpha with a 1 pt reserved-orange cap (R-UX-05); danger as a cap or
     outline per column (R-IDEA-17); only Storm text may use the warning accent
     (R-IDEA-13); badges are monochrome glyphs, never a second color channel
     (R-IDEA-08); pace ticks are neutral geometry (R-NOV-01); the "use it" chip adds
     no hue (R-NOV-02); a recent-bite segment needs a hatch texture, not a plain
     tint (R-IDEA-12); ring hues stay identity when severity is added (R-UX-10).
     Thresholds never recolor identity rings or traces, and provider brand metadata
     is not window/account identity (MAIN).
  2. Reordering, disabling or enabling never changes `stableAccountOrder`,
     automatic tile assignments or variants. Any persisted identity (R-UX-01's
     `colorVariant` or an append-only `stableAccountRanks`) seeds from today's order
     at decode so existing users see no change. A second channel for four or more
     accounts uses marker shapes, not new hues, and adds no in-chart legend.
  3. Custom colors render exactly as chosen, so collision checks only warn
     (R-UX-12). Accounts with no limit window have no primary slot; disable the
     picker instead of inventing one (R-BUG-44).
  4. Keep the three validated variants. Any new variant, palette (#53's palettes,
     theme packs), default hex or formula change reruns the dataviz validator
     against `#1D1F27` and `#5994F2` (WID-09). No palette pack ships until the pale
     variant passes.
  5. Non-full-color widget modes get secondary encoding (a stroke style per kind,
     `.widgetAccentable()`) with hues unchanged (R-A11Y-01).
  6. New provider metrics with a reset cadence use labels `classify` understands
     ("N-hour", "N-day", "weekly", "monthly") or get a special case next to
     Copilot's `premium`.
- **Tests / acceptance:** adding, renaming, reordering or disabling accounts leaves
  existing variants and automatic tiles unchanged; legacy settings decode to
  today's steps; twelve accounts give twelve distinct identities; validator output
  passes for every variant on both surfaces; the validated defaults report no
  collisions.
- **Relations:** WID-09; COR-10 (placeholder slot); BND-05 (color math into
  QuotaCore); BND-07. #53 (palettes), #96 (menu-bar track and failure drawing;
  deferred R-UX-04 dashboard order vs bars), #103 (pace ticks).

### BND-07 Widget kinds frozen, slots app-owned, extension sandboxed

- **Status / severity / effort / platform:** open (rule in force) / standing
  constraint on widget, project and release changes / no effort of its own /
  macOS-only.
- **Sources:** AGENTS.md hard constraints (`AGENTS.md:128-132`) and widget
  registration (`:262-296`); MAIN BOUNDARY-6, build item 1, W13; TMP R-BLD-03,
  R-UX-11, R-THM-04, R-IDEA-03, R-IDEA-06, R-IDEA-15, rejected ideas.
- **Problem and evidence:**
  - Kinds: `Shared/SharedConstants.swift:14-41` spells twelve literal
    `ch.lkmc.llimit.widget.provider-tile.slotN` kinds and asserts their count equals
    `AppSettings.providerTileSlotCount` (12, `QC/Models.swift:1374`); with the
    dashboard and trend there are 14 kinds. `ProviderTileSlot1Widget` to
    `ProviderTileSlot12Widget` (`WX/ProviderQuotaWidget.swift:19-85`) sit in nested
    bundles (`WX/LLimitWidgetBundle.swift:5-34`) because `WidgetBundleBuilder` takes
    at most ten widgets per block. `scripts/build.sh:88-90` and
    `scripts/widget-diagnostics.sh:86-91` loop slots 1 to 12 and grep the binary
    for whole kinds.
  - Display names: `WX/LLimitQuotaWidget.swift:13`, `:27` use literals and
    `WX/ProviderQuotaWidget.swift:107` uses `Text(verbatim:)`. An interpolated
    string becomes a formatted `LocalizedStringKey`; WidgetKit fatal-errors at
    extension launch and the gallery empties.
  - Versions: `project.yml:41` and `:81` set `CURRENT_PROJECT_VERSION: 37` for both
    targets, and `:40` sets `REGISTER_WITH_LAUNCH_SERVICES: NO`. R-BLD-03:
    `.github/workflows/release.yml:44` stamps CFBundleVersion from
    `github.run_number`; LLimit-1.0.1.zip has CFBundleVersion 2 in app and extension
    while project.yml had 20 at that tag and main has 37, so a release installed
    over a dev build lowers the version; lkm-release bumps only `MARKETING_VERSION`.
    Verifier: practical impact is limited because releases are ad-hoc signed
    without the App Group.
  - Sandbox: the host app is not sandboxed because import reads `~/.claude`,
    `~/.codex`, `~/.config/github-copilot`, `~/.kimi`, `~/.kimi-code`, `~/.gemini`,
    `~/.local/share/opencode`, `~/.local/share/devin`, `~/.config/muse`, `~/.venice`,
    `~/.cline` and the Keychain. The extension is sandboxed
    (`LLimitWidgetExtension.entitlements:5`) and reads only the App Group container.
- **Proposal (rules):**
  1. Placed kinds are frozen literals, never built by interpolation, so install
     gates can grep them. Renaming a widget title does not change its kind (R-THM-04).
  2. No widget-side configuration: no `AppIntentConfiguration`,
     `WidgetConfigurationIntent` or Edit flow without new evidence (Edit never
     worked across builds 7 to 13). Slot assignment stays in Settings → Widgets
     (`AppSettings.providerTileSlots`); previews and copy explain the mapping instead
     (R-UX-11). Quota/refresh automation intents are a separate proposal; TMP
     rejected Shortcuts entities until basic read and refresh intents exist.
  3. Changing the slot count updates `providerTileSlotCount`, the slot widget
     types, `providerSlotWidgetKinds`, the nested bundles and both script loops
     together.
  4. `configurationDisplayName` and `description` stay literals or `Text(verbatim:)`.
  5. App and extension share one monotonic `CURRENT_PROJECT_VERSION`, bumped
     whenever the `WidgetBundle` catalog changes. Releases must not override it
     (R-BLD-03: drop the override, gate on tag vs `MARKETING_VERSION` and on equal
     app/appex CFBundleVersion, set `RELEASE_POST_BUMP`).
  6. Keep `REGISTER_WITH_LAUNCH_SERVICES: NO`, the recursive `lsregister` cleanup
     and registration, the `chronod` restart and the NotificationCenter restart in
     `scripts/build.sh --install`. Registering both the intermediate and installed
     app creates duplicate `pluginUUID`s and "Bundle version did not match".
  7. A new widget kind costs a version bump and install-gate updates; prefer a view
     in an existing widget or the in-app history. TMP rejected the Spotlight
     widget, Reset Clock widget, window burn-down widget and usage calendar dot
     strip on this basis (REF-05, REF-34..REF-36); R-IDEA-15 adds a small kind only
     if its dropdown row proves useful.
  8. The extension stays sandboxed and reads only the App Group. Widgets run no
     continuous animations (`repeatForever` reported in `4768e74`, unverified,
     R-IDEA-06). A Terminal process reading another app's Group Container probably
     triggers macOS 15's prompt (unverified), so R-IDEA-03 mirrors the snapshot to
     Application Support instead.
  9. Widget deep links (`.widgetURL`, MAIN W13) need an app URL scheme first,
     credential-free URLs, frozen kinds, and no silent account mutation or login
     switch.
- **Tests / acceptance:** install gates find all 14 kinds and 12 slot types in the
  installed binary; app and extension CFBundleVersion are equal and increase; the
  release gate fails on a mismatch; all kinds appear in the gallery after install.
- **Relations:** BLD-02 (signed, widget-capable distribution), BLD-04
  (CFBundleVersion); BND-06. #95, #96 and #109 touch widget code; the current
  `feat/reset-celebration` branch (`4768e74`) edits tile rings.

### BND-08 Observation honesty

- **Status / severity / effort / platform:** open (rule in force) / standing
  constraint on freshness, reset, history, forecast and estimate displays / no
  effort of its own / both platforms; the pure rules are Linux-testable.
- **Sources:** TMP Shared building blocks (observed reset), R-BUG-02, R-BUG-08,
  R-BUG-12, R-BUG-18, R-BUG-21, R-BUG-27, R-VIS-10, R-LNX-01, R-LNX-14, R-LNX-22,
  R-NOV-01, R-NOV-02, R-IDEA-01, R-IDEA-04, R-IDEA-06, R-IDEA-09, R-IDEA-12,
  R-IDEA-13, R-IDEA-14; MAIN lessons, C02 (#75), W01 (#72), W06, W10, W14, L02, L04,
  M03, product notes, reported #51, #76, #82, #87, #98; AGENTS.md Venice and Cline
  notes.
- **Problem and evidence:**
  - `QC/SnapshotMerge.swift:12-31` (`mergingStaleUsage(from:)`, no clock) carries a
    failing account's previous `ProviderUsage` unchanged, including metrics whose
    `resetAt` has passed; `resetIn` is a string fixed at fetch time
    (`QC/Models.swift:268`). Expired Linux Claude imports carry their last 5-hour
    value (for example 8%) indefinitely into `percentage` and `critical` (R-BUG-08).
  - History points are stamped with `generatedAt`, so carried usage looks fresh by
    date; freshness must use `ProviderUsage.fetchedAt` (R-BUG-12). Single-account
    refreshes set `generatedAt` to now and append other accounts' old values
    (`APP/AppModel.swift:274-297`, `:316-347`, `:907-927`; R-BUG-27). Sparklines
    extend stale values to now (`APP/LLimitApp.swift:1427-1441`, R-VIS-10). Linux
    "Updated just now" comes from `generatedAt` (R-LNX-01). C02 (source-fetch-time
    history) is retired in #75.
  - Tiles keep the pre-reset ring at the `resetAt` entry and the dashboard shows
    the stale percentage with no marker (`WX/ProviderQuotaWidget.swift:189-195`,
    `:610-623`, `:778-781`; R-BUG-21).
  - Unknown rendered as full: a placeholder with `maxUsagePercent: 0` renders 100%
    remaining (`APP/LLimitApp.swift:1664-1679`, `WX/LLimitQuotaWidget.swift:636-651`)
    for exhausted Devin windows (R-BUG-02) and Antigravity catalog renames
    (R-BUG-18). W01 is retired in #72. W10: "Unlimited plans only" appears with an
    unknown premium quota.
  - Reported for `4768e74` (this branch; unverified in TMP): Reset Celebration
    glows whenever `abs(resetAt - entry.date) < 300 s`, which also lights stale data
    that never reset. #82's near-reset pulse is anticipation, not verified
    replenishment.
- **Proposal (rules):**
  1. Never declare a reset from the clock alone. `QuotaEvents.observedReset(previous:current:)`
     is true only when the current `ProviderUsage` is fresh (its `fetchedAt` is
     later than the previous one), its `fetchedAt` is later than the previous
     metric's `resetAt`, and `resetAt` moved forward or remaining rose by more than
     4 points. Between a passed `resetAt` and a fresh fetch, show "reset due"
     (`.resetPending`), never the old value (R-BUG-21, R-IDEA-01). A carried metric
     past its reset gets nil `remainingPercent` and `estimatedTotal`, cleared
     `resetIn`, and a recomputed `maxUsagePercent` (nil when no bounded metric
     remains) (R-BUG-08).
  2. Carried or stale values are not fresh observations: they never stamp resets,
     never feed forecasts, recent-bite marks or refresh summaries, never raise the
     Linux class above `warning`, and never append as new history samples
     (R-BUG-08, R-IDEA-06, R-IDEA-12, R-LNX-01, R-LNX-14). History readers dedupe by
     (account, metric, `fetchedAt`); TMP calls the dedupe required (R-LNX-22). An
     older observation never overwrites a newer fetch (R-IDEA-04). Health claims
     count only fresh covered accounts (MAIN).
  3. Unknown is not zero and never renders as full. Aggregate usage stays nil with
     no bounded metric. Unknown premium plus unlimited chat never reads
     "unlimited only" (MAIN W10). Clients round to whole percents, so 0 can hide a
     fraction: say "limit reached" and never disable anything (R-IDEA-01).
  4. A missing snapshot is not an empty schedule; a stale radar is not a fresh
     all-clear; passed reset dates stay "reset due" until replenishment is observed
     (MAIN lessons, #51).
  5. Forward fill (#98) and timestamp folding (#76) never create samples;
     publication time never becomes observation time; fresh equal readings must not
     disappear (MAIN, #52/#75/#76).
  6. Forecasts use fresh current-reset-segment observations taken before display
     sampling, gated on: metric present in the latest snapshot, no current failure,
     `fetchedAt` within 2x the refresh interval, the latest snapshot's `resetAt`,
     and depletion after now (R-BUG-12). Weak data reads as "fog", not a guess:
     data older than 2 intervals, fewer than 4 fresh samples, an estimated
     percentage, or a failing account (R-IDEA-13). Unattended guards never act on a
     stale snapshot (R-IDEA-14). Agent-facing results always state staleness
     (R-IDEA-09).
  7. Estimated values are labeled. Venice daily DIEM estimates are per account,
     cleared on key replacement, overridden by any reported allocation, and the
     first observation may already be spent. A dollar phrasing of unused quota is
     labeled as an estimate (R-NOV-02). USD and bundled credits, and Cline's
     balance (no total or reset), are amounts only, never percentages. Settings
     must not drop estimate qualifiers or print `--` for valid amounts (MAIN M03).
  8. Window lengths: the sources disagree. R-NOV-01 populates `windowSeconds` only
     where providers report it or ids fix it, never from labels, nil for rolling
     windows. R-BUG-12's forecast math takes the length from the classified label
     (`.other` gets no forecast). Reconcile when #103 and #109 meet; prefer
     reported durations.
- **Tests / acceptance:** a fresh fetch past `resetAt` with a forward `resetAt`
  stamps an observed reset and a carried value never does; a carried 8% past its
  reset produces no `critical`; a retired metric, a 3-day-old last sample and a
  burst inside a healthy week produce no forecast warning; placeholder-only usage
  never renders 100%; sparse history fixtures keep source timestamps; Venice
  estimates carry a label on every surface.
- **Relations:** LES-01, LES-02; BND-09; COR-08 (targeted refreshes), COR-12 and
  COR-13 (Venice estimate). #105 (R-BUG-08, R-LNX-01, R-LNX-02), #109 (R-BUG-12),
  #110 (`QuotaEvents`), #103 (pace), #87, #98, #76, #82. IDEA-06 asks the Reset
  Celebration on this branch to key on an observed reset (`lastResetObservedAt`,
  30 minutes) instead of `resetAt` alone.

### BND-09 Provider APIs are undocumented: fail gracefully and capture first

- **Status / severity / effort / platform:** open (rule in force) / standing
  constraint on every client and parser change / no effort of its own / both
  platforms; Linux-testable (client decoding tests run in QuotaCore).
- **Sources:** AGENTS.md hard constraints (`AGENTS.md:139-140`) and provider API
  notes; MAIN "Provider questions requiring sanitized fixtures", A03, A09, C12,
  reported #65, #69, #77, #81, #84, #91, rejected suggestions; TMP R-BUG-01,
  R-BUG-02, R-BUG-17, R-BUG-18, R-BUG-19, R-BUG-23, R-BUG-34, R-BUG-36, R-BUG-37,
  R-DEBT-02, R-DEBT-03, refuted CLIENT-7; LEDGER #89, #90, #93.
- **Problem and evidence:**
  - The rule: fail with a `ProviderFailure` and keep showing the last good snapshot.
    `QC/QuotaCoordinator.swift:59-81` records failures; `QC/SnapshotMerge.swift:12-31`
    carries the last good usage of failed accounts, subject to BND-08.
  - Baseline drift that read as healthy data: Devin omits proto3 zero percents, so
    exhausted windows vanish (R-BUG-02, #89); Antigravity's fixed `modelSpecs`
    (`QC/Clients/GoogleAntigravityClient.swift:18-23`, `:77-90`) return success with
    only the placeholder after a catalog rename (R-BUG-18); Cline's
    `decodeIfPresent(...) ?? 0` (`QC/Clients/ClineQuotaClient.swift:288-296`,
    `:330`) treats a missing `percentUsed` as 0% used (R-BUG-37, MAIN A01, retired
    in #69); `parseJSONObject` lets JSONSerialization errors escape as `.unknown`
    (`QC/Utilities.swift:140-146`, R-BUG-36); the "empty" placeholder literal sits
    at nine client sites (R-BUG-34); the Copilot internal decoder requires fields
    GitHub's own client treats as optional (R-BUG-19); Z.ai/Zhipu read only the
    first `TOKENS_LIMIT` entry (R-BUG-01, #90). `QC/QuotaCoordinator.swift:6-44`
    silently drops accounts with no registered client and traps on duplicate keys
    (R-DEBT-03, MAIN C12).
  - Reported: #65 maps a missing Antigravity fraction to unknown with nil
    `maxUsagePercent`; #84 fails Anthropic with `.decoding` when every window is
    unreadable, keeps readable windows, and coerces Kimi `limits[]` element-wise;
    #81 renders OpenCode Go `rate-limited` windows as exhausted; #69 validates Cline
    and Muse schemas; #93 deferred a nil `maxUsagePercent` when no window parsed,
    which #84 covers for Anthropic.
- **Proposal (rules):**
  1. Distinguish unknown from zero. Missing is unknown unless the protocol proves
     otherwise: for Devin, a missing percent with a positive reset is 0%
     (exhausted), a missing percent with no reset is no window, and windows are
     never invented from `billingStrategy` alone (R-BUG-02); on credit-billed
     plans #89 never infers an exhausted window from a reset alone. Refuted
     CLIENT-7: Antigravity's `remaining` is a oneof with explicit presence, so
     missing stays unknown; change that only after capturing a fixture from an
     exhausted model.
  2. Require a recognizable success: a non-JSON 200 is `.decoding` with fixed text;
     a non-empty model list with no quota info is `.decoding`; a terminally failed
     Muse stream is not fresh success; present malformed or null windows are not
     "absent" (MAIN rejected suggestions).
  3. Keep valid partial windows (#84; Kimi element-wise).
  4. Leave the aggregate (`maxUsagePercent`) nil when no bounded metric exists, and
     keep placeholders out of slots (R-BUG-34).
  5. Change endpoint or field semantics only from sanitized captures (PRV-27..PRV-29).
     Open capture questions from MAIN: the Antigravity catalog and absent fractions;
     the Anthropic extra-usage credit scale; Copilot AI-credit vs premium-request
     plans, organization scope, UTC resets and exchanged-token validity; Claude CLI
     namespace compatibility and the detected-version UA (#91); OpenAI additional
     limits, credits, `allowed`, reached type and absolute resets; Zhipu/Z.ai
     percentages and endpoints and the no-supported-limit case; private Google and
     Anthropic headers. From TMP and LEDGER: Muse exhausted 429/403 bodies
     (R-BUG-23, "do not implement speculatively"); whether `account/rateLimits/read`
     refreshes after a 401 (R-BUG-17); a weekly entry on `open.bigmodel.cn` (#90);
     non-USD Anthropic extra usage (#93); Devin's top-level `planInfo` (#89).
     Fixtures use synthetic tokens, never real credentials.
  6. Failure text follows BND-01. Status mapping is centralized: 401 (403 only
     when opted in) is auth; 408, 425, 429 and 503 are rate limits with
     `Retry-After`; everything else is api (R-DEBT-02). Reuse #77's `retryAt` rather
     than adding a second retry field.
  7. An unregistered provider yields a visible `.notConfigured` failure instead of a
     silent drop; duplicate registration gets a documented policy, never a trap
     (R-DEBT-03, MAIN C12).
  8. Respect provider poll floors: Anthropic no faster than about 3 minutes and
     only with its `claude-code/<ver>` User-Agent; LLimit's interval of at least
     15 minutes is safe (AGENTS.md).
- **Tests / acceptance:** missing, empty, null and hostile-number fixtures per
  client distinguish unknown from zero; an HTML body gives `.decoding`; partial-window
  fixtures keep readable windows; placeholder-only usage gives a nil aggregate and
  a nil primary slot; a body sentinel never appears in a failure message; refreshing
  one configuration per `QuotaProvider.allCases` lists every id in usage or failures.
- **Relations:** PRV-27..PRV-29; BND-01, BND-08; COR-06, COR-10, DEBT-02. #84
  covers #93's `maxUsagePercent` deferral for Anthropic; #65, #69, #81, #89, #90
  touch the same parsers.

## Correctness, privacy and persistence

This section covers data integrity, persistence, durability and cancellation.
MAIN's high-severity C-items come first because they can lose or resurrect user
data or credentials. TMP's low-severity persistence bugs follow. Identity binding
and file modes are in Security (SEC-01, SEC-02). Line references are baseline
`2d6ac1e` starting points. "Source check" marks a location re-read in the baseline
tree while merging; everything else is as the sources report it.

### COR-01 Refresh publication can resurrect removed, disabled or renamed accounts

- **Status / severity / effort / platform:** open. MAIN rates it high; TMP rates
  its Linux slice low (verifier correction). Effort: S for the Linux slice (TMP);
  the macOS revision checks are not sized. Both platforms: the daemon slice is
  Linux-testable, the AppModel path is macOS-only.
- **Sources:** MAIN C04; TMP R-LNX-10 (LINUX-10); LEDGER #104 deferral.
- **Problem and evidence:**
  - macOS: `APP/AppModel.swift:199-212,248-271` revalidates only Venice before
    commit. Source check: `removingChangedVeniceResults` (`:258-272`) compares only
    the Venice key and `isEnabled`, and runs at `:211` and `:250`. A non-Venice
    account removed, disabled, renamed or re-keyed during the fetch is still saved
    (`:212`, `:251`) and published (`:252`).
  - Linux: `LD/QuotaDaemon.swift:271-285,311-320` publishes the captured result
    with no final settings read. `removeAccount` (`:207-216`) reconciles and purges
    history while the daemon's fetch (`:283-323`) is in flight; the daemon then
    saves the old snapshot and appends it to history
    (`QC/QuotaHistoryStore.swift:55-76`).
  - Impact (MAIN): removed or disabled accounts, old credentials and names, and
    purged history can reappear, and a concurrent purge can lose unrelated samples.
  - TMP's verifier correction for Linux: the snapshot is reconciled again almost at
    once, so only history keeps the entry, and nothing on Linux reads history.
  - #104 deferral: an in-flight refresh can also re-save an old Venice estimate.
  - Backlog: TMP says R-LNX-10 largely restates "Cancellation and account-edit
    races (revalidate before every persistence boundary)" and "Synchronize stores"
    (BKL-10).
- **Proposal:**
  - Validate the actual queried account revision at each commit, for every
    provider, not only the Venice key. Reconcile current names and enabled IDs
    before save and publish.
  - Linux: perform the snapshot save and history append inside
    `settingsLock.withLock`. Inside the lock, reload settings, apply
    `reconciled(with:)` against the enabled accounts, then save and append. The CLI
    removal already holds this lock, so purge and append become serialized.
  - Never hold the settings lock across network work; edits must stay responsive.
- **Tests / acceptance:**
  - Barrier-controlled remove, disable, rename and key-change tests preserve the
    current configuration and unrelated history. Obsolete usage reaches no
    persistence boundary.
  - Extend the gated-fetch scenario in `SettingsConcurrencyTests` to remove an
    account mid-fetch and assert it is absent from both snapshot and history.
  - Settings three-way-merge tests alone do not prove publication correctness.
- **Relations:** BKL-10 (backlog wording); COR-02 (cross-process owner);
  COR-04 (cancellation guards sit at the same commit points); COR-12 (Venice
  estimate state on disable); #104 (edits `removeAccount`); #68 and #101 (Venice
  key edits); #75 (history semantics). The AppModel change must rebase onto #94,
  #101, #102, #104, #106 and #107, which all edit `APP/AppModel.swift` but merge
  cleanly with each other (measured, ledger table 1).

### COR-02 No cross-process refresh owner

- **Status / severity / effort / platform:** open. MAIN high; TMP medium. Effort M
  (TMP). Linux process ownership is Linux-testable; the Claude pending marker
  (QuotaCore plus AppModel) is partly macOS-only.
- **Sources:** MAIN C05; TMP R-LNX-04 (LINUX-4, PRODUCT-5). TMP backlog note
  (R-LNX-04): extends BACKLOG "Network layer > Rate limits, retries, and
  scheduling" (coalesce concurrent refreshes, manual-refresh cooldown) and
  "Synchronize stores" (cross-process coordination).
- **Problem and evidence:**
  - The daemon (`LD/QuotaDaemon.swift:359-374,435-448`), the one-shot CLI
    (`CLI/main.swift:316-330`), and tray and Waybar refresh clicks
    (`Packages/LLimitd/tray/llimit_tray.py:200-212`, a detached Popen;
    `Packages/LLimitd/examples/waybar/llimit.jsonc:16-18`) refresh independently.
    The tray docstring wrongly says the daemon holds the lock during refresh.
  - The settings lock covers only the load and the merge-save
    (`LD/QuotaDaemon.swift:119-130`, `:258-269`, `:359-375`). Repeated clicks, or a
    click during a daemon cycle, run fully parallel fetches with no cooldown.
  - When the hourly ChatGPT access token has expired, each process exchanges the
    same refresh token (`:385-454`, loop at `:393-404`). The loser records an auth
    failure, and last-writer-wins can overwrite the winner's good snapshot.
  - History appends are unlocked load-modify-write cycles
    (`QC/QuotaHistoryStore.swift:55-74`), so concurrent appends can drop entries.
  - Every run re-polls Anthropic, which hard rate-limits repeat pollers.
  - macOS and QuotaCore: the Claude pending marker is not an exclusive claim
    (`QC/ClaudeCodeRenewal.swift:65-94`, `APP/AppModel.swift:1035-1093`).
  - Duplicate launch windows are source-confirmed. Unverified: actual server
    revocation was not observed, and whether OpenAI revokes the whole grant on
    refresh-token reuse is unknown.
- **Proposal:** the two sources are complementary. TMP gives the Linux process
  design; MAIN gives the ownership invariant that also covers managed profiles.
  - Make a running daemon the sole fetcher (TMP):
    - It writes `$XDG_RUNTIME_DIR/llimit/daemon.pid` and handles SIGUSR1 by
      cancelling its sleep (not the cycle) and running one coalesced cycle,
      ignoring requests within 60 s of the last.
    - `llimit refresh` signals a live daemon and waits, with a timeout, for
      `generatedAt` to advance.
    - Add a non-blocking daemon instance lock.
  - Without a daemon, `llimit refresh` takes a `quota-refresh.lock` flock (reuse
    SettingsLock's code). It is held across the whole `refreshNow`, including the
    settings reload, so a waiter sees rotated tokens. When it waited, it prints the
    newer snapshot instead of fetching again. This is a separate refresh lock; the
    settings lock stays short.
  - Add durable, exclusive refresh and per-profile operation ownership before
    reading renewal material (MAIN). Coalesce or report busy operations. Preserve
    uncertain rotating-grant children and markers. A losing process must never
    clear the winner's record or delete a namespace. Keep the existing managed
    Codex operation guarantees from AGENTS.md.
  - Inject an HTTP client into `ChatGPTOAuth.refresh` (it already accepts one) for
    tests. Fix the tray docstring.
- **Tests / acceptance:**
  - Two daemons (or two processes) with gated clients perform one token exchange
    or renewal and one fetch per account, never overwrite with an older snapshot,
    and keep `llimit accounts` edits responsive.
  - flock exclusivity; a pure cooldown decision; stale pidfile handling.
  - Losing owners cannot clear winning records or delete namespaces.
- **Relations:** LNX-13, PRV-09, PRF-04. TMP's other SIGUSR1 consumers: tray and
  Waybar click feedback (R-LNX-15), `llimit config set refresh-interval` waking the
  daemon, and `llimit wait --refresh` sending one coalesced request. COR-01 (same
  publication step), COR-05 (rotation durability), COR-13 (the Venice guard
  assumes no overlap).

### COR-03 Failed saves reported as success; outcomes shown only on Overview

- **Status / severity / effort / platform:** partial. #104 implements the Linux
  account-mutation outcomes (TMP R-LNX-05: `normalizeAndSave` throws, mutations
  propagate, the CLI exits nonzero, `remove` saves before it purges history).
  On macOS, #101's draft commits return an outcome, and a rejected draft is kept
  with an inline reason. Remaining work is macOS-only. MAIN high; TMP medium.
  Effort M (TMP).
- **Sources:** MAIN C06; TMP R-UX-02 (APPMODEL-13, MENU-3 notice half,
  SETTINGS-2), R-LNX-05 (LINUX-5, done in #104); LEDGER #101 deferral.
- **Problem and evidence (remaining, macOS):**
  - Edits stay in memory after a failed save (`APP/AppModel.swift:163-184`,
    `:550-578`, `:1603-1611`). Source check: `saveConfiguration` only sets
    `statusMessage` on failure (`:182-184`) and on a blocked save (`:164-166`).
  - Auto-fill can replace a save error with a success message.
  - A single `statusMessage` is overwritten by later refresh text, and Settings
    often hides notices.
  - Outcomes that appear only on Settings > Overview (the only renderer is
    `APP/Views/SettingsView.swift:181-185`; see also `:828-832`, `:847-864`) or
    nowhere (`APP/AppModel.swift:163-185`, `:203-207`, `:253-255`, `:424-427`,
    `:533-557`, `:1218-1229`, `:1588-1601`; `APP/LLimitApp.swift:797-843`, `:866`):
    - Auto-fill's "No Kimi login detected…" and "Filled…".
    - Venice key rejections. #101 shows a rejected draft's reason inline, but
      (deferred by #101) a rejected draft for an account that became connected is
      never shown and is dropped at quit.
    - "Save failed" and "Save blocked because the existing settings file could not
      be read".
    - "No enabled provider accounts with complete credentials".
    - Failed non-Claude removals go to `claudeAccountMessages`, which only Claude
      pages display.
    - The menu's Launch at Login toggle silently flips back on `register()` errors;
      `requiresApproval` is not handled at all.
    - The dropdown never renders `statusMessage`.
  - Impact: clicks in the menu and on account pages appear to do nothing. With an
    unreadable settings file, every edit looks saved and is lost on relaunch.
- **Proposal:**
  - Return explicit durable outcomes from mutations. Save settings before
    destructive derived cleanup. Roll back failed mutations or keep retryable
    unsaved drafts (#101's `PendingEdits` already keeps a rejected draft with its
    reason).
  - Publish `accountNotices: [String: AccountNotice]` (message, severity, date,
    context) plus one global `AppNotice` with an optional recovery action. Render
    account notices under the Credentials row, and the global notice as one line
    under the dropdown header and in Settings.
  - Set notices from Auto-fill (return a result enum), `updateAccount` rejections,
    save failures, `removeProviderAccount`, the early exits and catch of
    `refreshNow`, and `setLaunchAtLogin`.
  - For `requiresApproval`, add an "Open Login Items" action that calls
    `SMAppService.openSystemSettingsLoginItems()`.
  - While `configurationLoadFailed` is true, show a persistent banner on every
    page: "Changes are not being saved because the settings file could not be read."
  - Disagreement: TMP clears notices after the next successful refresh; MAIN says
    a later success must not dismiss a durability failure. Reconcile by clearing
    only refresh-scoped notices on refresh; durability notices clear only on a
    successful save.
- **Tests / acceptance:**
  - Inject failures for add, import, edit, enable, remove and Auto-fill: durable
    state stays unchanged, the error appears beside the operation, an uncommitted
    removal preserves history, and cleanup failures remain visible.
  - Manual: disable all accounts, press Refresh in the menu, and confirm the notice
    appears.
- **Relations:** DEBT-01 (MAIN's `print()`/`debugInfo()` on every snapshot sync,
  to be routed through `reportPersistenceIssue`-style structured logging with JSON
  stdout clean); COR-07 (recovery banner); COR-09 (save-failure notice); #101
  (drafts); #85 (save debounce and termination flush on the same edit path); #104
  (also adds the macOS unreadable-settings guard, MAIN C03); #102 (refresh
  controls). TMP backlog links: "Actionable account state" (structured notices),
  "Onboarding" (do not tell an unconfigured user to refresh), "Platform polish"
  (launch-at-login approval).

### COR-04 Cancellation becomes an ordinary failure

- **Status / severity / effort / platform:** partial. #65 (MAIN-reported)
  rethrows `CancellationError`/`URLError.cancelled` in the transport. Remaining:
  propagation through clients and the coordinator, and commit guards. MAIN high;
  TMP low (R-BUG-26 verifier: low to medium, narrow trigger; R-LNX-11 low).
  Effort M for macOS (R-BUG-26), S for Linux (R-LNX-11). Coordinator and daemon
  are Linux-testable; the interval Picker trigger is macOS-only.
- **Sources:** MAIN C10; TMP R-BUG-26 (APPMODEL-2), R-LNX-11 (LINUX-18). TMP
  backlog notes: R-BUG-26 extends BACKLOG "Data correctness > Cancellation and
  account-edit races"; R-LNX-11 substantially restates that item, and the signal
  handler is its new trigger.
- **Problem and evidence:**
  - Baseline `QC/HTTPClient.swift:29-33` wraps cancellation as `.network`, and
    `QC/QuotaCoordinator.swift:59-82` captures every error as a failure (source
    check). Publication owners have no cancellation-before-commit guarantee;
    #65's rethrow alone does not prove propagation.
  - macOS trigger (R-BUG-26): the interval Picker stays enabled during a refresh
    (`APP/Views/SettingsView.swift:362`), and `restartAutoRefreshLoop()` cancels the
    task awaiting `refreshNow()` (`APP/AppModel.swift:209-213`, `:700-720`,
    `:1155`, `:1231-1243`, `:1763-1786`). The cancellations then surface as real
    failures, all saved and published:
    - URLSession cancellations become `.network` failures.
    - Managed Codex cancellations become `.auth` "Codex could not complete this
      request" (`QC/CodexAccountService.swift:104-106`).
    - A Claude renewal cancelled before launch shows "Reconnect it to try again"
      (`QC/ClaudeCodeProcess.swift:78-85`).
    - Carried usage keeps the values, so accounts show failures rather than
      blanks.
    - A cancelled `ChatGPTOAuth.refresh` can lose a refresh token the server
      already rotated, which can break an imported OpenAI grant.
  - Linux trigger (R-LNX-11): SIGTERM/SIGINT cancel the loop task
    (`CLI/main.swift:341-367`, source check: `:364-365`), which cancels
    `refreshNow` (`LD/QuotaDaemon.swift:258-328`). swift-corelibs URLSession on
    Swift 6.1.2 was verified to throw `NSURLErrorCancelled` at once, and the
    resulting `.network` failures are saved. The comments in `main.swift`
    (`:344-347`) and `UBUNTU_PORT.md` (`:139-140`) claim the handler lets the
    in-flight refresh finish. Stranding an OpenAI grant needs a narrow window after
    the server has rotated the token.
- **Proposal:**
  - Reuse #65's transport handling. Preserve `CancellationError` through clients
    and `QuotaCoordinator.refresh` (check `Task.isCancelled`, discard cancelled
    results), stop retries, and check cancellation before every snapshot save,
    history append and publish.
  - macOS: run each refresh in its own task that rescheduling never cancels; an
    interval change only recomputes the due time (TMP R-BUG-22 scheduler).
  - Shield the ChatGPT token exchange in an unstructured Task so its rotation is
    always persisted (COR-05).
  - Linux: have the signal handler set a stop flag and wake the sleep; run each
    cycle in an unstructured task the signal does not cancel; fix the comments in
    `main.swift` and `UBUNTU_PORT.md`.
  - Quota cancellation must not replay or destroy uncertain official-CLI
    rotating-grant operations.
- **Tests / acceptance:**
  - A coordinator with a suspending fake client and a cancelled parent yields no
    failures, and no new snapshot or history entry is written.
  - Linux: cancel during a gated fetch; no snapshot with cancellation failures is
    written, and shutdown keeps the last good usage.
  - Pending auth children and durable operation records keep their owner until
    confirmed exit.
- **Relations:** PRV-06 (managed Codex "sign-in was canceled" copy); COR-01 (same
  commit points); COR-05 (lost rotation); MAIN F05 (HTTP client and transient
  classification); TMP R-BUG-22 and #102's deferral (ticks dropped during
  single-account refreshes).

### COR-05 Rotated grants must be durable before the next account

- **Status / severity / effort / platform:** open. MAIN high. Not sized. Linux
  daemon, Linux-testable.
- **Sources:** MAIN C08.
- **Problem and evidence:**
  - Linux proactive renewal batches rotations until every account finishes
    (`LD/QuotaDaemon.swift:258-268,385-406`). Source check: the loop at `:393-404`
    awaits each account and only sets `didChange`; one `mergeAndSaveSettings()`
    follows at `:264-268`, and its failure is only logged (`:267`). The reactive
    recovery path (`:291-297`) has the same shape. The next cycle reloads settings
    (`:361-363`) and can reload the old credentials.
  - Not in the sources, observed in baseline during this merge: macOS batches the
    same way (`APP/AppModel.swift:640-671`, one `saveConfiguration()` at
    `:668-670`, which swallows errors into `statusMessage`). macOS keeps the
    rotated token in memory until relaunch, so the loss needs a quit before a later
    successful save. Unverified beyond source reading.
- **Proposal:**
  - Persist each successful rotation before awaiting another account.
  - Retain unsaved replacement material so a reload or retry cannot discard it or
    replay the old grant. Never resubmit the old grant.
  - Report durability uncertainty, not ordinary refresh success.
  - Do not overwrite env references (#86 `env:NAME` settings).
- **Tests / acceptance:** block account B after A rotates: A is already durable.
  With an injected save failure, the next cycle neither loses the replacement nor
  resubmits the old grant. Use synthetic transport and storage only, never real
  OAuth credentials.
- **Relations:** COR-04 (R-BUG-26's rotation lost on cancel); COR-11 (R-BUG-31's
  id mismatch drops rotations); COR-02 (double exchange); SEC-01 (identity binding
  for refresh acceptance); #86 (env references).

### COR-06 Failure records: safe text, status mapping, structured fields, history migration

- **Status / severity / effort / platform:** partial. #70 (MAIN-owned) makes new
  failures safe; #63, #65 and #77 (MAIN-reported) add excerpts, 429-to-rateLimit
  mapping and `retryAt`. Remaining: historical migration, structured fields and
  one shared HTTP failure helper. MAIN high; TMP medium. Effort M (TMP). QuotaCore,
  Linux-testable.
- **Sources:** MAIN C01; TMP R-DEBT-02 (CLIENT-11).
- **Problem and evidence:**
  - Baseline `QC/QuotaCoordinator.swift:59-81` copied typed and localized errors;
    `QC/Clients/ChatGPTOAuth.swift:41-46` included refresh response text;
    `QC/Models.swift:385-421` has only account, provider, kind and message fields.
    Snapshots, history and log owners persisted those strings. Neither #70 nor #63
    migrates existing archives or defines a widget-specific credential-free
    projection. #77 adds `retryAt` and a cooldown, not the full structured model.
    The incoming copy says #65's `.api` failures include response bodies.
  - #63's scrubbing (about 200-character whitespace-folded excerpts,
    Bearer/JWT/API-key-shaped token scrubbing via `bodyExcerpt`/
    `sanitizeFailureText`) does not establish safety for unknown reflected secrets
    or old persisted errors.
  - TMP's per-client inventory (baseline):
    - 429 mapped to `.api`: `QC/Clients/OpenAIClient.swift:44`,
      `QC/Clients/ZhipuQuotaClient.swift:39`,
      `QC/Clients/GoogleAntigravityClient.swift:111`, `:137`,
      `QC/Clients/CopilotClient.swift:78`, `QC/Clients/ChatGPTOAuth.swift:42`. #65
      reportedly fixes Zhipu, OpenAI and Copilot billing; re-check the rest after
      it merges.
    - Body echo sites: Anthropic `:58`; OpenAI `:53`; ChatGPTOAuth `:45`; Copilot
      `:79`, `:220`, `:278`; Devin `:85`, `:87`; Google `:112`, `:138`; Kimi `:68`,
      `:71`; Zhipu `:40`, `:50`; Muse `:73`, `:75`, `:123`.
    - VoiceOver reads the kind's raw value: `WX/ProviderQuotaWidget.swift:643`.
  - TMP marks R-DEBT-02 "unverified as new": the facts are accurate, but problem
    and fix are the union of BACKLOG "Release blockers > Failure-data redaction
    boundary" and "Rate limits, retries, and scheduling (centralize 408/425/429
    classification; honor Retry-After)". The site list is the new content.
- **Proposal:**
  - Migrate or filter persisted raw errors on every read, export and publish path.
    Use allowlisted public messages, not raw diagnostic bodies; keep raw
    diagnostics transient.
  - Add backward-compatible `failedAt: Date`, a safe `httpStatusCode: Int?`, and a
    safe provider code where justified. Reuse #77's `ProviderFailure.retryAt`/
    `ProviderClientError.retryAfter` instead of a second retry field (the earlier
    `retryAfter: Date?` proposal is dropped). Surfaces can then tell "failing for
    3h" from "retries in 2m".
  - Define a bounded widget/display DTO. Preserve reconnect, unsupported-key and
    missing-CLI advice.
  - Add `ProviderHTTPFailure.make(status:response:providerName:authStatuses:)`:
    401 (403 only when opted in) is auth; 408, 425, 429 and 503 are rateLimit with
    `Retry-After` parsed (reuse #77's parser); everything else is api. Fixed text,
    `statusCode` always set, never a body. Migrate the nine clients, keeping hints
    such as Kimi's 404. TMP R-BUG-10 is a subset; land it first or together.
  - Reconcile #63's excerpts and #65's `.api` bodies with #70's allowlist. Do not
    reopen #70's new-failure implementation.
- **Tests / acceptance:**
  - Legacy snapshot and history fixtures with reflected access and refresh tokens,
    unknown token-like values, HTML, control characters and oversized bodies leak
    nothing through persisted, display, export or log output. Old Codable records
    still decode.
  - Typed, unexpected, OAuth, cooldown/countdown and recency-ordering cases stay
    actionable.
  - Per client: a 429 gives `.rateLimit`, and a body sentinel string never appears
    in the message.
- **Relations:** unblocks MAC-22 (copy failure text) and LNX-01 (account-named
  Linux errors). TMP R-LNX-07 (Waybar markup escaping and failure-text
  sanitizing); TMP R-BUG-36 (non-JSON 200 becomes `.unknown`); MAIN F05 (transient
  classification); #63, #65, #70, #77.

### COR-07 Settings recovery and schema evolution

- **Status / severity / effort / platform:** open. MAIN medium. Not sized. Codec
  and backup logic in QuotaCore is Linux-testable; the recovery UI is macOS-only,
  with a Linux CLI counterpart.
- **Sources:** MAIN C11.
- **Problem and evidence:**
  - A settings decode failure blocks saves with no last-good backup or guided
    recovery. Source check: `APP/AppModel.swift:138-147` substitutes defaults and
    sets `configurationLoadFailed`; `:164-166` blocks every save with "Fix or back up
    the file, then relaunch LLimit."
  - Snapshot versions are unchecked. Source check: `QuotaSnapshot`
    (`QC/Models.swift:423-438`) carries `version: Int = 1` with synthesized
    Codable.
  - Unknown providers can fail whole arrays (`QuotaProvider` is a String-raw
    Codable enum, `QC/Models.swift:3`).
  - Neither #78's quarantine nor #79's failable container initializer provides
    recovery, and neither do the #104/#66 unreadable-settings guards.
- **Proposal:** versioned envelopes with a forward and downgrade policy; atomic
  last-good backups (owner-only, reusing #71's secure-save helper); reveal, export,
  restore and reset actions. Preserve originals and identify or quarantine skipped
  account records. No silent partial recovery or empty defaults.
- **Tests / acceptance:** truncated, newer-version and mixed-provider files
  preserve originals. Test restoration, downgrade preservation, version validation,
  backup failures and visible recovery.
- **Relations:** PRD-11 (remove all); LNX-03 (reporting an unreadable file on
  Linux); COR-03 (persistent banner); SEC-02 (backup file modes); #78 and #94
  (snapshot/history corruption: #94 deferred the corrupt local archive, which #78
  likely covers).

### COR-08 Targeted refreshes mark the whole snapshot fresh

- **Status / severity / effort / platform:** partial. #75 (MAIN-owned) stops
  sibling and carried values from entering history. Remaining: `generatedAt`
  advancement. TMP low. Effort S. macOS app; the splice function is
  Linux-testable.
- **Sources:** TMP R-BUG-27 (APPMODEL-6, MENU-2 `generatedAt` half). TMP backlog
  note (R-BUG-27): extends BACKLOG "Fresh, stale, failed, and unknown state"
  (timestamp trend points with `fetchedAt`, append only fresh observations).
- **Problem and evidence:**
  - The post-login, renewal and Codex-connect single-account refreshes set
    `generatedAt` to now (`APP/AppModel.swift:274-297`, `:316-347` at `:341`,
    `:907-927` at `:922`, `:1797-1812`; `APP/LLimitApp.swift:715-720`;
    `WX/LLimitQuotaWidget.swift:351`, `:717-722`, `:773`).
  - The header then says "Updated just now" while other cards are 25 minutes old.
  - A quick relaunch skips the bootstrap refresh, because the bootstrap decision
    reads `generatedAt`.
- **Proposal:**
  - Add a pure `QuotaSnapshot.splicingPartialRefresh(_:accountIDs:)` that keeps the
    base `generatedAt`. TMP's history-delta half of this function is superseded by
    #75; reuse #75's source-fetch-time append rather than adding a second rule.
  - The generalized `refreshAccount(_ id:)` proposed in TMP R-UX-07 must use it and
    never bump `generatedAt`.
  - Confirm the widget trend dedupe at `WX/LLimitQuotaWidget.swift:717-722`
    tolerates sparse entries.
- **Tests / acceptance:** `generatedAt` is preserved after a targeted refresh; the
  spliced result changes only the given account ids; a relaunch right after a
  targeted refresh still runs the bootstrap refresh when the rest is due.
- **Relations:** PRF-01 (bootstrap), WID-05 (per-account age), SUB-CORE-1
  (REF-06). #95 (R-UX-03) moves the header age toward per-account `fetchedAt`;
  check whether the "Updated just now" symptom survives it. The bootstrap skip
  remains either way. TMP's reset-notification idea depends on this fix landing
  first.

### COR-09 A failed local snapshot save discards a successful refresh

- **Status / severity / effort / platform:** open. TMP low. Effort S. macOS-only.
- **Sources:** TMP R-BUG-28 (APPMODEL-7).
- **Problem and evidence:**
  - `try refreshService.save(refreshed)` (`APP/AppModel.swift:212`, inside
    `:209-256`) runs before receipts, auth recovery and publishing. If it throws,
    the catch at `:253` only updates the Settings status line; nothing reaches the
    menu, the App Group or history. Every later cycle repeats this while the
    fetches succeed.
  - The targeted refresh paths (`:339-346`, `:920-926`) do the opposite and publish
    despite a failed save.
  - `RefreshService.refresh` (`APP/Services/RefreshService.swift:8-17`, `:11`)
    re-reads "previous" from the same stale file.
  - Realistic triggers: a full disk, a non-writable LLimit directory, or
    `chflags uchg`. `chmod 444` on the file does not trigger it, because the atomic
    rename still works (REF-14).
- **Proposal:**
  - Catch the save error and still run receipts, auth recovery and
    `publishSnapshot`. Post a persistent notice through COR-03: "Latest results
    could not be saved locally."
  - Have `RefreshService.refresh` take an explicit previous snapshot, and use the
    in-memory one when the disk copy is missing or older.
- **Tests / acceptance:** manual: `chmod 555` the LLimit directory, refresh, and
  confirm the menu updates and the notice appears.
- **Relations:** COR-03 (notice), REF-14 (reproduction lesson), SEC-02 (directory
  modes).

### COR-10 The "empty" placeholder counts as a quota window

- **Status / severity / effort / platform:** open. TMP low. Effort S. QuotaCore,
  Linux-testable.
- **Sources:** TMP R-BUG-34 (CORE-8); LEDGER #93 deferral.
- **Problem and evidence:**
  - Copilot always attaches a `resetAt` (falling back to next month) to its "No
    quota data available" placeholder (`QC/Clients/CopilotClient.swift:168`,
    `:183-191`); Zhipu and Z.ai attach `providerResetAt`
    (`QC/Clients/ZhipuQuotaClient.swift:145-151`).
  - `primaryLimitSlot` (`QC/ProviderMetricSelection.swift:87-100`, guard at `:92`)
    keeps an `.other` metric that has a reset, so the placeholder becomes the
    primary slot, and the menu-bar bar and the Settings preview
    (`APP/AppModel.swift:1482`) paint it #B8A8FF.
  - The literal `"empty"` appears at nine client sites. Source check: Codex
    rate limits, Anthropic, Copilot, OpenAI, Google Antigravity, Devin, Muse,
    Zhipu and Kimi.
- **Proposal:**
  - Add `UsageMetric.placeholderID = "empty"` and `isPlaceholder`, and use the
    constant at all nine sites.
  - Exclude placeholders in `limitSeriesSlots`, `primaryLimitSlot` and
    `defaultRingMetrics`.
  - #93 deferred making `maxUsagePercent` nil when nothing parsed. #84 (Anthropic)
    and #65 (Antigravity) report that behavior for their clients; check the other
    clients that emit a placeholder. #93 drops Anthropic's "empty" placeholder
    when an extra-usage amount exists.
- **Tests / acceptance:** a placeholder-only usage gives a nil primary slot; a
  placeholder listed first does not shift a real `.other` metric's slot.
- **Relations:** AGENTS.md color semantics (identity colors only for real
  windows); #93, #84, #65.

### COR-11 Blank or duplicate account ids get random UUIDs on every decode

- **Status / severity / effort / platform:** open. TMP low (verifier correction:
  only a hand-edited or copied file triggers it, and it ends at the first save).
  Effort S. QuotaCore decode with a Linux consequence; Linux-testable.
- **Sources:** TMP R-BUG-31 (CORE-5).
- **Problem and evidence:** `normalizedAccounts` (`QC/Models.swift:1545-1556`;
  source check: `:1549-1550` assigns `UUID().uuidString`) gives replacement ids
  that differ on every decode. The daemon's in-memory id then differs from the id
  on disk (`LD/QuotaDaemon.swift:77-93`, `:119-159`), so `mergingCredentialChanges`
  drops rotated OpenAI tokens, and the CLI cannot address the account. A rotated
  credential is lost on the first merge.
- **Proposal:** derive replacement ids from a stable FNV-1a hash of (provider,
  original id, name, index), formatted as a UUID. Have the daemon persist the
  normalized ids under the lock and log the affected account.
- **Tests / acceptance:** decoding twice yields the same ids; a merge keeps the
  credential change for a duplicate-id account.
- **Relations:** COR-05 (rotation durability); COR-07 (decode policy).

### COR-12 Disabling and re-enabling a Venice account resets the DIEM estimate

- **Status / severity / effort / platform:** open. TMP low (verifier correction:
  the value is labeled as an estimate that may be partly spent). Effort S.
  Linux-testable.
- **Sources:** TMP R-BUG-29 (APPMODEL-12).
- **Problem and evidence:**
  - Disabling an account reconciles the snapshot (`APP/AppModel.swift:1603-1611`,
    `:1712-1729`), and the snapshot is the only place the upper bound is stored
    (`APP/Services/RefreshService.swift:8-17`; `QC/QuotaCoordinator.swift:101-107`;
    `QC/VeniceQuotaEstimate.swift:28-41`).
  - After re-enabling, the current, possibly half-spent balance becomes the new
    upper bound, and the account restarts near 100%.
  - AGENTS.md allows clearing the estimate only on key replacement.
  - Not in the source, observed in baseline during this merge: the daemon's
    `setAccountEnabled` (`LD/QuotaDaemon.swift:198-205`) runs the same enabled-only
    reconciliation (`:525-529`), so `llimit accounts disable` likely has the same
    effect.
- **Proposal:**
  - Cheaper option (verifier): keep disabled Venice accounts' estimate state in the
    snapshot instead of dropping it.
  - Alternative: seed the prior from the newest history entry
    (`loadRecent(days: 2)`); history is already purged on key replacement and on
    removal.
  - #68's key fingerprint (LED-12) can key the retained state so a replaced key
    still starts fresh.
- **Tests / acceptance:** disable and re-enable in the same epoch keeps the bound;
  a new epoch starts fresh; a replaced key starts fresh.
- **Relations:** COR-01 (#104's deferred stale Venice estimate re-save); COR-13
  (same estimator); #68 (LED-12); #101 (Venice key drafts).

### COR-13 The Venice estimate freezes after the clock steps backward

- **Status / severity / effort / platform:** open. TMP low. Effort S.
  Linux-testable.
- **Sources:** TMP R-BUG-30 (CORE-10).
- **Problem and evidence:** `VeniceQuotaEstimate.applying`
  (`QC/VeniceQuotaEstimate.swift:23-26`, source check: `:24-25`) returns the whole
  previous usage whenever `usage.fetchedAt <= prior.fetchedAt`. After a backward
  clock step (dual-boot RTC, VM resume, manual correction), every refresh
  republishes the frozen balance with a future `fetchedAt`, so it also looks fresh
  to the stale checks. Venice usage can stay frozen for hours with no error. TMP
  says the guard exists for overlapping refreshes, which cannot happen in one
  process.
- **Proposal:** keep the prior only when both observations fall in the same server
  epoch (equal floored `resetAt`) and `prior.fetchedAt - usage.fetchedAt` is within
  about 120 s.
- **Tests / acceptance:** with a prior fetched at now+2h, a fetch at now updates the
  amount and the percent.
- **Relations:** COR-12 (same file); COR-02 (revisit the no-overlap assumption when
  refresh ownership changes); WID-05 and #105 (per-account `fetchedAt`/`ageSeconds`
  must clamp future dates).

## Providers, managed sign-in and account setup

This section covers provider clients, managed Claude/Codex sign-in, credential discovery and account setup. Managed-auth lifecycle bugs come first (PRV-01 to PRV-09) because they force reconnects or rotate grants needlessly. Provider-client, discovery and setup defects follow (PRV-10 to PRV-26). Questions that need a provider capture come last (PRV-27 to PRV-29).

Provider APIs are undocumented and unstable: adopt new endpoint or field semantics only from sanitized fixtures (BND-09), fail gracefully with `ProviderFailure`, and keep showing the last good snapshot. MAIN's original review found no further code-established Venice, OpenCode Go, Kimi, Devin or Zhipu client defect that warranted speculative API changes. TMP's findings and MAIN's pass-D reports (A09) are separate evidence, and MAIN did not independently validate #65, #81 or #84. Line references are baseline `2d6ac1e` starting points. `QCT/` means `Packages/QuotaCore/Tests/QuotaCoreTests/`.

### PRV-01 Auth failures rotate credentials every cycle

- **Status / severity / effort / platform:** open; medium (TMP); effort M; client mapping, the recovery policy and the daemon are Linux-testable, the AppModel wiring is macOS-only. TMP put it in the next tier, not the shortlist: high value, but the OpenAI trigger is unverified and the fix touches four areas.
- **Sources:** TMP R-BUG-10 (CLIENT-2, CLIENT-6, AUTH-7, APPMODEL-8). TMP backlog note (R-BUG-10): extends BACKLOG "Release blockers > Honest OAuth ownership".
- **Problem and evidence:**
  - `QC/Clients/OpenAIClient.swift:44-50` and `QC/Clients/AnthropicClient.swift:44-49` map both 401 and 403 to `.auth`. OpenAI sends `User-Agent: LLimit/0.1` (`OpenAIClient.swift:34`).
  - Claude: a `claude setup-token` token has only the `user:inference` scope and gets a 403 `permission_error` ("does not meet scope requirement user:profile"), per Claude Code issues #22450, #24200 and #33311. The advice "reconnect or import again" can never fix that. This case is documented upstream.
  - OpenAI: a Cloudflare challenge (reported on the backend-api edge for some User-Agents) or a workspace denial leaves the token valid. Unverified: no 403 from chatgpt.com to a valid token has been observed in this repo.
  - Managed Claude: every cycle, each `.auth` failure forces `claude auth login` with the refresh token (`APP/AppModel.swift:221-230`, `:1067-1093`, `:1118-1122`; `QC/ClaudeCodeRenewal.swift:58-94`). That takes up to 45 s while `isRefreshing` is held, and nothing records that the last forced renewal did not help.
  - Imported OpenAI: `recoverFailedOpenAITokens` (`APP/AppModel.swift:730-763`; daemon `LD/QuotaDaemon.swift:291`, `:434-456`, `:462-488`) forces `ChatGPTOAuth.refresh` whenever no fresher Codex token exists (`QC/OpenAICredentialSync.swift:51-57`). After the first rotation LLimit holds the freshest token, so adoption returns nil and every later 403 rotates again. The first rotation logs the user's Codex CLI out; after each new Codex login LLimit adopts the fresher token, gets another 403 and rotates again.
  - Unaffected: managed OpenAI accounts and accounts without a stored refresh token. On the Claude side only managed profiles are affected.
  - `ProviderFailure` carries no status code (`QC/Models.swift:385-404`). `ChatGPTOAuth` already accepts an `httpClient` (`QC/Clients/ChatGPTOAuth.swift:27`).
  - Impact: repeated grant rotations and CLI launches, a repeatedly logged-out Codex CLI, and permanently wrong guidance for setup-token users.
- **Proposal:**
  1. Clients: 401 maps to `.auth`. Decode Anthropic's error envelope without echoing it; a 403 `permission_error` that mentions a scope maps to `.notConfigured` with fixed text: "This token can't read usage (missing user:profile scope, e.g. a setup-token). Connect with Claude Code sign-in instead." Any other 403 maps to `.api` with fixed text: "Claude denied the usage request (HTTP 403)." or "ChatGPT blocked the usage request (HTTP 403). Try again later." Detect an HTML 403 or a `cf-mitigated` header. Never include the response body.
  2. `ProviderFailure`: add an optional Codable status code copied from `ProviderClientError`. TMP calls it `statusCode`; COR-06 (MAIN C01) proposes `httpStatusCode: Int?`. Add one field.
  3. Policy: a pure QuotaCore `AuthRecoveryPolicy.shouldForce(statusCode:currentToken:lastForcedToken:)` that forces at most once per stored access token and never on a 403. AppModel and QuotaDaemon keep `lastForcedToken[accountID]` in memory and clear it after any successful fetch. After a failed forced recovery, show "Authorization rejected. Reconnect or check the subscription." until the credentials change.
  4. Daemon: pass an injected HTTP client into `ChatGPTOAuth.refresh` so tests can count exchanges.
  - Constraints: never replay a possibly rotated Claude grant, and a timed-out renewal keeps its process and pending marker (BND-04). Keep the new texts fixed and body-free (#70's boundary).
- **Tests / acceptance:** an HTML 403 with `cf-mitigated` gives `.api` and no body text; a 403 scope body gives `.notConfigured`; 401 stays `.auth`. Policy: a second failure with the token just obtained does not force; a changed token may force once. Daemon: a 403 triggers no token exchange.
- **Relations:** subset of COR-06's shared `ProviderHTTPFailure.make` helper (TMP R-DEBT-02: 403 is auth only when opted in); land first or together. Reconcile with #65's shared `errorKind(forStatusCode:)` and PRF-05's provider-specific 403 classes rather than adding a third mapping. #93 edits `AnthropicClient.swift` (TMP lists the conflict). TMP lists the daemon's forced rotations as the Linux part of this item. COR-05 (durability of rotated grants), SEC-01 (refresh-result identity), PRV-03 and PRV-07 (other forced-reconnect paths), PRV-19.

### PRV-02 Quitting during a managed Codex fetch strands the account

- **Status / severity / effort / platform:** open; medium (TMP); effort M; `waitUntilIdle` and the drain are Linux-testable with a slow fake app-server, the terminate hook is macOS-only. TMP next tier.
- **Sources:** TMP R-BUG-14 (AUTH-4, APPMODEL-9); REF-21 (rejected AUTH-4 sub-claim).
- **Problem and evidence:**
  - Every managed fetch writes an `O_EXCL` `Operations/<id>.pending` record before launching app-server (`QC/CodexAccountService.swift:84-108`, `:119-174`, acquired at `:128`, released at `:161`; `QC/CodexProfileStore.swift:41-54` acquire, `:57-62` release). It is released only after the child exits, and only by the same process.
  - `APP/LLimitApp.swift:5-13`: the AppDelegate has no terminate hooks; `:870-872`: Quit calls `terminate(nil)` directly. Quitting, logging out or restarting during that window (a few seconds per fetch) leaves the record behind.
  - On the next launch every poll fails with "A previous Codex operation has not finished safely". By design (AGENTS.md) recovery means reconnecting into a fresh profile, and README:153-155 documents that outcome. The avoidable part is the trigger.
  - Quitting during a Codex login strands only the fresh, unreferenced profile, not the existing account (REF-21).
  - An open Claude login terminal is SIGHUP-killed without warning.
  - Impact: an ordinary Quit right after Refresh forces an OpenAI re-login.
- **Proposal:**
  1. Implement `applicationShouldTerminate`. When a refresh, Codex session, Codex login or Claude login terminal is active, set `isTerminating` so no new work starts, and return `.terminateLater`.
  2. Add `CodexAccountService.waitUntilIdle(timeout:)` (or `drain`) that awaits an empty `sessions` set and never kills a child.
  3. Wait 15 to 30 s, then call `reply(toApplicationShouldTerminate: true)`.
  4. On timeout offer "Wait" and "Quit Anyway" and name the accounts that may need reconnecting. If the child outlives the drain, keep the record (BND-04).
  5. Warn when a Claude login terminal is open.
  6. Make the error copy say that a restart does not clear this state.
- **Tests / acceptance:** `CodexAccountServiceTests` with a slow fake app-server: the drain waits for release; on timeout it returns false and the record stays. Manual: Quit during a refresh, relaunch, and the account polls normally.
- **Relations:** PRV-08 (each forced rotation is a window this interruption can lose), PRV-06 (`unfinishedOperation` copy), COR-04 (cancellation must not destroy pending records), COR-02. `LLimitApp.swift` is also edited by #95, #96, #102, #103 and #106; `AppModel.swift` by #94, #101, #102, #104, #106 and #107.

### PRV-03 A transient network failure during Claude renewal forces a reconnect

- **Status / severity / effort / platform:** open; medium (TMP); effort S; the `prepare` change is Linux-testable, the `NWPathMonitor` preflight is macOS-only. TMP next tier.
- **Sources:** TMP R-BUG-15 (AUTH-6).
- **Problem and evidence:**
  - `ClaudeCodeRenewal.prepare` persists `anthropicRenewalPending`, then launches `claude auth login` with the refresh token (`QC/ClaudeCodeRenewal.swift:87-100`, marker and `StartFailure`; `APP/AppModel.swift:1123-1126`). Only a launch failure clears the marker.
  - A launched child that exits non-zero leaves the marker, and the next `prepare` throws `reconnectRequired` (`QC/ClaudeCodeRenewal.swift:74-76`).
  - Renewing while offline (Wi-Fi not yet up after wake, a captive portal, a VPN switch, an OAuth outage) therefore costs a full browser re-login, although the request most likely never reached the token endpoint.
  - This is a deliberate safety tradeoff (comment at `:87-89`, README:208-210). Unverified: whether Claude Code exits non-zero offline without reaching the endpoint.
  - Renewal runs about every 8 h per account, so a short network failure at that moment strands managed Claude accounts.
  - Proxied networks were another trigger: the Claude child dropped proxy and CA variables, failed, and left the marker (TMP R-BUG-42). #107 passes those variables now.
- **Proposal:**
  - Add a `preflight: @Sendable () async -> Bool` parameter to `ClaudeCodeRenewal.prepare`, called before the marker is written.
  - When it returns false, throw a transient `networkUnavailable` ("Offline; will retry.") without persisting or renewing.
  - Implement the preflight in AppModel with `NWPathMonitor` (`.satisfied`) plus a DNS or HEAD probe of the Anthropic host.
  - The never-replay rule holds because the marker is still set before any launch. Preflight lowers the risk but cannot rule it out (BND-04).
- **Tests / acceptance:** with preflight false: no persist, no renew, a transient error, no marker. With preflight true: behavior unchanged.
- **Relations:** PRV-01, PRV-07, PRV-28 (offline exit behavior is a CLI compatibility question), PRF-01 (retry on wake and network return), #107.

### PRV-04 An open Claude reconnect terminal fails a working account

- **Status / severity / effort / platform:** open; medium (TMP); effort S; macOS-only (manual test), though the `prepare` path can get a Linux unit test.
- **Sources:** TMP R-BUG-16 (AUTH-9).
- **Problem and evidence:**
  - While a login terminal for the account is running, including a hidden sheet, `prepareClaudeAccount` throws `.inProgress` before reaching the cached-token fast path (`APP/AppModel.swift:199-202`, `:937-942` `claudeAccountIsBusy`, `:1077-1079`; `QC/ClaudeCodeRenewal.swift:28-36`).
  - The account is dropped from the refresh with the false message "Claude Code is still renewing this account".
  - Impact: clicking Reconnect and leaving the terminal open stops usage updates for a working account and shows a misleading failure.
- **Proposal:**
  - Separate a real renewal (`claudeRenewals[id]`) from an open terminal (`claudeSessions`).
  - For the terminal case, still call `ClaudeCodeRenewal.prepare`, with a `renew` closure that throws a new `.reconnectInProgress`. The cached token keeps publishing; renewal is deferred only when actually needed.
  - Copy: "Finish or cancel the open sign-in to renew this account."
- **Tests / acceptance:** manual: open Reconnect, hide the sheet, press Refresh, and usage updates while the cached token is valid. Optional unit test: `prepare` with a valid cached token never calls the throwing `renew` closure.
- **Relations:** PRV-09 (the other false "still renewing" source), #102 and MAIN A08 (OpenAI sign-in blocking refreshes), the rejected `llimit exec` idea (blocked partly by this item and PRV-09).

### PRV-05 Managed CLIs installed via nvm/fnm or at custom paths

- **Status / severity / effort / platform:** partial. #107 (open) implements the rest of R-BUG-03 (executable directory first in the child PATH, wider candidates, and nvm, fnm and Volta discovery), R-BUG-42 (proxy and CA variables) and R-PERF-05 (prerelease versions, cached probe). Remaining: a Settings override for custom CLI paths. Original severity: high for npm-installed Codex, medium for Claude (verifier correction). Remaining effort S; the Settings override is macOS-only.
- **Sources:** TMP R-BUG-03 (AUTH-1); REF-20 (rejected AUTH-1 sub-claim); LEDGER #107 deferrals.
- **Problem and evidence:**
  - Baseline: discovery checked `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, then `$PATH`, and every child (probe, app-server, renewal, login PTY) inherited the parent PATH. An app started from Finder or as a login item gets `/usr/bin:/bin:/usr/sbin:/sbin`. The npm Codex shim (`#!/usr/bin/env node`, verified with `npm pack` of 0.160.1) then exits 127 on `codex --version`, every candidate is rejected, and the user is told "Install Codex CLI 0.144.4 or later" (`QC/CodexProfileStore.swift:130`). Locations: `QC/CodexCLIProbe.swift:15`, `:77-78`; `QC/CodexAccountService.swift:123`, `:138`, `:209-225`; `QC/ClaudeCodeProcess.swift:50-52`; `APP/Services/ClaudeProfileService.swift:22`, `:64-76`; `APP/AppModel.swift:968-978`, `:996-1000` ("Sign-in did not finish"), `:1114-1121`; `APP/Views/ClaudeTerminalSession.swift:54-60` (direct `execve`, no login shell).
  - Done in #107's final head: nvm discovery (`$NVM_DIR` or `~/.nvm`, `alias/default` first, then `versions/node/*` by semantic version), fnm, and Volta with `VOLTA_HOME`; a distinct excessive-output failure, tailored timeout advice, a process-group kill on probe timeout, and re-probing only when a start failure implicates the executable.
  - Remaining: a CLI at any other custom path is still not found, which also gives Claude `cliMissing`. TMP also named `~/.npm-global/bin` as a candidate; the ledger does not say whether #107 covers it.
  - Current `@anthropic-ai/claude-code` ships a native binary, so the `env: node` failure does not apply to Claude (REF-20); its gap is only the candidate directories.
  - #107's probe cache, keyed by resolved path, size and mtime, misses a byte-identical npm downgrade. It recovers on launch failure.
- **Proposal:**
  - Add a non-secret "CLI path" override per CLI in Settings, validated with the same probe and its "not found", "failed to run (exit N)" and "too old" errors.
  - Keep the override authoritative over #107's nvm, fnm and Volta candidates.
  - Leave the downgrade cache miss to launch-failure recovery unless it shows up in practice.
- **Tests / acceptance:** a fake `codex` script with `#!/usr/bin/env fakenode` at a custom path outside every discovered candidate, parent PATH `/usr/bin:/bin`: with the override set, a session starts. An override path wins over candidates; an invalid override reports "not found" with the path.
- **Relations:** #107 (merge first; it edits `AppModel.swift`, which merges cleanly with this pass's other PRs, measured in ledger table 1), PRV-28 (#91's version detection depends on finding the CLI), PRV-06 (missing CLI maps to `.notConfigured`).

### PRV-06 Managed Codex failures all become auth; cancellation reads as "sign-in canceled"

- **Status / severity / effort / platform:** open; low (TMP R-UX-23), unrated in MAIN; effort S; Linux-testable with the fake executable.
- **Sources:** MAIN A04; TMP R-UX-23 (GAPB-5). TMP backlog note (R-UX-23): new; the cancellation-rethrow part overlaps BACKLOG "Cancellation and account-edit races".
- **Problem and evidence:**
  - `fetchUsage` wraps every error as `ProviderClientError(kind: .auth, ...)` (`QC/CodexAccountService.swift:84-106`, catch at `:104-107`). `safeError` (`:204-207`) keeps `CodexConnectionError` values and turns everything else into `.incompatibleCLI`: "Codex could not complete this request. Try again or reconnect the account." (`QC/CodexProfileStore.swift:135-136`).
  - Decoding, launch, timeout, storage and identity failures therefore all become `.auth` "reconnect the account" (MAIN), and CodexRPCError's fixed texts are discarded, for example "Codex did not respond in time. Its operation may still be running." (`QC/CodexRPCSession.swift:57-78`).
  - Cancellation caught in the probe loop throws `CodexConnectionError.cancelled` (`QC/CodexCLIProbe.swift:18`), which reads "OpenAI sign-in was canceled." for a cancelled refresh. `APP/AppModel.swift:352-362` surfaces it.
  - Impact: users are pushed into needless reconnects, which create new profiles.
- **Proposal:**
  - Map failures to sanitized, actionable kinds, combining both sources:
    - timeouts, closed sessions and write failures: `.network`, keeping their text;
    - launch failures and a missing CLI: `.notConfigured` (MAIN: "missing CLI configuration");
    - malformed rate-limit payloads: `.decoding`;
    - identity mismatch, invalid profile and unfinished operation: stay `.auth`.
    - Storage failures: neither source assigns a kind; keep the storage-permission text and do not ask for a reconnect.
  - Rethrow `CancellationError` when the task is cancelled (COR-04), and use usage-specific copy instead of sign-in wording.
  - Keep every pending-operation guarantee: a `.network` timeout still keeps the child and its record, so the next poll may report the unfinished operation (BND-04).
- **Tests / acceptance:** with the fake executable, a never-answering mode gives `.network`; a cancelled task has no "sign-in" wording and propagates cancellation; a malformed payload gives `.decoding`; an identity mismatch stays `.auth`; the record survives a timeout.
- **Relations:** COR-04 (MAIN C10), PRV-02, PRV-05, PRV-08, COR-06 (safe fixed texts; CodexRPCError texts are already body-free).

### PRV-07 Claude renewals break after a one-time Keychain Allow or an app update

- **Status / severity / effort / platform:** open; medium (TMP, verifier correction: the update case affects only ad-hoc-signed official builds, and the failure appears only when a renewal is due); effort S; macOS-only.
- **Sources:** TMP R-UX-13 (AUTH-2).
- **Problem and evidence:**
  - Claude Code creates its Keychain item with `security -i add-generic-password -U`, so LLimit is not on the item's ACL.
  - If the user clicks "Allow" rather than "Always Allow", or the cdhash changes (ad-hoc-signed releases), background renewal fails with "Allow LLimit to read this Claude profile in Keychain, then reconnect." Background reads use `kSecUseAuthenticationUIFail` (`APP/Services/ClaudeProfileService.swift:119`).
  - Nothing re-prompts for the existing profile; reconnecting means a new profile and a full browser sign-in.
  - Locations: `APP/AppModel.swift:1005`, `:1083`; `APP/Services/ClaudeProfileService.swift:25`, `:112-124`; `APP/Views/SettingsView.swift:49`; README:198.
  - The failure recurs with every ad-hoc release until Developer ID signing lands (BLD-02).
- **Proposal:**
  - Add an "Allow Keychain Access" action for `.keychainLocked` failures. It reads the existing profile with `mode: .interactive` off the main actor (PRF-08), then reruns `prepareClaudeAccount`.
  - Point the error copy at that action.
  - Before the first interactive read, show "macOS will ask for access; choose Always Allow."
  - Link to Developer ID signing, the only fix that keeps approval across updates.
- **Tests / acceptance:** manual: approve once with "Allow", force a renewal, use the new action, and renewal works without creating a new profile.
- **Relations:** BLD-02, PRF-08 (interactive reads off the main actor; this action depends on it), BKL-03 (adds Keychain ACL durability to BACKLOG), PRV-01, PRV-03.

### PRV-08 Managed Codex polls rotate the refresh token every time

- **Status / severity / effort / platform:** open; medium (TMP); effort S; Linux-testable with the fake app-server. TMP next tier: needs a Codex app-server capture first.
- **Sources:** TMP R-BUG-17 (AUTH-3).
- **Problem and evidence:**
  - `fetchUsage` always sends `account/read {refreshToken: true}` (`QC/CodexAccountService.swift:95`; pinned by `QCT/CodexAccountServiceTests.swift:36-47`).
  - `codex app-server generate-ts` (0.160.1) documents the flag as "requests a proactive token refresh before returning. In managed auth mode this triggers the normal refresh-token flow."
  - Every 15 to 30 minute poll for every managed account therefore rotates the OpenAI refresh token. If `auth.openai.com` is down, the poll publishes nothing, even though the cached access token was valid.
  - Impact: rotations happen orders of magnitude more often than needed; each one is a window in which an interruption (PRV-02) can lose the grant; usage goes missing during auth-endpoint incidents.
  - Unverified: whether `account/rateLimits/read` refreshes on its own after a 401. Confirm against a Codex capture before relying on `refreshToken: false`.
- **Proposal:**
  - Default to `refreshToken: false`.
  - Add `CodexProfileStore.accessTokenExpiry(_:)`, which decodes `exp` from the already-validated `auth.json`. Force a refresh only when the expiry is missing or within about 10 minutes. Read only the claim; never copy app-server authentication material into settings, logs or snapshots.
  - If `account/rateLimits/read` fails with `serverRejected`, retry once in the same session after `account/read {refreshToken: true}`.
  - Keep the identity re-checks after any forced refresh.
- **Tests / acceptance:** a token far from expiry sends `false`; a near-expiry token sends `true`; a rejected read gets exactly one forced retry; identity is re-verified after the forced refresh.
- **Relations:** PRV-29 (the same capture), PRV-02, PRV-06, BND-04.

### PRV-09 Leftover Claude Code lock files block renewal and removal forever

- **Status / severity / effort / platform:** open; low (TMP: needs SIGKILL, a crash or power loss inside the renewal window); effort S; the helper is Linux-testable, the service wiring is macOS-only.
- **Sources:** TMP R-BUG-43 (AUTH-14).
- **Problem and evidence:**
  - Any `.oauth_refresh.lock` or `<profile>.lock` counts as a live renewal by existence alone (`APP/Services/ClaudeProfileService.swift:133-137`, `:181`; `APP/AppModel.swift:944-949`, `:1077-1079`).
  - Claude Code 2.1.291 uses proper-lockfile with `stale: 60000` and `update: 5000`, plus a `.oauth_refresh.lock.owner` pid file. LLimit never starts Claude Code while the lock exists, so nothing reclaims it.
  - Impact: the account is stuck at "still renewing", and removal is blocked.
- **Proposal:**
  - Add `ClaudeCodeProfile.lockIsLive(modifiedAt:now:)`: a lock is live only if its mtime is under 60 s old (the CLI's own rule). Optionally also check the owner pid.
  - For a stale lock, say "A previous Claude Code run did not exit cleanly; Refresh to retry" and let the next renewal reclaim it.
  - Do not weaken exclusive ownership: a stale lock does not grant LLimit ownership, LLimit still takes its own durable claim before launching (COR-02), pending markers still block replay, and a namespace with a pending operation is never removed (BND-04).
- **Tests / acceptance:** helper unit tests (fresh, 59 s, 61 s, future mtime); manual test with a planted old lock: renewal proceeds, removal is allowed once no pending marker exists.
- **Relations:** PRV-04, COR-02, SEC-03 (removal blocked keeps grants alive), rejected `llimit exec` idea.

### PRV-10 The Antigravity model catalog is hardcoded

- **Status / severity / effort / platform:** open; medium (TMP); effort M; Linux-testable.
- **Sources:** TMP R-BUG-18 (CLIENT-8); MAIN AM-PROV-Q1 (provider questions); REF-02 (refuted CLIENT-7). TMP backlog note (R-BUG-18): extends BACKLOG "Provider correctness > Endpoint watchlist (fixed model IDs)", "Keep aggregate usage nil when no bounded metric exists" and "Never infer 100 percent remaining from absent aggregate data".
- **Problem and evidence:**
  - `modelSpecs` (`QC/Clients/GoogleAntigravityClient.swift:18-23`) reads only `gemini-3-pro-high/low`, `gemini-3-pro-image`, `gemini-3-flash` and `claude-opus-4-5(-thinking)` (`:77-90`; preferred ids `QC/ProviderMetricSelection.swift:24`).
  - When none match, the client returns success with only the placeholder and `maxUsagePercent: 0`, which `APP/LLimitApp.swift:1677` and `WX/LLimitQuotaWidget.swift:648` render as 100% remaining. Renames are realistic: CodexBar already handles Gemini 3.1 Pro aliases. Impact: after a routine catalog change every Google account silently shows a full quota.
  - MAIN (`:18-23`, `:50-79`): absent or unparseable fractions need captured exhausted/unavailable semantics and current-model omission behavior first; missing data is not a verified zero.
  - #65 (MAIN-reported) turns missing or unparseable `remainingFraction` into unknown with nil `maxUsagePercent` when no bounded data exists. That may already hide the 100% symptom for the no-match placeholder; verify.
  - REF-02: a missing `remainingFraction` is not an omitted proto3 zero. The Antigravity IDE reads `remaining` as a oneof case with explicit presence, so a real 0 is serialized, and CodexBar marks such entries `usageKnown: false`. Keep "missing means unknown" until a fixture from an exhausted model says otherwise.
- **Proposal:**
  - TMP: build metrics from every `models` entry that has `quotaInfo`, label from the response `displayName` (fallback: the key), id from the key. Keep the current list only as a preferred sort order. If `models` is non-empty but no entry has `quotaInfo`, throw `.decoding`.
  - Before collapsing pooled models, check whether the response exposes pools or buckets directly, as CodexBar uses. Collapsing on identical (fraction, reset) pairs can merge unrelated models that sit at 1.0 with no reset.
  - The sources differ on order: TMP implements now from existing evidence; MAIN wants a capture first. Enumerating entries and the `.decoding` case need no new semantics; pool collapsing and exhausted/unavailable handling wait for a sanitized capture (BND-09).
- **Tests / acceptance:** unknown ids still produce metrics; an empty-quota catalog gives `.decoding`; pooled entries follow the chosen rule; a no-match response never renders 100% remaining.
- **Relations:** WID-14 (TMP R-VIS-02 edits the same `modelSpecs`; Google trend colors change once), #65, COR-10 (placeholder counted as a window), PRV-27.

### PRV-11 Copilot plan variants: optional fields, Free tier, AI credits

- **Status / severity / effort / platform:** open; medium (TMP); effort M; Linux-testable.
- **Sources:** TMP R-BUG-19 (CLIENT-9); MAIN AM-PROV-Q3; REF-10 (rejected CLIENT-9 sub-claim). TMP backlog note (R-BUG-19): extends BACKLOG "Provider correctness > Copilot billing and fallback behavior".
- **Problem and evidence:**
  - `InternalUsageResponse` (`QC/Clients/CopilotClient.swift:389-399`, decoded at `:228-232`) requires `quota_reset_date` and `quota_snapshots`. VS Code's `IEntitlementsData` (`src/vs/base/common/defaultAccount.ts`) types both as optional.
  - Copilot Free uses `limited_user_quotas {chat, completions}`, `monthly_quotas` and `limited_user_reset_date` instead. VS Code computes remaining as `limited_user_quotas.chat / monthly_quotas.chat`, so the limited values are remaining counts.
  - Any response without the paid shape fails every refresh with Foundation's decoding text. Impact: Copilot Free accounts never show usage.
  - `copilot_plan` is required in GitHub's own types, so keeping it required is defensible (REF-10). The snapshot's `entitlement` and the missing `remaining` are further fragility.
  - MAIN capture questions: current AI-credit versus legacy premium-request plans, organization scope, UTC reset boundaries (PRV-22), and whether the exchanged token is valid for quota endpoints.
- **Proposal:**
  - Make `quota_reset_date` and `quota_snapshots` optional.
  - When snapshots are absent and `limited_user_quotas` is present, emit chat and completions metrics: remaining from the limited value, total from `monthly_quotas`, reset from `limited_user_reset_date` (a string in `IEntitlementsData`, a number in the token envelope; `parseDateValue` accepts both).
  - If neither shape is present, throw `.decoding` with fixed text, without Foundation's description.
  - Fall back to `access_type_sku` for the subtitle.
  - Label the new metrics "Monthly chat" and "Monthly completions", and relabel the existing chat/completions metrics in the same change (WID-15).
  - Model AI-credit plans only from a sanitized capture (BND-09).
- **Tests / acceptance:** a Free-shape fixture; a fixture with `quota_snapshots` missing; a fixture without `entitlement`; Foundation text never reaches the message.
- **Relations:** WID-15, PRV-15 (same client), PRV-22, PRV-26 (tier list), PRV-27.

### PRV-12 Kimi CLI sign-in imports die at token expiry

- **Status / severity / effort / platform:** open; medium (TMP); effort M; Linux-testable.
- **Sources:** TMP R-BUG-20 (GAPA-3). TMP backlog note (R-BUG-20): extends BACKLOG "Honest OAuth ownership" and "Discovery and import > Multi-account discovery and replacement"; the import-detection part duplicates "Compare provider-specific secret identity".
- **Problem and evidence:**
  - `scanKimi` (`QC/CredentialDiscovery.swift:205-245`, `:224-238`) imports the CLI's OAuth access token as `kimi.api_key`; only already-expired tokens are skipped.
  - `kimi.refresh_token` is stored ("so a future one can renew"), but nothing reads it and nothing re-adopts the Kimi file. At expiry every refresh fails with "Kimi authorization failed ... check the API key" (`QC/Clients/KimiQuotaClient.swift:59-60`).
  - Import detection matches any shared value (`LD/QuotaDaemon.swift:227-236`, `APP/AppModel.swift:581-590`, `CLI/main.swift:205-209`): an unchanged refresh token makes re-import print "already imported, skipping", and a rotated one creates a duplicate account.
  - macOS Auto-fill is a working recovery path. On Linux, remove plus import works but changes the id.
  - Impact: Kimi CLI imports stop updating, contradicting AGENTS.md's promise that imports work without the source tool, and a long-lived refresh token sits in settings for no purpose, unlike the Cline policy.
- **Proposal:** choose one:
  - Option A (matches Cline): store `kimi.expires_at` and stop importing the refresh token; at expiry the import needs a reimport.
  - Option B: an OpenAI-style pure adoption helper that re-reads `~/.kimi*/credentials/kimi-code.json` and adopts a strictly fresher token only when its refresh token matches the stored one. LLimit never refreshes the token itself.
  - Either way: on a 401 for an OAuth-sourced key say "Kimi sign-in expired. Run the Kimi CLI and re-import, or paste a console API key."
  - Make import detection compare only the primary secret, here `kimi.api_key` (PRV-18).
- **Tests / acceptance:** discovery stores the expiry; adoption matches the same login only; import detection ignores refresh-token overlap; the 401 copy names the sign-in.
- **Relations:** PRV-18; PRV-19 (drop `kimi.refresh_token` when `kimi.api_key` changes); #104 implements TMP R-LNX-03, whose fix includes primary-secret detection, but whether #104 contains that part, and whether it covers the macOS copy, is unconfirmed.

### PRV-13 Meta Muse cannot show an exhausted subscription

- **Status / severity / effort / platform:** open; medium (TMP); effort M; Linux-testable once a capture exists. Do not implement speculatively.
- **Sources:** TMP R-BUG-23 (CLIENT-10).
- **Problem and evidence:**
  - The probe is a real inference request (`QC/Clients/MetaMuseQuotaClient.swift:57-64`). Any non-2xx throws (`:66-77`), and a 429 becomes `.rateLimit` with an echoed body excerpt. The "Quota exhausted" branch (`:123`, `:131`) needs a 200 stream.
  - Surfaces therefore keep the last good reading (for example 92% used), so users see "High usage" plus a rate-limit error instead of "exhausted until <time>".
  - Unverified: whether an exhausted subscription answers the probe with 429 or 403, and whether that body carries a snapshot or reset data. Needs a live capture from an exhausted account.
- **Proposal (after a capture):**
  - On a 429 or 403, first run `subscriptionUsageSnapshot(in:)` over the body.
  - If the error type or code says usage is exhausted and carries `resets_at` or `resets_in_seconds`, return 0% remaining with that reset.
  - A plain 429 stays `.rateLimit` with fixed text.
  - Build on #69's completion and last-good handling (absent versus malformed windows, recognizable completion) rather than a parallel path.
- **Tests / acceptance:** a 429 with a snapshot; a 429 usage-limit body with reset info; a plain 429 (fixed text, no body).
- **Relations:** #69, #70, #77 (`retryAt` for a plain 429), COR-06, PRV-27. TMP notes the exhausted state cannot reach Muse surfaces until this lands.

### PRV-14 Claude extra-usage amounts and currency

- **Status / severity / effort / platform:** partial. #93 (open) divides minor units by 100 and reads `extra_usage.currency`. Remaining: the unit contradiction, non-USD amounts, a capture tied to a known billing amount, and the cap-reached display. Medium (TMP, verifier correction: display-only, one surface); effort S; Linux-testable.
- **Sources:** TMP R-BUG-06 (CLIENT-3); MAIN AM-PROV-Q2; REF-09 (rejected CLIENT-3 sub-claim); LEDGER #93 deferrals.
- **Problem and evidence:**
  - Baseline `QC/Clients/AnthropicClient.swift:109-123` (`:120`) printed amounts raw via `formatIntLike` (`QC/Utilities.swift:115-121`, no scaling): `{"is_enabled":true,"monthly_limit":100000,"used_credits":1234}` rendered "Extra: $1234 / $100000".
  - CONTRADICTION. TMP: Claude Code's own bundled schema says the amounts are "minor units of `currency` (cents for USD)", and its gateway docs say "`monthly_limit` and `used_credits` are cents" with the example `{"monthly_limit": 50000, "used_credits": 27140}`. MAIN: get a response tied to a known billing amount before changing units. Decide before merging #93.
  - Non-USD or unknown currencies fall back to "Extra usage on" until a capture exists.
  - PowerQuota notes that `is_enabled` turns off at the cap, so the current gate hides the line exactly when the cap is reached. What to show then is undecided; one option is "Extra usage cap reached".
  - Only the dropdown card renders the subtitle (`APP/LLimitApp.swift:1446`; REF-09); widgets and Linux do not.
- **Proposal:**
  - Settle the units: either accept TMP's schema and docs evidence and merge #93, or hold it until one sanitized capture from an account with a known billed amount confirms the scale.
  - Add non-USD formatting (POSIX `NumberFormatter`, currency minor-unit digits) only after a capture shows a non-USD response.
  - Decide the cap-reached copy.
  - Record the units in the AGENTS.md Anthropic notes if #93 did not. A shared `formatUSD(_:)` helper (Cline and Venice each have their own) stays optional.
- **Tests / acceptance:** the fixture above gives "Extra: $12.34 / $1000.00"; a disabled object gives no subtitle (or the chosen cap text when the cap is reached); a non-USD currency uses the fallback; a captured fixture pins the scale.
- **Relations:** #93; #84 covers #93's deferred nil `maxUsagePercent` when no window parsed (COR-10); TMP R-FEAT-01 (#93 deferral: extra usage on ring tiles and the dashboard widget); PRV-27 (private Anthropic headers in the same capture).

### PRV-15 Copilot 503 reported as auth

- **Status / severity / effort / platform:** open; unrated in MAIN; effort S (estimate); Linux-testable.
- **Sources:** MAIN A03.
- **Problem and evidence:**
  - `fetchFromInternalAPI` (`QC/Clients/CopilotClient.swift:144-158`) tries the legacy token, then bearer, then a session-token exchange, and finally throws `.auth` with `quotaUnavailableMessage`.
  - `fetchInternalUser` (`:216-225`) returns nil for every non-2xx except 429, including 503. The exchange loop (`:274-287`) `continue`s on any non-2xx except 429 and on an undecodable payload.
  - A 503 therefore walks every auth path (up to four sequential round trips, PRF-11) and ends as `.auth`. The 429 branches echo the body ("Copilot quota API rate limited: \(body)").
  - #65 (MAIN-reported) says Copilot quota non-401/403/404 statuses and token-exchange 5xx no longer fall through to `.auth`, and its incoming copy says `.api` includes response bodies.
- **Proposal:** reconcile #65's fallback hardening first. Target: the first 503 makes one sanitized `.api` failure with no further requests; a malformed successful exchange is `.decoding`; 429 stays `.rateLimit` (with #77's `retryAt` where applicable) and the supported 401/403/404 auth fallback keeps working; no raw-body errors return when integrating #70.
- **Tests / acceptance:** a first 503 issues exactly one request and gives sanitized `.api`; a malformed exchange gives `.decoding`; 429 gives `.rateLimit` with no body text; 401 on the legacy path still falls back to bearer and the exchange.
- **Relations:** #65, #63, #70, #77, COR-06, PRF-05, PRF-11, PRV-01, PRV-11.

### PRV-16 Claude imports ignore expiry; an OpenCode entry hides the Keychain

- **Status / severity / effort / platform:** open; low (TMP), unrated in MAIN; effort S; discovery parsing is Linux-testable, the Keychain scan is macOS-only.
- **Sources:** TMP R-BUG-38 (GAPA-4); MAIN A06.
- **Problem and evidence:**
  - The `~/.claude` file import already skips expired tokens (`QC/CredentialDiscovery.swift:105-112`). The OpenCode branch (`:364-368`) ignores OpenCode's `expires`, the Keychain path (`APP/AppModel.swift:615-630`) ignores `expiresAt`, and no import stores `anthropic.expires_at`.
  - The Keychain is consulted only when no file-based Anthropic candidate exists (`APP/AppModel.swift:501-519`, `:505-507`). Any OpenCode Anthropic candidate, even a stale or different account, suppresses ordinary Keychain discovery, the hazard `scanClaudeCode` guards against.
  - Impact: one-click import can create an account that is already dead.
- **Proposal:**
  - Parse both expiry fields with `parseDateValue`, skip expired tokens with a "token expired" diagnostic, and store `anthropic.expires_at` so the UI can warn before expiry.
  - Explicit Claude and all-provider scans include and dedupe Keychain candidates; scans for other providers never prompt the Keychain (keep the existing guard).
  - Choosing the freshest of the file, OpenCode and Keychain tokens by expiry, and recording the source identity on linked imports, is BKL-03's remaining work.
- **Tests / acceptance:** expired OpenCode is skipped; a valid one carries its expiry; 0 or missing expiry is kept; distinct injected OpenCode and Keychain sources both appear; identical tokens dedupe; a non-Claude scan never reads the Keychain.
- **Relations:** LNX-02 (#104 deferred carrying the Claude `expiresAt` on Linux), BKL-11 (narrow the BACKLOG expiry item), BKL-03, PRF-08 (Keychain reads off the main actor), PRV-18, PRV-22 (sentinel 0).

### PRV-17 Discovery paths: CLAUDE_CONFIG_DIR, XDG roots, multiple Antigravity accounts

- **Status / severity / effort / platform:** open; low (TMP), unrated in MAIN; effort S; Linux-testable.
- **Sources:** TMP R-BUG-41 (AUTH-11); MAIN A07.
- **Problem and evidence:**
  - Claude is read only from `~/.claude` and Codex only from `~/.codex`. Several paths ignore `XDG_CONFIG_HOME`. Devin and Muse accept relative XDG values while OpenCode requires an absolute path (`QC/CredentialDiscovery.swift:94-96`, `:126-128`, `:160-161`, `:339-346`, `:405-408`, `:445`, `:552-553`, `:596-597`).
  - Antigravity companion discovery ignores custom XDG data roots and returns only one of several accounts (`:339-345`, `:403-440`).
  - Impact: the import shortcut and OpenAI adoption silently find nothing for relocated config directories, mostly on Linux.
  - Unverified as new: most of this duplicates BACKLOG "Current paths, metadata, and diagnostics" (`XDG_*`, `CODEX_HOME`, injectable resolution). Only `CLAUDE_CONFIG_DIR` and the inconsistent relative-XDG handling are new.
- **Proposal:**
  - Read absolute `CLAUDE_CONFIG_DIR` and `CODEX_HOME` from the injected environment and probe them first.
  - Use one `xdgPath(_:)` helper that rejects relative values everywhere.
  - For Antigravity, reuse the resolved OpenCode roots and enumerate distinct usable accounts without mixing token and project fields.
  - Never surface LLimit's own managed profile directories as imports.
- **Tests / acceptance:** one fixture per variable plus relative-value rejection; custom XDG roots; two Antigravity accounts; migration-root duplicates appear once.
- **Relations:** PRV-16, PRV-18 (dedupe), SEC-01 (OpenAI adoption from a relocated `CODEX_HOME` still needs identity binding), TMP R-LNX-08 (daemon and CLI XDG paths).

### PRV-18 Import dedup matches any shared metadata

- **Status / severity / effort / platform:** open; unrated in MAIN; effort S (estimate); Linux-testable if the helper moves to QuotaCore.
- **Sources:** MAIN A05.
- **Problem and evidence:** `isDetectedCredentialImported` exists twice (`APP/AppModel.swift:583-588`, `LD/QuotaDaemon.swift:227-235`). Both build the set of all non-empty credential values and report a match when it intersects any account of the same provider. Shared metadata such as a Devin server URL or a Google project id therefore blocks distinct imports, and shared refresh tokens hide changed access tokens (PRV-12).
- **Proposal:** one QuotaCore helper that compares keyed, provider-specific authenticators (the primary secret per provider, for example `kimi.api_key`), used by both platforms. #104 may already include primary-secret detection for Linux (unconfirmed, see PRV-12).
- **Tests / acceptance:** different Devin keys on one server and Google tokens sharing a project stay importable; identical keys dedupe; Kimi refresh-token overlap is ignored.
- **Relations:** PRV-12, PRV-16, PRV-17, PRV-25, #104 (TMP R-LNX-03).

### PRV-19 Pasting a new OpenAI access token keeps the old refresh token

- **Status / severity / effort / platform:** open; low (TMP: needs a manual paste of another account's token); effort S; Linux-testable helper.
- **Sources:** TMP R-BUG-40 (GAPA-1). TMP backlog note (R-BUG-40): extends BACKLOG "Honest OAuth ownership" (validate identity before replacing credentials).
- **Problem and evidence:**
  - Only Anthropic clears hidden metadata on edit (`QC/ClaudeCodeProfile.swift:166-170`, `clearManagedMetadata`). The hidden `openai.refresh_token` is not in the form, so it survives the paste (`QC/Models.swift:81-95`; `APP/AppModel.swift:655-664`).
  - Near expiry or on a 401, LLimit refreshes with the old grant, writes the old account's token and id back, and rotates (logs out) the Codex CLI's grant for that account (`APP/AppModel.swift:700-720`, `:730-764`, `:1192-1207`).
  - Impact: a manual credential edit is silently reverted.
- **Proposal:**
  - Add a pure QuotaCore helper modeled on `clearManagedMetadata`: `credentialsAfterManualEdit(_:key:value:)`. Drop `openai.refresh_token` only when the pasted JWT's `chatgpt_account_id` differs from the stored id (the verifier's gentler rule); re-derive `openai.account_id` from a decodable JWT; drop `kimi.refresh_token` when `kimi.api_key` changes. SEC-01 also requires the user claim, so compare it too when both tokens carry one.
  - In `refreshOpenAIAccount` (app and daemon), reject refresh results whose account id differs from the stored one. This also covers TMP R-SEC-06 (SEC-01).
  - Run the helper where edits commit (#101's `PendingEdits`), and leave `env:NAME` references (#86) untouched; a non-JWT value keeps the typed id.
- **Tests / acceptance:** an edit to a different account clears the refresh token; the account id is re-derived; a non-JWT paste keeps the typed id; Claude behavior is unchanged; a mismatched refresh result is rejected.
- **Relations:** SEC-01, PRV-01, PRV-12, #101, #86, COR-05.

### PRV-20 Copilot discovery imports GitHub Enterprise logins

- **Status / severity / effort / platform:** open; low (TMP); effort S; Linux-testable.
- **Sources:** TMP R-BUG-39 (GAPA-5).
- **Problem and evidence:** every `apps.json` or `hosts.json` key is imported, including `corp.ghe.com:…` (`QC/CredentialDiscovery.swift:155-183`), but the client hard-codes `https://api.github.com` (`QC/Clients/CopilotClient.swift:10`, `:139-158`). The account can never succeed and shows a misleading error, and the enterprise token is sent to the wrong host.
- **Proposal:** import only `github.com` keys and add a diagnostic for others: "GitHub Copilot: skipped enterprise login for <host> (not supported)". Supporting enterprise hosts instead would need a per-account API host and a capture (BND-09).
- **Tests / acceptance:** a file with github.com and ghe.com entries imports one account and records the diagnostic.
- **Relations:** PRV-11, PRV-17.

### PRV-21 Non-JSON 200 responses become .unknown

- **Status / severity / effort / platform:** open; low (TMP); effort S; Linux-testable.
- **Sources:** TMP R-BUG-36 (CLIENT-12).
- **Problem and evidence:** `parseJSONObject` (`QC/Utilities.swift:140-146`) lets `JSONSerialization` errors escape. A captive-portal HTML page or a truncated body throws an NSError, which the coordinator records as `.unknown` with Foundation's text (`QC/QuotaCoordinator.swift:71-82`). Affected: Anthropic, Kimi, Devin, Zhipu and Google's models call. The failure kind is wrong and the message names no provider.
- **Proposal:** wrap the call and throw `ProviderClientError(kind: .decoding, message: "Response was not valid JSON.")`. First check whether #63's bounded decoding already does this. TMP files it under BACKLOG "Network layer > Dedicated resource-bounded HTTP client (normalize parser failures to .decoding)".
- **Tests / acceptance:** an HTML body gives `.decoding` in `QuotaUtilitiesTests` and `AnthropicClientTests`, with no Foundation text.
- **Relations:** #63, #84, COR-06, PRF-05, PRV-01 (HTML 403 detection).

### PRV-22 Epoch, sentinel and timezone parsing

- **Status / severity / effort / platform:** open; MAIN pass-D report, unrated; effort S to M (estimate); Linux-testable.
- **Sources:** MAIN A09.
- **Problem and evidence:**
  - `dateFromEpochTimestamp` (`QC/Utilities.swift:223-241`, reached from `parseDateValue` `:199-217`) scales by magnitude only: at least 1e18 is nanoseconds, 1e15 microseconds, 1e12 milliseconds, anything smaller seconds. Millisecond values before 2001 (below 1e12) are read as seconds, far in the future (MAIN: around year 5000).
  - Reset sentinels 0 and -1 become 1970 dates with a perpetual "reset". Only the Claude file import guards `> 0` (`QC/CredentialDiscovery.swift:107`).
  - `monthEndDate` and `startOfNextMonth` (`QC/Utilities.swift:276-302`) use a Gregorian calendar in the machine time zone for assumed Copilot and Zhipu resets (`QC/Clients/CopilotClient.swift:109-110`, `:168`; `QC/Clients/ZhipuQuotaClient.swift:210`).
- **Proposal:** establish each provider's units and sentinel semantics with fixtures; pass explicit units or context instead of another global magnitude guess. Reject invalid reset sentinels at the provider boundary without forbidding legitimate general epoch dates. Pin the monthly helpers to UTC only after the contract is verified (PRV-11 capture).
- **Tests / acceptance:** historical milliseconds, valid seconds and milliseconds, 0 and -1, malformed and far-future values, UTC month boundaries, and several machine time zones.
- **Relations:** PRV-11, PRV-16, PRV-27, PRF-12 (date parsing cost).

### PRV-23 Window classification and cadence labels disagree

- **Status / severity / effort / platform:** partial. #65 (MAIN-reported) labels exact OpenAI 45-minute, 25-hour and N-second windows with classifier tests. Remaining: `classify` bucketing and one shared formatter. Low (TMP: latent, current Muse and Kimi windows are 300 minutes and weekly windows use separate ids); effort S; Linux-testable.
- **Sources:** TMP R-BUG-32 (CORE-6, CLIENT-15).
- **Problem and evidence:**
  - `QuotaWindowKind.classify` (`QC/Models.swift:816-822`) makes any N-hour value of 20 or more, or N-minute value of 1,200 or more, `.daily`, so "168-hour limit" and "720-hour limit" are both daily.
  - Day counts are bucketed: "14-day" is monthly while "2-week" is weekly.
  - OpenAI's formatter (`QC/Clients/OpenAIClient.swift:119-127`) rounds 43,200 s to "1-day limit" (daily), while Codex (`QC/CodexRateLimits.swift:63-68`) renders the same window as "12-hour limit" (session), so managed and imported accounts get different colors. Check whether #65's exact labels already fix this case.
  - Muse (`QC/Clients/MetaMuseQuotaClient.swift:148-152`) and Kimi (`QC/Clients/KimiQuotaClient.swift:181-201`) fold minutes only into hours.
  - Impact: windows longer than a day would get the wrong color and wrong short-term or long-term handling.
- **Proposal:**
  - Convert to hours and bucket once: under 20 h session, up to 36 h daily, up to 13 days weekly, longer monthly. Keep the existing pins: 20-hour and 1440-minute are daily, 13-day is weekly, 14-day is monthly. TMP also expects "2-week" to stay weekly, which keeps the 14-day versus 2-week inconsistency it reports; decide that explicitly.
  - Add a shared `windowCadenceLabel(seconds:)`: exact days give "N-day", exact hours "N-hour", anything else "N-minute". Use it in OpenAI, Codex, Muse and Kimi.
  - Root fix: persist `windowKind`/`windowSeconds` (DEBT-03; #103 adds `windowSeconds`) so `classify` prefers reported durations; BACKLOG "Appearance model cleanup" (declare the window kind).
- **Tests / acceptance:** "168-hour limit" and "10080-minute limit" are weekly; "720-hour limit" is monthly; "2-week limit" is weekly; OpenAI 43,200 s gives "12-hour limit"; existing pins hold.
- **Relations:** #65, #103, DEBT-03, PRD-02, PRV-29 (duration-based ids).

### PRV-24 OpenAI accounts never get the 80% "High usage" warning

- **Status / severity / effort / platform:** open; low (TMP: macOS only; Linux classes already escalate); effort S; Linux-testable.
- **Sources:** TMP R-UX-14 (CLIENT-16).
- **Problem and evidence:** OpenAI (`QC/Clients/OpenAIClient.swift:100`) and Codex (`QC/CodexRateLimits.swift:54-60`) warn only when a limit is reached; `QCT/CodexRateLimitsTests.swift:22` pins nil at 80%. Nine other clients warn at 80% or more, each with a duplicated threshold. The warning renders at `APP/LLimitApp.swift:1408` and `WX/ProviderQuotaWidget.swift:446`.
- **Proposal:** add `standardUsageWarning(maxUsagePercent:exhaustedText:)` in Utilities and use it for OpenAI and Codex; migrate the other clients, keeping their provider-specific exhausted text; update the pinned test deliberately.
- **Tests / acceptance:** OpenAI at 85% gives "High usage"; the managed Codex path matches; `limit_reached` gives "Rate limit reached".
- **Relations:** WID-04 (severity thresholds across surfaces), #100 and #110 (alert thresholds).

### PRV-25 Imports create duplicate account names

- **Status / severity / effort / platform:** open; low (TMP); effort S; Linux-testable.
- **Sources:** TMP R-UX-16 (SETTINGS-10).
- **Problem and evidence:**
  - Imports use the suggested name verbatim ("Claude", "Kimi", "Venice", "Cline", "Devin", "Meta Muse"); only manual adds de-duplicate (`APP/AppModel.swift:559-579`, `:1656-1672`; `LD/QuotaDaemon.swift:188-195`, `:553-566`).
  - Tile pickers and trend toggles become indistinguishable, and the Automatic label omits the provider (`APP/Views/SettingsView.swift:520-541`). Copilot and Antigravity already embed identity hints in the suggested name.
- **Proposal:**
  - A shared QuotaCore `uniqueAccountDisplayName(base:existing:)` (case-insensitive, appending " 2", " 3" and so on) for add and import on both platforms; delete the two private copies.
  - Show "Name (Provider)" in the Automatic label.
  - Land TMP R-UX-01's stable order before any automatic renaming. Name only new accounts; never rename existing ones.
- **Tests / acceptance:** importing a second "Kimi" gives "Kimi 2" on macOS and in `llimit accounts import`.
- **Relations:** PRD-05, PRV-18, #104 (Linux rename and update), TMP R-UX-01.

### PRV-26 Copilot form marks every field Optional and accepts any tier text

- **Status / severity / effort / platform:** open; low (TMP); effort M; descriptor and validation are Linux-testable, the Picker is macOS-only.
- **Sources:** TMP R-UX-17 (SETTINGS-11).
- **Problem and evidence:**
  - All four Copilot fields say "Optional" (`QC/Models.swift:136-163`, `:220-229`; `APP/Views/SettingsView.swift:1036-1064`), yet empty fields report "Missing: OAuth token or PAT plus username" (`QC/Clients/CopilotClient.swift:95`). A token, or a PAT plus username, is required.
  - `parseTier` (`QC/Clients/CopilotClient.swift:298-318`) accepts only five spellings; "Copilot Pro" silently falls back to the inferred limit.
- **Proposal:**
  - Add `choices` and `requirementGroup` to `CredentialFieldDescriptor`, and render the tier as a Picker (Automatic, Free, Pro, Pro+, Business, Enterprise).
  - Show one group caption: "Enter an OAuth token, or a PAT plus username."
  - Add `credentialIssues(in:)` so both Settings and `llimit accounts add` can warn.
- **Tests / acceptance:** tier validation (unknown text is rejected or flagged, not ignored) and the group message on both platforms.
- **Relations:** PRD-05, PRV-11 (plan list should follow captured plans), DEBT-05 (provider metadata), SEC-06 (scripted setup).

### PRV-27 Provider contract captures: Zhipu/Z.ai, Devin, private headers, fixture rules

- **Status / severity / effort / platform:** open; capture work, unrated; effort per capture S; fixtures are Linux-testable.
- **Sources:** MAIN AM-PROV-Q0 (fixture rules), AM-PROV-Q6; LEDGER #89 and #90 deferrals; TMP R-BUG-01, R-BUG-02.
- **Problem and evidence:**
  - Earlier reports found empty Anthropic schemas, unsupported Zhipu limit types and missing Google fractions treated as zero. #65/#84 (MAIN-reported) now cover Google unknown handling, Anthropic all-unreadable failure with partial preservation, Zhipu's optional numeric `code`, exact OpenAI window labels and heterogeneous Kimi limits. Reconcile these rather than reimplementing them.
  - Open questions: the Zhipu no-supported-limit case (validation candidate); Zhipu/Z.ai percentages and endpoints; whether `open.bigmodel.cn` (Zhipu) returns a weekly entry, since #90 must behave the same with one entry or two; logging of unknown (unit, number) pairs, deferred because QuotaCore has no logger; Devin's top-level `planInfo` copy, which oh-my-pi treats as authoritative and #89 does not read; an overage balance outside `planStatus`, since #89 probes `overageBalanceMicros` (proto field 16, int64 micros) only there; private Google and Anthropic headers.
- **Proposal:** capture sanitized responses for each open question, then adopt semantics from them only (BND-09). Fixture rules: distinguish unknown from zero, require a recognizable success, keep valid partial windows, and leave the aggregate nil when there are no bounded metrics. Route unknown-pair logging through DEBT-01 once QuotaCore has a logger.
- **Tests / acceptance:** each capture becomes a committed sanitized fixture with provenance; missing, empty and hostile-number fixtures pass the four rules; #89/#90 tests stay green.
- **Relations:** #65, #84, #89, #90, DEBT-01, PRV-10, PRV-11, PRV-14.

### PRV-28 Claude CLI namespace and User-Agent compatibility

- **Status / severity / effort / platform:** open; verification work, unrated; effort S per CLI release (estimate); needs the real CLI, mostly macOS.
- **Sources:** MAIN AM-PROV-Q4.
- **Problem and evidence:** compatibility of the official Claude CLI's profile namespace (`CLAUDE_CONFIG_DIR`) and renewal behavior with LLimit, and of #91's cached detected-version `claude-code/<ver>` User-Agent (replacing the frozen `claude-code/1.0.110`), is unproven. The User-Agent is mandatory; without it the usage endpoint hard rate-limits. Synthetic ordering tests do not prove every CLI version works. Known version-specific behavior: Claude Code 2.1.291's proper-lockfile locks (PRV-09); offline exit codes are unverified (PRV-03).
- **Proposal:** a per-release manual check against the current and previous CLI: profile isolation, renewal with the refresh token, lock and marker handling, and the detected version reaching the User-Agent. Record results next to the AGENTS.md Anthropic notes.
- **Tests / acceptance:** a recorded run per checked CLI version; #91's fallback when no version is detected is covered by a unit test.
- **Relations:** #91, PRV-03, PRV-05 (version detection needs the CLI path), PRV-09.

### PRV-29 OpenAI and Codex additional limit fields

- **Status / severity / effort / platform:** open; capture work, unrated; effort M (estimate, includes an id migration); Linux-testable once captured.
- **Sources:** MAIN AM-PROV-Q5; TMP R-BUG-13 (root fix), R-BUG-17. TMP backlog note (R-BUG-13, the root fix): extends BACKLOG "Appearance model cleanup (declare window kind on UsageMetric)".
- **Problem and evidence:**
  - Additional limits, credits, `allowed`, the reached type and absolute reset fields are not decoded. Decode them optionally, and only from captured contracts; keep #65's label-to-kind tests.
  - OpenAI and Codex name windows by response slot (`primary`, `secondary`; `QC/Clients/OpenAIClient.swift:70-76`, `:110-125`; `QC/CodexRateLimits.swift:36-40`), and the duration lives only in the label. #109 splits trend series when the kind changes; the root fix is duration-based ids, as Kimi already uses (`window-5-hour`, `plan-weekly`). Unverified: nothing in the code shows OpenAI moving a window between slots.
  - The same Codex capture should settle the app-server refresh behavior (PRV-08).
- **Proposal:** capture `wham/usage` and app-server `account/rateLimits/read` responses, add optional fields from them, and introduce duration-based ids with a one-time migration of history ids and of the `defaultRingMetrics` preference `["primary","secondary"]`.
- **Tests / acceptance:** captured fixtures decode with and without the new fields; migrated history keeps one series per window; ring preferences resolve to the same windows after migration.
- **Relations:** PRV-08, PRV-23, #65, #109, DEBT-03.

## Performance, networking and scheduling

This section covers scheduling, networking and main-actor work. Source inspection proves blocking work and full-archive decoding. It does not prove measured stutter, multi-second hangs, OOM or a fixed WidgetKit memory limit, and the older 30 MB widget budget is unverified. Profile before optimizing (Instruments, RSS, archive sizes). The only measurement in the sources is TMP R-BUG-09's Linux swift-foundation benchmark: 3,000 snapshots x 4 accounts is about 8 MB, with about 0.28 s per decode and 0.33 s per encode. macOS was not measured. Line references are baseline `2d6ac1e`.

### PRF-01 Refresh scheduling ignores snapshot age, wake, network return and failures
- **Status / severity / effort / platform:** open; medium (TMP lowered it from high because the UI shows the update age and manual Refresh works); M; the pure scheduler is Linux-testable, while the wake and network observers are macOS-only.
- **Sources:** TMP R-BUG-22 (APPMODEL-1, LINUX-7; extends BACKLOG "Network layer > Rate limits, retries, and scheduling" and Product backlog #8); MAIN F06; LEDGER #102 deferral.
- **Problem and evidence:**
  - Bootstrap skip plus a full-interval wait, on both platforms. `APP/AppModel.swift:131-135` starts the loop and then refreshes only if `shouldRefreshOnBootstrap` (`:1797-1812`) finds the snapshot at least one interval old. `restartAutoRefreshLoop` (`:1763-1786`) always sleeps a full interval first (`:1774`). The daemon does the same in `LD/QuotaDaemon.swift:336-375` (`runRefreshLoop`, `refreshCycle(bootstrap:)`) and `:571-593`. A 29-minute-old snapshot with a 30-minute interval sleeps another 30 minutes after a restart, so data can reach about twice the interval in age.
  - Nothing observes wake or network changes, and nothing calls `ProcessInfo.beginActivity`. App Nap can defer ticks. There is no failure backoff.
  - macOS: changing the interval restarts the countdown from zero (`APP/AppModel.swift:1231-1243`, restart at `:1240`).
  - Linux: after an all-network failure the next attempt comes 30 to 180 minutes later, and the systemd units' `network-online` ordering is a no-op (LNX-14). New CLI accounts wait a full interval. With no accounts the daemon keeps ticking, because `shouldRefreshOnBootstrap` returns false but the loop continues.
  - Manual refreshes have no shared deadline.
  - Dropped ticks (#102 deferral): `refreshNow` returns at once when `isRefreshing` is set or a Codex operation is busy (`APP/AppModel.swift:187-193`). An auto tick that lands during a targeted single-account refresh is dropped, and the next attempt waits a full interval.
  - Unverified (macOS sleep pause): `Task.sleep(nanoseconds:)` pauses during system sleep only on the Swift 6.1-or-older runtime (macOS 14/15). On macOS 26 (Swift 6.2) it uses the continuous clock and fires right on wake, possibly before the network is back. The shipped LLimitd uses the Swift 6.2.3 static SDK and does not share the sleep-pause bug (REF-12).
  - Impact: data stays stale after launch, wake, a network outage or account setup, with no visible reason.
- **Proposal:**
  1. Add a pure `RefreshSchedule.nextDue(...)` in QuotaCore with an injectable clock and sleeper. Inputs: the last attempt and its outcome, the last success, the interval, the snapshot `generatedAt`, and the settings-file mtime (Linux).
  2. Rules: at bootstrap, due = `generatedAt + interval`, so overdue data refreshes immediately. After an all-network failure, back off 1, 2, 4… minutes, capped at the interval. Reuse #77's `ProviderFailure.retryAt` for per-account cooldowns rather than adding a duplicate field. A settings mtime change makes a refresh due now, which covers new CLI accounts. An interval change only recomputes the due time. With no configured accounts, suspend.
  3. Loops sleep `min(60 s, due - now)` and re-evaluate, which handles sleep and clock jumps.
  4. Coalesce manual, wake and network-return refreshes into one deadline, with jitter and a cooldown. A tick that finds a refresh in flight becomes due when that refresh ends instead of being dropped.
  5. macOS: observe `NSWorkspace.didWakeNotification` and an `NWPathMonitor`. After wake, refresh once the path is satisfied plus 5 to 10 s. Wrap each refresh in `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)`.
  6. Decouple scheduling from execution: run each refresh in its own task that rescheduling never cancels (TMP R-BUG-26).
  7. Optional, from TMP R-BUG-21: wake the loop at the earliest `resetAt` plus 60 s, bounded by each provider's minimum poll interval (Anthropic: no faster than about 3 minutes, per AGENTS.md).
- **Tests / acceptance:** table tests for `nextDue` across sleep gaps, interval shrink and grow, overdue-at-launch, network backoff and mtime change. A snapshot one minute short of the interval refreshes after one minute; overdue data refreshes immediately. A tick during a targeted refresh runs after it completes. No accounts means no ticks.
- **Relations:** COR-08 (TMP R-BUG-27: single-account refreshes bump `generatedAt`, so a quick relaunch skips the bootstrap refresh and this schedule would trust a misleading timestamp). LNX-14 (the timer hard-codes 30 minutes and `Persistent=` is ignored; it relies on this retry). TMP R-BUG-26 and MAIN C10 (an interval change cancels the in-flight refresh). TMP R-LNX-11 (the SIGTERM handler should wake the sleep, not cancel the cycle). COR-02 / MAIN C05 (cross-process refresh coalescing). PRF-05 (transient classes). REF-12. AppModel.swift merge conflicts with #94, #101, #102, #104, #106 and #107.

### PRF-02 Synchronous persistence on the main actor
- **Status / severity / effort / platform:** partial. #94 cuts a publish to one decode and one encode. #101's drafts and #85's 400 ms debounce (MAIN-reported) reduce edit saves. Remaining: an off-main persistence service. Severity not rated by the sources; effort M (estimate); macOS-only wiring, though a QuotaCore persistence service can be Linux-tested.
- **Sources:** MAIN F02; LEDGER #94, #101; MAIN-reported #85.
- **Problem and evidence:**
  - Edits and publication synchronously encode, write and reload local and App Group stores on `@MainActor`: `APP/AppModel.swift:163-175` (`saveConfiguration`: settings save plus App Group settings sync), `:274-289` (`publishSnapshot`: history append, `reloadRecentHistory`, App Group snapshot and history syncs), `:1759-1760` (`reloadRecentHistory` decode), and `:2020-2031`. At baseline only timeline reloads were debounced (800 ms).
  - #85 reports 400 ms coalescing for keystrokes and color drags, a synchronous `willTerminate` flush (observer queue nil, because async hops may be dropped on quit) and a resign-active flush. Debouncing does not establish off-main I/O or measured responsiveness.
  - #101 commits `PendingEdits` drafts on submit, focus loss, selection change, close and quit.
- **Proposal:**
  1. Choose between #101 and #85 first; they overlap on the same AppModel edit path.
  2. Put persistence behind an application service (UI and controllers must not touch stores directly, per AGENTS.md). Move encoding and I/O off the main actor and serialize writes there. TMP's R-PERF-01 follow-up names a `HistoryWriter` actor for history I/O.
  3. Skip identical redacted writes (shared payload hash with PRF-06).
  4. Flush final edits on focus loss, close, termination, and before Test Connection or Refresh. Auth durability stays immediate (rotated grants, and the throwing durable history clear on a Venice key change). The earlier 500 ms figure is a tuning candidate, not a durability rule; #85 uses 400 ms.
- **Tests / acceptance:** slow-storage tests with an injected slow writer show typing and resize stay responsive and the final edit is durable. Instruments confirms the main thread no longer encodes or writes. Quitting with a pending edit persists it. An identical redacted payload writes nothing.
- **Relations:** PRF-03, PRF-04, PRF-06, PRF-09. MAIN F09/#68 (Venice key invalidation). MAIN C06 (persistence failures reported as success). AppModel.swift conflicts with #94, #101, #102, #104, #106 and #107.

### PRF-03 History archive retention, size and widget projection
- **Status / severity / effort / platform:** partial. #94 reduces per-publish decoding; #52 and #76 (MAIN-reported) reduce appends. Remaining: a retention policy, byte bounds and a bounded trend projection. Low (TMP); M; retention and projection building are Linux-testable, widget consumption is macOS-only.
- **Sources:** TMP R-BUG-33 (CORE-7; extends BACKLOG "Storage and performance > Replace whole-file history archives", whose byte-size part it duplicates); MAIN F01; LEDGER #94 deferral.
- **Problem and evidence:**
  - `QC/QuotaHistoryStore.swift:19-41`: `load` and `loadRecent` decode the full archive before filtering. `:55-74`: `append` loads, filters to 45 days, sorts, caps at 3,000 entries, then `save` (`:43-53`) sorts again. The cap counts entries, not bytes. App publication then reloads a two-day slice (`APP/AppModel.swift:42-45`). The trend widget calls `loadRecent(days: windowDays + 1)` (`WX/QuotaTimelineProvider.swift:93-99`), which still decodes everything; the trend window is at most 30 days (`QC/Models.swift:1355-1357`) and the chart caps display at 240 points (`WX/LLimitQuotaWidget.swift:838`). Decode cost grows with the archive.
  - Truncation affects only the minimum 15-minute interval. A 30-day window needs 2,880 entries, leaving about 120 extra appends (manual or post-login) before the visible chart is truncated. The original "24 extra appends" figure only trims the one-day buffer (REF-13). The default 30-minute interval uses about 1,490 entries.
  - Impact: with frequent manual refreshes the "30-day" chart quietly covers fewer days.
- **Proposal:**
  1. Decide the retention policy (#94 deferred this pending a decision). TMP proposes time-tiered retention in `append`: keep every entry from the last 48 h; keep one entry per hour older than that, plus any entry where a metric's remaining percent rises (a reset); then apply `keepDays`. This holds 45 days in about 1,100 entries.
  2. Add a byte bound alongside the entry cap.
  3. Publish a bounded, credential-free `quota-trend.json` projection so windowed widget reads never decode the raw archive. Downsample before sharing.
  4. Consider partitioned, indexed or append-only storage only with preservation tests and measured need.
  5. Preserve #52/#75/#76 semantics (LES-02): a no-op append still enforces retention, sparse entries are source observations, and timestamp folding or forward fill cannot create samples.
- **Tests / acceptance:** 3,200 entries at 15 minutes plus 50 extras: `loadRecent(days: 31)` spans at least 30 days and keeps the reset jumps. Benchmark 12 accounts with multiple metrics at 3,000 entries and with 45-day archives: append latency, UI stalls, widget RSS. The projection matches the filtered, downsampled raw history.
- **Relations:** TMP's usage ledger (`usage-ledger.json`, see the ideas intro) sits outside the cap and also spares the main actor a history decode. #94 and #75 edit the same `QuotaHistoryStore` methods. PRF-06 consumes the projection. PRF-04 (store mutation safety).

### PRF-04 Store codecs and unlocked read-modify-write
- **Status / severity / effort / platform:** partial. #78 (MAIN-reported) quarantines undecodable snapshot and history files. Remaining: operation-local codecs and serialized mutation. Severity not rated; effort M (estimate); Linux-testable.
- **Sources:** MAIN F03; LEDGER #94 deferral; MAIN-reported #78.
- **Problem and evidence:**
  - `QC/QuotaHistoryStore.swift:3-17`, `QC/SnapshotStore.swift:3-13` and `QC/SettingsStore.swift:3-11` keep a `JSONEncoder` and `JSONDecoder` inside `@unchecked Sendable` classes.
  - `append` (`QC/QuotaHistoryStore.swift:55-74`) and `remove` (`:76-88`) are unlocked load-modify-save sequences, so a concurrent append and purge can lose one change. On Linux the daemon appends while `llimit accounts remove` purges from another process (TMP R-LNX-10).
  - At baseline an undecodable archive made `load` throw, so every later append failed. #94 deferred this case for the local archive ("quarantine + rebuild + surface"). #78 reports moving undecodable snapshot and history files to `<name>.corrupt`, with `reportPersistenceIssue` logging through os.Logger on Darwin and stderr on Linux. It likely covers #94's deferral; verify that appends resume on a fresh archive and that the failure is surfaced, not only logged. Quarantine does not establish settings recovery or serialized read-modify-write.
- **Proposal:** use operation-local codecs, or shared ones only with proven synchronization. Serialize logical mutations per file in-process, and coordinate cross-process writers with COR-02 (on Linux, a flock sidecar like `SettingsLock`). Reuse #78's quarantine rather than rebuilding it.
- **Tests / acceptance:** concurrent append and purge, truncation and schema mismatch, and replacement failure each preserve unrelated data and the corruption evidence.
- **Relations:** COR-02 / MAIN C05. TMP R-LNX-10 (perform the daemon's snapshot save and history append inside `settingsLock`). PRF-12 (decoder reuse must not reintroduce shared-codec races; LES-04). PRF-02, PRF-03. #94 (same store).

### PRF-05 HTTP transport bounds and retry policy
- **Status / severity / effort / platform:** partial. #77 (Anthropic `Retry-After` cooldown) and #65 (transport cancellation), both MAIN-reported. Remaining: session, size and retry bounds. Severity not rated; effort M to L (estimate); Linux-testable, but Darwin and swift-corelibs URLSession differ, so verify both.
- **Sources:** MAIN F05; MAIN-reported #77, #65.
- **Problem and evidence:**
  - `QC/HTTPClient.swift:14-34`: `URLSession.shared` (`:14`) keeps cookies and cache. `session.data(for:)` (`:24`) buffers the whole body with no size cap. The only limit is a 10 s `timeoutInterval` (`:20-21`), with no resource deadline. Every error collapses into `.network` with `localizedDescription` (`:29-34`), losing URL error codes. At baseline cancellation collapsed too; #65 now rethrows `CancellationError` and `URLError.cancelled`, and end-to-end cancellation stays with MAIN C10.
  - `QC/QuotaCoordinator.swift:39-60` starts one task per enabled account, with no concurrency or per-host bound.
  - #77 parses delta-seconds and IMF-fixdate `Retry-After`, capped at 24 h, into `ProviderClientError.retryAfter` and an additive Codable `ProviderFailure.retryAt` (old records decode nil). The coordinator skips accounts that are still cooling and carries the failure so `mergingStaleUsage` keeps the last-known usage. Only Anthropic uses it.
- **Proposal:**
  1. A dedicated ephemeral session with cookies and cache off, a resource deadline, a streaming body cap, host connection and concurrency bounds, and preserved URL error codes.
  2. Reuse #77's delta/date/24 h handling for the Copilot internal API and Kimi, and for GitHub's rate metadata once the headers are verified.
  3. Centralize the verified transient classes (408, 425, 429, provider-specific 403 (PRV-01), selected 5xx) with small jittered retries for read-only calls only.
  4. Never replay OAuth or other ambiguous token exchanges.
- **Tests / acceptance:** slow, oversized, 429, 5xx and many-account cases; carried failures; old Codable records still decode.
- **Relations:** PRF-11 (per-client budgets inside these bounds). PRF-01 (scheduler backoff). MAIN C10 (cancellation). TMP R-DEBT-02 (central status mapping, 408/425/429/503 to `.rateLimit` with `Retry-After`) and #65's `errorKind(forStatusCode:)`. PRV-01.

### PRF-06 Widget timelines and reloads spent on unchanged data
- **Status / severity / effort / platform:** open; low (TMP); S; macOS-only.
- **Sources:** TMP R-PERF-02 (APPMODEL-11, WIDGET-11; extends BACKLOG "Debounce actual settings writes", which already says to skip App Group writes when only credentials changed); MAIN F07.
- **Problem and evidence:**
  - Credential-only saves: cycles that adopt or rotate an OpenAI token or renew Claude save settings (`APP/AppModel.swift:640-671`, `:876-886`, `:1035-1054`). `saveConfiguration` (`:163-185`) rewrites the redacted App Group settings and reloads all 14 widget kinds, although the payload is byte-identical. A typical cycle reloads once. Reloads go through an 800 ms debounce (`:2019-2033`) but always use `reloadAllTimelines()`. `SharedConstants.allWidgetKinds` (`Shared/SharedConstants.swift:37-40`) is unused.
  - Each widget also schedules `.after(now + interval)` (`WX/QuotaTimelineProvider.swift:43-53`, `WX/ProviderQuotaWidget.swift:176-212`). That fires just before the app's push and re-reads unchanged files, and the trend widget decodes the whole history each time. At the default 30 minutes this is about 48 app reloads plus 48 policy reloads per day; the 96 + 96 figure was refuted (REF-18), and tile 5-minute entries are timeline entries, not reloads.
  - Trend entries carry raw history (`QuotaEntry.history`, `WX/QuotaTimelineProvider.swift:5-10`, `:55-68`) and build all arrays before the 240-point cap. Tiles emit an entry every 5 minutes up to the next refresh, plus reset dates: up to 37 entries for static states (`WX/ProviderQuotaWidget.swift:183-209`). Pass D reports footer countdown entries cloned across twelve tile kinds per reload. Value sharing means 37 entries do not prove 37 deep heap copies.
  - The dashboard timeline already uses one lightweight entry with `.after(nextRefreshDate)` (REF-01).
  - Unverified: whether this exhausts the macOS reload budget. Apple's 40-70 per day figure is iOS guidance, and app-requested reloads may be counted differently. WIDGET-11 partly argues against BACKLOG's `.after(nextRefreshDate)` guidance.
- **Proposal:**
  1. Hash the last written App Group snapshot and settings payloads; skip both the write and the reload on a match.
  2. Replace `reloadAllTimelines` with a debounced `reloadWidgetTimelines(kinds:)`: slot changes reload only the slot kinds, trend visibility changes reload `trendWidgetKind`, snapshot changes reload all kinds.
  3. Feed the trend widget the compact projection from PRF-03.
  4. Use one `.after` entry except at explicit changing-state, reset and stale boundaries (WID-02); do not just delete every dated entry. The sources differ on the fallback date: TMP makes the widget policy a staleness fallback at the later of `now + 2 x interval` and the next reset or stale boundary; MAIN keeps `.after(nextRefresh)`.
- **Tests / acceptance:** count actual reloads with the `scripts/widget-diagnostics.sh` log stream. An identical-payload save writes and reloads nothing; a slot change reloads only slot kinds. Measure archive size, render time, RSS and countdown behavior. Inspecting the timeline shows entries at reset and stale boundaries without extra provider calls.
- **Relations:** WID-02 (MAIN W09). PRF-02 (shared payload hash), PRF-03, PRF-07 (credential adoption causes the saves). Widget kinds stay frozen (AGENTS.md). #94 (App Group mirror) and #109 (trend widget) touch the same code.

### PRF-07 Every refresh runs a full credential scan on the main actor
- **Status / severity / effort / platform:** open; low (TMP: a few small files, and only when an imported OpenAI account is enabled); S; Linux-testable.
- **Sources:** TMP R-PERF-03 (AUTH-15, APPMODEL-14). TMP backlog note (R-PERF-03): extends BACKLOG "Discovery and import > Async, explicit scanning".
- **Problem and evidence:** `adoptLiveOpenAITokens` runs `CredentialDiscovery().discover()` across every provider and then filters to OpenAI (`APP/AppModel.swift:640-693`, scan at `:676`; `QC/CredentialDiscovery.swift:71-91`). Recovery repeats the scan per failed account (`APP/AppModel.swift:700-720` at `:719`, `:730-757` at `:747`), up to about 1 + 3N scans per cycle, on the main actor. The daemon has the same path (`LD/QuotaDaemon.swift:411`). Each scan loads unrelated secrets into memory.
- **Proposal:** add `CredentialDiscovery.discover(providers:)`; for OpenAI it runs only `scanCodex` and the `openai` entry of `scanOpenCode`. Run it once per refresh off the main actor, and reuse the result for the proactive and recovery paths in both the app and the daemon. Keep managed Codex accounts out of global-file adoption (AGENTS.md).
- **Tests / acceptance:** `discover(providers: [.openAI])` matches `discover()` filtered to OpenAI. A FileManager spy shows that no other provider's files are read. N failing accounts cause one scan per cycle.
- **Relations:** SEC-01 (same code path; unrelated secrets in memory). BKL-04 (TMP R-BKL-03: add this to "Async, explicit scanning"). #86 (MAIN-reported `env:` references must survive live-file adoption). AppModel.swift conflicts with #104 and #107.

### PRF-08 Interactive Keychain reads block the main actor
- **Status / severity / effort / platform:** open; low (TMP); M; macOS-only.
- **Sources:** TMP R-PERF-04 (GAPB-6; extends "Async, explicit scanning", where the interactive read after managed Claude sign-in is new).
- **Problem and evidence:** `SecItemCopyMatching` blocks until the user answers the Keychain dialog, and Apple warns against calling it on the main thread. Locations: `APP/AppModel.swift:501-527`, `:592-611` (no `kSecUseAuthenticationUI`), `:993-1005` (interactive read in `completeClaudeLogin`); `APP/Services/ClaudeProfileService.swift:112-124`; `APP/Views/SettingsView.swift:273-277` (Scan). While the dialog is up, Settings, the dropdown and the auto-refresh loop are frozen. Every new managed Claude connection, and any Scan that hits a protected item, hangs LLimit until the dialog is answered.
- **Proposal:** move interactive reads into a nonisolated helper and await it from AppModel. Show "Waiting for Keychain permission…" while the read is pending, and disable Scan and Auto-fill meanwhile. In `completeClaudeLogin`, re-check `claudeLoginProfiles[accountID] == profile` after the await. Background reads keep `kSecUseAuthenticationUIFail`.
- **Tests / acceptance (manual):** remove LLimit from the item's access list, click Scan, and confirm the dropdown still opens while the dialog is up.
- **Relations:** BKL-04. TMP R-UX-13 (an "Allow Keychain Access" action reads with `mode: .interactive` off the main actor through this helper).

### PRF-09 Repair App Group stores after transient failures
- **Status / severity / effort / platform:** open; severity not rated; M (estimate); macOS-only.
- **Sources:** MAIN F08; MAIN-reported #79; LEDGER #94.
- **Problem and evidence:** the settings and snapshot syncs try twice and then give up (`APP/AppModel.swift:1907-1950`), as does the App Group history append (`:1999-2018`); store resolution is cached and invalidated on failure (`:1952-1995`). The app then shows "Settings saved locally. Widget sync unavailable." (`:163-185`) or "Widget sync partially unavailable" (`:274-297`), and nothing retries until the next save or publish. A missed App Group history append is never replayed. #79 makes the App Group `SnapshotStore` convenience initializer failable with an NSLog breadcrumb instead of a force unwrap; it avoids the crash but does not repair publication. #94 makes the App Group history a byte mirror of the local archive and replaces an unreadable widget copy on the next publish (`ifUnreadable: .replace`), which may also cover a missed history append; verify.
- **Proposal:** at bootstrap, reconcile the redacted settings and the latest local snapshot (and history, if #94's mirror does not) into the App Group. After a failure, retry a bounded number of times, then reload the affected timelines once repaired. Expose the load failure while the store is unavailable (WID-03).
- **Tests / acceptance:** inject a transient failure; the widget copy recovers without another credential edit, and the widgets show a storage-unavailable state while it lasts.
- **Relations:** WID-03 (MAIN W03 explicit load outcomes; #109 deferred the "Store unavailable" empty state). PRF-02 (the persistence service owns the sync), PRF-06 (reload kinds). #79, #94.

### PRF-10 Dashboard view bodies recompute history and settings
- **Status / severity / effort / platform:** open; low (TMP); M; macOS-only, except the spark index builder, which is Linux-testable in QuotaCore.
- **Sources:** TMP R-PERF-06 (MENU-13); MAIN F04, F10.
- **Problem and evidence:**
  - `sparkPoints(for:)` (`APP/LLimitApp.swift:1427`, within `:1397-1440`) scans history linearly for every metric through `SparkSeriesBuilder` (`:412-446`, built at `:628`/`:633-668`). Hover, minute ticks and resize repeat this work, and both dashboards (dropdown and floating) build eager cards. Further locations: `:557-562`, `:663`, `:1343`, `:1398-1404`, `:1418-1423`.
  - `AppModel.primaryColorsByAccountID` (`APP/AppModel.swift:1462-1468`) builds `currentSettings()` and every account style on each access, across view bodies; see also `:1698-1710`.
  - Grip drags (`APP/LLimitApp.swift:1010`, `:1016-1034`) write `@AppStorage` (`:537-538`) on every pointer event, which re-renders both the dropdown and the floating dashboard.
  - Unverified: the verifier judged the per-hover cost to be microseconds, because `recentHistory` holds at most about 192 snapshots and a hover invalidates only one card. Only the pointer-rate rebuild during a resize drag likely matters. There is no measured stutter.
- **Proposal (cheap part first):**
  1. Keep the drag size in `@State` and write AppStorage in `onEnded`.
  2. Store `primaryColorsByAccountID` instead of computing it, memoized by account and style revision.
  3. Only if Instruments shows a cost with 10 accounts: precompute an immutable `[accountID: [metricID: [SparkPoint]]]` index in one QuotaCore pass when history changes (a `DashboardData` cache), and hoist lookups. Profile before switching to lazy cards.
- **Tests / acceptance:** rename, reorder, enable and style changes invalidate the right projection; unrelated hover or state changes do not rebuild settings or alter stable identity (`stableAccountOrder`). Hover and resize do not rebuild unchanged series, and moving windows stay correct.
- **Relations:** TMP R-IDEA-16 (scrub state lives in `ProviderQuotaCard`, `:1332`, so hovering does not recompute other cards). PRF-12 (`accountColorStep` sorting). LLimitApp.swift conflicts with #95, #96, #102, #103 and #106.

### PRF-11 Sequential provider calls and timeout budgets
- **Status / severity / effort / platform:** open; severity not rated; M (estimate); Linux-testable with fake HTTP clients, but timeout semantics need verification on both platforms.
- **Sources:** MAIN F12 (pass D report).
- **Problem and evidence:** Copilot's internal path tries the legacy token, then bearer, then a session-token exchange followed by another bearer call: up to four sequential round trips (`QC/Clients/CopilotClient.swift:139-160`). Cline calls profile, then balance, then usage-limits in sequence (`QC/Clients/ClineQuotaClient.swift:36-40`). One global 10 s `timeoutInterval` applies per request (`QC/HTTPClient.swift:14-21`); pass D reports that it covers the whole request on Linux but only idle time on Darwin. The roughly 40 s Copilot figure is inferred, not measured. Streaming Muse and chained Copilot need different budgets.
- **Proposal:** benchmark and verify on both platforms. Add per-client timeout budgets within PRF-05's resource bounds. After the profile call validates the key and yields the user id, run Cline's balance and usage-limits calls in parallel where safe. Keep Cline's rules from AGENTS.md: never guess the `usr-…` id, treat only 401/403/404 on usage-limits as "no windows", and fail the refresh on any other error. Preserve authentication prerequisites and failure semantics.
- **Tests / acceptance:** slow-stream, chain and cancellation fixtures verify the budgets, the response bounds and that no OAuth exchange is replayed. A parallel Cline fetch still fails on a balance error or on a non-401/403/404 usage-limits error.
- **Relations:** PRF-05, MAIN C10. #65 (Copilot error mapping) and #69 (Cline schema validation) touch the same clients.

### PRF-12 Formatter, decoder and sorting allocations
- **Status / severity / effort / platform:** partial. #65 (MAIN-reported) replaces the per-call numeric regex with a scan. Remaining: ISO8601 parsing, per-response decoders and `accountColorStep` sorting. Severity not rated; S (estimate); Linux-testable.
- **Sources:** MAIN F11 (pass D report).
- **Problem and evidence:** `parseISO8601` (`QC/Utilities.swift:148-175`) allocates two `ISO8601DateFormatter` instances per call (`:153`, `:168`). Eight clients (Cline, Copilot, Devin, Google Antigravity, Meta Muse, OpenAI, OpenCode Go, Venice) build a `JSONDecoder` per response. `accountColorStep` (`QC/ProviderMetricSelection.swift:194-204`) re-sorts all accounts through `stableAccountOrder` (`:175-187`) on every call.
- **Proposal:** profile first. Use the value-type `ISO8601FormatStyle` or operation-local instances, never an unsynchronized shared static formatter, because corelibs formatters need synchronization (LES-04). Hoist the stable-account sort out of per-account calls. Reuse a decoder per client only with proven synchronization under parallel same-provider accounts; otherwise keep operation-local codecs (PRF-04).
- **Tests / acceptance:** timestamp and number parsing are equivalent before and after, including Kimi's nine-digit fractions. Concurrent clients work. Color identity is unchanged after reorder and disable.
- **Relations:** PRF-04, PRF-10, LES-04.

## macOS usability, visuals and accessibility

This section covers the dropdown, Settings, the floating dashboard, the menu-bar
item and in-app accessibility. Widget rendering and chart integrity are in their
own section. Items marked hypothesis come from MAIN's native layout review and were
not reproduced; verify them on a Mac before changing lifecycle code. Line
references are baseline `2d6ac1e` starting points. "Source check" marks a location
re-read in the baseline tree while merging; everything else is as the sources
report it. Native rendering, VoiceOver and Accessibility Inspector runs were not
performed for any item here.

### MAC-01 Per-account refresh and account management actions

- **Status / severity / effort / platform:** open. TMP rates it medium; MAIN does
  not rate it. Effort M (TMP). macOS UI; partly Linux-testable (a credential-free
  usage-summary formatter in QuotaCore).
- **Sources:** TMP R-UX-07 (MENU-9, SETTINGS-8, SETTINGS-19); MAIN AM-PROD-2
  (Product, "Fast management").
- **Problem and evidence:**
  - Locations: `APP/LLimitApp.swift:1417-1423,1624-1654`;
    `APP/Views/SettingsView.swift:6-16,64-99,997-1010`;
    `APP/AppModel.swift:217-220,315-347,368,559-579,907-927,1603-1612`.
  - Dropdown cards brighten like buttons on hover but have no action and no
    context menu.
  - The only refresh polls every provider, and Anthropic hard-rate-limits repeat
    pollers.
  - Import, Auto-fill and credential edits never fetch the account. Re-enabling an
    account shows "No data" until the next cycle.
  - Source check: `APP/AppModel.swift:368` sets "Credentials need renewal. Refresh
    this account." for an action that does not exist.
  - The sidebar context menu offers only Move Up and Move Down. There is no
    Enable/Disable, no Remove, no Delete key handling and no Cmd-N.
  - Never fetching new accounts also causes MAC-03's false "All accounts
    reporting".
  - MAIN's broader proposal: search, filters and groups when the account count
    needs them, targeted refresh, snooze, reversible removal with confirmation or
    Undo, and explicit visibility. Stable ids, styles and history must survive, and
    cleanup, credential provenance and expiry consequences must be clear.
- **Proposal:**
  1. Generalize the existing Claude and Codex single-account paths into
     `AppModel.refreshAccount(_ id:)`: wait for the current cycle, fetch one
     configuration, merge, save and publish. Do not bump `generatedAt` (TMP
     R-BUG-27). Views call it through AppModel, not through clients.
  2. Call it after import, Auto-fill, a committed credential edit, and re-enable.
  3. Relabel the account-page button "Refresh This Account" (the BACKLOG
     alternative is to label the global one "Refresh All Accounts").
  4. Add a card `.contextMenu`: Refresh This Account; Open in Settings… (lift the
     selection into a published `settingsFocusAccountID`); Copy Usage Summary (a
     credential-free QuotaCore formatter that StatusRenderer can share; copy
     failure text only after COR-06's redaction boundary lands); Disable Account.
  5. Sidebar: Enable/Disable, Refresh, Remove… with confirmation,
     `.onDeleteCommand`, and a Cmd-N command that selects Add Account.
  6. Later, from MAIN: search, filters, groups, snooze, reversible removal with
     Undo, explicit visibility. Disable, remove and undo must not change
     `stableAccountOrder`, color variants or automatic tile assignments (AGENTS.md
     color semantics).
- **Tests / acceptance:** the summary formatter on Linux (no credentials, same
  output as StatusRenderer's projection). Manual checks of both menus. After
  import, Auto-fill, a committed edit or re-enable, the account shows data without
  waiting for the cycle. A single-account refresh leaves `generatedAt` and other
  accounts' history untouched. Ids, styles and history survive disable, enable and
  an undone removal.
- **Relations:** MAC-03, MAC-05 (announce results), MAC-15 (blocked actions),
  MAC-22 (copy). TMP R-UX-02 (notices) and R-BUG-27 (single-account freshness).
  #75 excludes failed, carried and sibling observations from history; a targeted
  refresh must not reintroduce them. MAIN W14 (per-account age, targeted sibling
  refresh fixture). #101's PendingEdits commit is the "committed credential edit"
  hook. #102 changed Refresh controls during sign-in and deferred TMP R-BUG-22
  (ticks dropped during single-account refreshes). Expected conflicts:
  `AppModel.swift` (#94, #101, #102, #104, #106, #107), `SettingsView.swift`
  (#101, #102, #106). BACKLOG "Onboarding and account operations" (targeted
  refresh) and "Actionable account state" (deep links).

### MAC-02 Add Account saves an enabled empty account before sign-in

- **Status / severity / effort / platform:** open. Medium (TMP). Effort M.
  macOS-only (manual tests).
- **Sources:** TMP R-UX-08 (SETTINGS-7).
- **Problem and evidence:**
  - Locations: `APP/Views/SettingsView.swift:228-235`;
    `APP/AppModel.swift:385-403,857-874,993-1003`; `QC/Models.swift:1452-1466`;
    `WX/ProviderQuotaWidget.swift:236-245`.
  - The account is saved with empty credentials, and only then is sign-in
    launched.
  - Canceling or failing a Claude or OpenAI connect leaves "Claude 2" or "OpenAI
    2", enabled. It takes an automatic tile slot, shifts color variants and shows
    red in the sidebar.
  - `APP/AppModel.swift:869` says "Your previous connection is unchanged" even for
    a new account.
  - There is no way to add a Claude or OpenAI account with a pasted token without
    aborting a sign-in first.
- **Proposal:**
  - Track `pendingNewAccountIDs`. If a connect for such an account is canceled or
    fails before any credential exists, remove the account and return to Add
    Account with "Sign-in canceled. No account was added."
  - Show a Discard button on manual accounts that have no credentials and no data.
  - Add an "Add with a token instead" link.
  - AGENTS.md constraint: discarding must not delete a Codex namespace that still
    has a pending operation record or a running child; defer that profile's
    cleanup instead.
- **Tests / acceptance:** manual: cancel the Claude and the Codex sign-in from Add
  Account; no account remains, tile assignments and other accounts' color variants
  are unchanged, and the new-account cancel copy no longer mentions a previous
  connection.
- **Relations:** part of PRD-05 (guided first account). MAC-01, MAC-05 (announce
  the cancel), MAC-33 (sheet sizes). TMP R-UX-01 (positional color identity).

### MAC-03 Empty state and a false "All accounts reporting"

- **Status / severity / effort / platform:** open. MAIN does not rate it; effort
  not estimated in the sources. The coverage derivation is Linux-testable if it
  lives in QuotaCore; the views are macOS-only.
- **Sources:** MAIN M01.
- **Problem and evidence:**
  - MAIN cites `APP/LLimitApp.swift:621-622,733-843`.
  - Source check: the empty state (`:779-843`) says "No quota data yet. Refresh
    now to fetch your current limits." and its button calls `model.refreshNow()`.
    With no enabled account that has complete credentials, the refresh exits
    early and its message ("No enabled provider accounts with complete
    credentials") appears only on Settings > Overview (TMP R-UX-02), so the click
    does nothing visible.
  - Source check: the header (`:735-739`) shows a green checkmark labeled "All
    accounts reporting" whenever `snapshot.failures` is empty. An old failure-free
    snapshot therefore claims coverage of accounts added since and never queried
    (they are not fetched, MAC-01).
- **Proposal:** derive per-account coverage, readiness and freshness (absent,
  disabled, incomplete credentials, new and unqueried, stale, busy) in one pure
  function. Claim "all reporting" only when every enabled account has a fresh
  result. When nothing is configured, offer a first-account action instead of
  Refresh. Add scoped recovery notices. No silent no-op.
- **Tests / acceptance:** fixtures for absent, disabled, incomplete, new, stale and
  busy accounts. None produces a false all-reporting state or a silent no-op.
- **Relations:** MAC-01, MAC-05, PRD-05. TMP R-UX-02 (notices). MAIN W14 and #80:
  #80's header stale badge at 2x the interval is aggregate, not per-account age.
  #72 made the dashboard widget's no-account and awaiting states truthful (widget
  side only). #96 adds failure and stale cues to the status item. MAIN "Honesty
  mode": count only fresh covered accounts in health claims.

### MAC-04 VoiceOver semantics in the app and widgets

- **Status / severity / effort / platform:** open. TMP rates it low; MAIN does not
  rate it. Effort S for TMP's part; the full spoken-summary work is larger.
  Linux-testable: reset components, spoken failure kind, countdown formatter.
  Native VoiceOver verification is macOS-only.
- **Sources:** MAIN M02, W07; TMP R-A11Y-06 (MENU-15, WIDGET-17).
- **Problem and evidence:**
  - Settings controls with empty semantic labels at baseline:
    `APP/Views/SettingsView.swift:361-377,494-507,582-593,890-950,1121-1150`.
    #56 reports explicit hidden-control labels, described account-status dots and
    a textual "Refreshing"; tile, color-target and menu quota-summary gaps remain.
  - The menu graph exposes only "LLimit" (`APP/LLimitApp.swift:169-171`; source
    check: `.accessibilityLabel("LLimit")`).
  - Countdowns are spoken as "4d 6h 56m" (`APP/LLimitApp.swift:361-365,512-528,1584`;
    `QC/Utilities.swift:12-23`).
  - The card ring announces "28 percent remaining" without naming the limit. #67
    reports accessible gauge context for the limiting metric; check what remains.
  - Tiles read `failure.kind.rawValue` ("rateLimit", "notConfigured")
    (`WX/ProviderQuotaWidget.swift:641-653,677-702`; `QC/Models.swift:247-255`).
  - The trend label is only "Quota trend chart." and omits the warning shown on
    screen (`WX/LLimitQuotaWidget.swift:130-144`).
  - Hiding percentages loses the dashboard's numeric semantics, and literal `INF`
    and `--` are read (`WX/LLimitQuotaWidget.swift:207-235,520-534,1050-1065`).
    #80 reports dashboard rows speaking unlimited/unknown, and AUTO/ESTIMATED
    badges reportedly carry explicit VoiceOver labels (8 pt, 0.85 opacity). Neither
    closes this item.
  - Unverified: exact VoiceOver pronunciation.
- **Proposal:**
  - Build one presentation-independent `spokenDescription` (account, named metric,
    value, reset, freshness, failure) shared by the dropdown, tiles, dashboard and
    trend. Hide decoration.
  - Add `UsageMetric.resetComponents(at:)` and a full-unit `DateComponentsFormatter`
    (at most 2 units): "Resets in 4 days, 6 hours".
  - Add `QuotaErrorKind.spokenDescription` ("rate limited", "sign-in needed").
  - Name the constrained metric on the ring: "Lowest: 5-hour limit, 28 percent
    remaining".
  - Append trend warnings to the trend label.
  - Keep numeric semantics when percentages are hidden; name unknown and unlimited.
  - Give the status item a quota summary label instead of "LLimit".
  - Extend #56 (Settings), #80 (dashboard speech) and #67 (gauge context) rather
    than redo them.
- **Tests / acceptance:** reset components at 0, 59 s, 1 h, multi-day and past;
  the spoken-kind mapping (Linux). Native AX/VoiceOver traversal shows distinct
  roles, names and values without navigating surrounding text.
- **Relations:** MAC-08 (one state enum feeds AX), MAC-21 ("1 account issues"),
  MAC-24 (hidden percentages). MAIN M12 (localized Unlimited/Unknown; DEBT-03).
  TMP R-IDEA-16 (sparkline audio graphs). #96 feeds failure counts into the
  status-item tooltip; check whether it also replaces the "LLimit" label.
  BACKLOG "Widgets > Widget accessibility contract" and "Platform polish
  (locale-aware durations)".

### MAC-05 VoiceOver never announces outcomes

- **Status / severity / effort / platform:** open. Medium (TMP; its verifier said
  low to medium). Effort M. macOS-only.
- **Sources:** TMP R-A11Y-05 (GAPB-1).
- **Problem and evidence:**
  - Locations: `APP/AppModel.swift:292-296,796-797,811,833-838`;
    `APP/Views/SettingsView.swift:181-185`; `APP/Views/CodexLoginView.swift:21-22`;
    `APP/Views/ClaudeTerminalView.swift:36-39,54-61` (corrected lines);
    `APP/LLimitApp.swift:716-722`.
  - No announcement API is used anywhere. Refresh, sign-in and removal outcomes
    only change on-screen text.
  - A successful Codex sign-in silently dismisses the sheet.
- **Proposal:**
  - Add `AppModel.announce(_:)` using `AccessibilityNotification.Announcement`
    (macOS 14).
  - Announce only user-started outcomes: manual refresh results ("Refreshed 3
    accounts, 1 failed"), connect success, failure and cancel, removal, and save
    failures. Never automatic cycles.
  - In the login sheets, announce from `.onChange` of the status message.
  - Keep messages short and credential-free.
- **Tests / acceptance:** a manual VoiceOver checklist added to `scripts/tests`.
- **Relations:** TMP R-UX-02 (announce from the same notice it publishes). MAC-01,
  MAC-02, MAC-21 (pluralized phrases). COR-06 (no failure bodies in speech).

### MAC-06 Dropdown text contrast and Increase Contrast

- **Status / severity / effort / platform:** open. Medium (TMP). Effort S.
  macOS-only.
- **Sources:** TMP R-A11Y-03 (MENU-8, THEME-8); MAIN M05.
- **Problem and evidence:**
  - `APP/LLimitApp.swift:241-253` (`:248` sectionTitle white 0.48, `:250`
    tertiaryText white 0.42); MAIN cites `:242-250,521-525,1561-1577`. Tertiary
    uses: `:525` (ResetChip), `:1203`, `:1323`, `:1564`, `:1577`, `:1642`.
  - TMP measured tertiary text at 3.77:1 at the top of a card, 4.0:1 at the
    bottom and 3.61:1 on a hovered card, and section titles at 4.46:1. MAIN
    calculated a nominal 3.77-4.02:1. Both are calculations, not captured pixels.
  - That tone carries 9 to 10 pt text: reset countdowns, usage lines, stat labels
    and the failure provider line. Reset times fail WCAG AA for small text.
  - `colorSchemeContrast` is never read.
  - The measurements assume the forced-dark dashboard (`:601`
    `.colorScheme(.dark)`), which #73 removes (MAC-16).
- **Proposal:**
  - Raise tertiary to 0.56 (5.5:1 on cards, 5.2:1 on hover) and section titles to
    0.58.
  - Add `DashboardPalette.resolved(contrast:)`. Under `.increased`: secondary
    0.80, tertiary 0.72, card stroke white 0.28, hairlines 0.22, no glow shadows.
  - Target 4.5:1 for small text while keeping the metric hues. Check that the
    orange "reset due" and the red value text still pass on a hovered card.
- **Tests / acceptance:** Accessibility Inspector contrast audit in both contrast
  modes. Capture actual normal, hover, bright and high-contrast pixels before
  claiming native ratios, in dark and (after #73) light appearance.
- **Relations:** MAC-11 (preset contrast), MAC-16, MAC-29 (glow shadows). MAIN W08
  (widget text on light backgrounds). #109 (trend chip legibility, R-A11Y-02).
  TMP R-VIS-13 (light titlebar over forced-dark content) is overtaken by #73.

### MAC-07 Reduce Motion is ignored by bars and jump-scroll

- **Status / severity / effort / platform:** open. Low (TMP). Effort S.
  macOS-only.
- **Sources:** TMP R-A11Y-07 (MENU-16, THEME-12); MAIN M06.
- **Problem and evidence:**
  - Rings are gated correctly (`APP/LLimitApp.swift:307-339`; source check:
    `accessibilityReduceMotion` is read at `:307` and `:1333`).
  - The GlossBar spring (`:398`) runs on every refresh, and the jump-to-card scroll
    spring (`:644-647`) animates, both regardless of the setting (`:1290-1304`,
    `:1418`). #103 deferred the GlossBar spring as pre-existing.
  - "Jump to card" moves only the scroll position; VoiceOver focus stays on the
    gauge.
  - #82's `repeatForever` near-reset glow needs the same gate.
- **Proposal:**
  - Gate both animations through a `DashboardMotion.spring(reduce:)` helper so
    later effects (#82's glow, the reset celebration) inherit the gate. Geometry
    and scroll changes become immediate under Reduce Motion; ordinary animation
    stays otherwise.
  - Add `@AccessibilityFocusState` and set it after scrolling.
- **Tests / acceptance:** manual run with VoiceOver and Reduce Motion both on:
  bars and scroll change without animation, the glow does not pulse, and focus
  lands on the target card.
- **Relations:** #103, #82, MAC-27 (same ring drawing). TMP R-IDEA-16 (scrub
  returns instantly under Reduce Motion). MAIN "Observed reset receipt".

### MAC-08 Account status indicators rely on color and contradict each other

- **Status / severity / effort / platform:** open. Low (TMP R-UX-19); MAIN does not
  rate it. Effort S. Rendering is macOS-only; the state enum is Linux-testable if
  it lives in QuotaCore.
- **Sources:** MAIN M11; TMP R-UX-19 (SETTINGS-13). TMP backlog note (R-UX-19):
  extends BACKLOG "Actionable account state" (model the disabled state; color is
  not the only signal).
- **Problem and evidence:**
  - Locations: `APP/AppModel.swift:369-380`;
    `APP/Views/SettingsView.swift:898-922,1068-1088,1169-1177,1216-1218`.
  - One disabled account shows "Disabled" with a green dot, "Account disabled"
    with a red dot, and a gray sidebar dot.
  - The status row "Credentials" sits directly above the editor row
    "Credentials".
  - Sidebar dots, provider dots and summary controls use color as the only state
    channel. Incoming main grouped identity rings and menu bars with them; those
    are identity, not status.
- **Proposal:**
  - Use one state enum (LES-03) with ok, neutral and problem states, each carrying
    a symbol (check, warning, exclamation), text and an AX equivalent. Honor
    Differentiate Without Color.
  - Show disabled as neutral, with "Not refreshed while disabled".
  - Rename the status rows "Connection" and "Usage data".
  - Extend #56's described status dots.
  - Identity rings and menu bars stay identity (BND-06); reserved accents carry
    danger.
- **Tests / acceptance:** each state renders symbol, text and AX label; a disabled
  account shows one consistent neutral state in every row and the sidebar; state
  stays readable with Differentiate Without Color.
- **Relations:** #56, MAC-04, MAC-25 (TMP R-UX-26 also moves status to shaped
  symbols), MAC-03.

### MAC-09 Background color and alpha contract

- **Status / severity / effort / platform:** open. Medium (TMP). Effort S for the
  wells (TMP); the parser consolidation is larger. TMP marks it not
  Linux-testable; a contract placed in QuotaCore would be.
- **Sources:** TMP R-BUG-25 (THEME-17); MAIN M04, W11. TMP backlog note (R-BUG-25): extends BACKLOG "Appearance model cleanup" (nil overloading; the five-parser consolidation).
- **Problem and evidence:**
  - Default background wells show a clear swatch: `color(fromHex: nil)` returns
    `.clear` (`APP/AppModel.swift:1814-1817`, `:1832-1834`;
    `APP/Views/SettingsView.swift:590-595`), while widgets render #5994F2 or
    provider gradients. Opening a well seeds the panel at 0% opacity.
  - Zero alpha serializes as nil and restores an automatic opaque background
    (`APP/AppModel.swift:1350-1356,1832-1842`). Picks at alpha 0.01 or below become
    nil and are silently ignored. Unverified: whether the color wheel keeps 0%
    after a pick.
  - `#RRGGBB33` renders 72% opaque on the dashboard and trend widgets
    (`WX/LLimitQuotaWidget.swift:1092-1096`; source check: `max(0.72, alpha)` at
    `:1095`) but 20% on tiles (`WX/ProviderQuotaWidget.swift:887-893`, raw
    alpha). The shared parser keeps RGBA (`Shared/LimitKindColorScheme.swift:161-165`).
  - Source check, the parsers to consolidate: `normalizeHexColor`
    (`QC/Models.swift:1086`), `rgbaComponents` (`Shared/LimitKindColorScheme.swift:135`
    and `APP/AppModel.swift:1848`), `Color(providerTileHex:)`
    (`WX/ProviderQuotaWidget.swift:871`), `backgroundBaseColor`
    (`WX/LLimitQuotaWidget.swift:1068`), `AppModel.parseHexColor`
    (`APP/AppModel.swift:1867`).
- **Proposal:**
  - Write one tested component and background contract that consolidates those
    parsers. Do not add another parser.
  - Represent transparency explicitly; nil means automatic.
  - Well getters resolve nil to the color actually rendered: #5994F2 for global
    and dashboard, the provider's top palette color for an account (expose the
    palette through Shared). Always use alpha 1 for nil.
  - Choose one alpha policy for both widget families; any intentional effect (such
    as the 0.72 floor) applies after the shared parse.
- **Tests / acceptance:** zero, partial and full alpha survive reload for global,
  widget and account controls; automatic and clear swatches differ; transparent,
  quarter, half and full alpha match across tile, dashboard and trend before
  intentional effects. Manual: from Default, pick a color and confirm the tile,
  dashboard and trend all change.
- **Relations:** MAC-10, MAC-11, MAC-16, MAC-20. MAIN W08. #85 debounces color
  drags on the same bindings. #53.

### MAC-10 Account style override starts from a hidden stale copy

- **Status / severity / effort / platform:** open. Medium (TMP). Effort M.
  Linux-testable (`effectiveTileStyle` in QuotaCore).
- **Sources:** TMP R-BUG-24 (SETTINGS-5).
- **Problem and evidence:**
  - Locations: `APP/AppModel.swift:394-399,571-575` (seeding), `:1334-1348`
    (override toggle), `:1521-1547` (unused `effectiveStyle`);
    `QC/Models.swift:1132-1138,1605`; `WX/ProviderQuotaWidget.swift:328-340`.
  - New and imported accounts store a copy of the global style at creation. The
    override toggle only flips `useCustomStyle`, so enabling it later shows a stale
    background (for example Ocean), and the picker labels it.
  - With the override on and Default selected, a nil background resolves to the
    global hex, so the provider palette is unreachable while the global style has
    a background.
- **Proposal:**
  - When the override is switched on, seed it from the current global style and
    keep `primaryHexColor`.
  - While `useCustomStyle` is true, nil means the provider palette, matching the
    global Default.
  - Migrate stored overrides with a nil background to the global hex at decode
    time, so existing tiles render unchanged.
  - Move the duplicated logic into `AppSettings.effectiveTileStyle(for:)` in
    QuotaCore and delete `AppModel.effectiveStyle`.
- **Tests / acceptance (Linux):** both scenarios; legacy decode keeps today's
  rendering.
- **Relations:** MAC-19 (legacy fallback), MAC-09, MAC-11, PRD-14 (live preview,
  reset to global). BACKLOG "Appearance model cleanup" ("Stop overloading nil",
  "Reset to Global"); MAC-09 extends the same section.

### MAC-11 Style presets carry unrendered ring palettes and weak contrast

- **Status / severity / effort / platform:** open. Medium (TMP). Effort M.
  Linux-testable (preset table in QuotaCore).
- **Sources:** TMP R-THM-01 (SETTINGS-6, THEME-4); MAIN M07, M05 (Crazy Banana).
  TMP backlog note (R-THM-01): extends BACKLOG "Appearance model cleanup (remove
  or consolidate ring/reset helpers)".
- **Problem and evidence:**
  - Locations: `APP/WidgetStylePreset.swift:3-342` (24 presets, 21 with
    `rings(...)`; `id(for:)` at `:299-305`, MAIN cites `:299-317`);
    `APP/AppModel.swift:1316-1332` (`:1324-1325` stale "menu bar status colors"
    comment), `:1521-1536`; `APP/Views/SettingsView.swift:560-578` (`:572`
    caption). Ring colors are only copied at `WX/LLimitQuotaWidget.swift:1226` and
    `WX/ProviderQuotaWidget.swift:336`.
  - Ring colors are never drawn (AGENTS.md), so presets differ only by
    background. "Neon Pulse" and "Cyberpunk" promise themes that never appear. The
    dead ring data is about 200 lines (not the 300 first estimated).
  - `id(for:)` still compares ring colors, so a legacy `ringPalette` style shows as
    Custom.
  - The caption "Adjust any color below and the style becomes Custom" is wrong for
    the Limit colors. The picker has no swatches.
  - Tile text is hard-coded white. White-text contrast: Crazy Banana #D9B21B 2.03
    (MAIN: about 2.03:1, `WidgetStylePreset.swift:169-183`), Default #5994F2 3.02,
    Glacier 4.03, Desert Bloom 4.18, Mint Pop 4.25, Sunset 4.31. On Crazy Banana,
    the monthly, Other A and daily rings measure 1.02 to 1.04:1.
- **Proposal:**
  - Make presets background-only (`ringColors: .default`) and match on rendered
    properties; `id(for:)` ignores ring colors. All preset backgrounds are
    distinct, so nothing collides. Current/Custom follows the actual appearance.
  - Rename presets after their surface, or merge near-duplicates.
  - Darken or retire backgrounds below 4.5:1 for white text, and add "Dashboard
    Graphite" (#1D1F27). Default #5994F2 is one of the two surfaces the palette is
    validated against (AGENTS.md), so changing it requires re-running the
    validator; luminance-aware tile chrome (MAIN W08) is the alternative.
  - Fix the AppModel comment and the caption ("Presets set the widget background.
    Picking a background color or transparency switches to Custom. Limit colors
    are kept.").
  - Add swatches, show the affected longest window and a real tile preview, and
    offer a one-action reset to global.
  - Move the preset table into QuotaCore.
- **Tests / acceptance:** every preset is distinct and passes white text at 4.5:1
  or better; a legacy `ringPalette` style matches its preset.
- **Relations:** PRD-14 (live preview), MAC-06, MAC-09, MAC-10. #53's limit
  palettes are separate from these background presets. TMP R-THM-02 (identity hues
  on widget surfaces).

### MAC-12 Color pickers accept colliding colors

- **Status / severity / effort / platform:** open. Medium (TMP). Effort M.
  Linux-testable.
- **Sources:** TMP R-UX-12 (SETTINGS-18, THEME-16).
- **Problem and evidence:**
  - Locations: `APP/Views/SettingsView.swift:641-682,926-943`;
    `APP/AppModel.swift:1425-1460,1470-1492`; `QC/Models.swift:925-946`;
    `Shared/LimitKindColorScheme.swift:56-64`.
  - Any color is accepted. Setting Weekly to the Session hue makes the two rings
    and lines identical.
  - A custom primary color can equal another account's automatic hue, or sit near
    the reserved danger red.
  - "Reset to defaults" replaces all seven colors with no confirmation or undo.
  - #53's palettes enlarge the space to check.
- **Proposal:**
  - Add a pure QuotaCore `ColorDistance.deltaE2000` and `conflicts(...)` checking:
    the six kind hues against each other and the unlimited tint; each account's
    resolved primary color; the reserved warning and danger accents (move those
    constants into QuotaCore); contrast against #1D1F27.
  - Show an inline caption ("Very close to Work's weekly color", "Close to the
    warning color"). Warn only: AGENTS.md requires custom colors to render exactly
    as chosen.
  - Keep the previous palette after Reset and offer a one-step Undo.
- **Tests / acceptance:** ΔE reference pairs; the validated defaults and #53's
  palettes report no conflicts; an identical pair reports one; three-account
  conflict detection.
- **Relations:** #53, MAC-20, MAC-25. TMP R-THM-03 (pale variant validation and a
  Linux-runnable validator). MAIN W04.

### MAC-13 Dashboard order and colors cannot be matched to the menu-bar bars

- **Status / severity / effort / platform:** open; a product decision. Medium
  (TMP). Effort S. Linux-testable (projection parity).
- **Sources:** TMP R-UX-04 (MENU-4).
- **Problem and evidence:**
  - Locations: `APP/LLimitApp.swift:192-197,220-226,636-668,889-900,1226-1231`;
    `QC/AccountDisplayOrder.swift:29-48`.
  - Since d08e460 the status-item bars follow the Settings order and wear each
    account's primary (longest window) color.
  - The dashboard sorts by lowest remaining and tints gauges by the most
    constrained metric, so bar N matches its gauge in neither position nor color,
    and cards reshuffle on every refresh.
- **Proposal:**
  - Build the dashboard with `orderedUsageForAccounts(...)`, the function the icon
    uses, and append standalone failures in account order. Urgency stays visible
    through the LOWEST stat.
  - Optionally add a persisted "Sort Cards by Lowest Remaining" toggle that
    affects cards only.
  - Color will still differ for multi-window accounts, because gauges show the
    most constrained window and gauge tints stay unchanged (AGENTS.md). #67 made
    the gauge and caption identify the same limiting metric.
- **Tests / acceptance:** dashboard and icon projections agree, including legacy
  provider-keyed usage and disabled accounts.
- **Relations:** #96 deferred this item, plus sharing level, stale and
  failure-matching rules between MenuBarGraph, the dashboard's
  `MenuBarQuotaStyling` and the provider tile. #67. IDEA-18 (split bars make hue
  and height describe one limit). #59 (overview trophy). MAC-35.

### MAC-14 Settings drops estimate qualifiers and valid amounts

- **Status / severity / effort / platform:** open. MAIN does not rate it; effort
  not estimated. Linux-testable if the shared presentation lives in QuotaCore.
- **Sources:** MAIN M03.
- **Problem and evidence:** `APP/Views/SettingsView.swift:730-740,1294-1307` print
  `--` for valid amounts and drop the "estimated" qualifier.
- **Proposal:** one shared presentation for reported percentage, estimated
  percentage, amount, unlimited and unknown, used by Settings and the other
  surfaces. Never invent balance percentages (AGENTS.md: Venice USD and bundled
  credits and Cline's credit balance are amounts only; estimated Venice DIEM
  percentages are labeled).
- **Tests / acceptance:** estimated Venice, `$4.25`, unlimited and absent values
  render with the right qualifier and no fabricated percentage.
- **Relations:** #83 (`StatusRenderer.accountQuotaSummary` with estimate marker and
  balance), #72 (distinct unknown/unlimited/zero in the dashboard widget), #93
  (amount-only `extra_usage` metric), MAIN M12 (localized Unlimited/Unknown),
  MAC-04.

### MAC-15 Disabled account actions give no reason

- **Status / severity / effort / platform:** partial: #102 explains disabled
  Refresh controls. Remaining: Connect, Reconnect and Remove. Low (TMP). Effort S.
  macOS-only.
- **Sources:** TMP R-UX-18 (SETTINGS-12); LEDGER #102.
- **Problem and evidence:**
  - Locations: `APP/Views/SettingsView.swift:235,778-782,814-818,1010-1016`;
    `APP/AppModel.swift:937-942,1122`.
  - Connect, Reconnect and Remove are disabled during refreshes (up to 45 s) or
    renewals, with no `.help` or caption.
  - Verifier correction: with a hidden login terminal open, Connect becomes "Open
    Login Terminal" and stays enabled; only Remove is blocked.
  - Unverified: tooltips on disabled buttons on macOS 14 (#102 left this open).
- **Proposal:** add `accountActionBlocker(for:)` (`refreshing`, `renewalRunning`,
  `loginTerminalOpen`, `connecting`) with fixed copy. Show it as `.help` and as a
  caption under the Actions row, so the reason is visible even if disabled-button
  tooltips do not appear. Follow #102's Refresh pattern.
- **Tests / acceptance:** manual: each blocker shows its reason on all three
  buttons; check tooltip behavior on macOS 14.
- **Relations:** #102, MAC-01. TMP R-BUG-22 (#102 deferral).

### MAC-16 Validate a light-surface palette

- **Status / severity / effort / platform:** open. MAIN does not rate it; effort
  not estimated. macOS-only.
- **Sources:** MAIN M09.
- **Problem and evidence:** #73 lets the floating dashboard follow the system
  appearance after removing forced dark mode (baseline `APP/LLimitApp.swift:601`),
  but no light graphite palette has been validated. System appearance alone does
  not validate one. AGENTS.md's validated palette covers only the graphite
  (#1D1F27) and widget blue (#5994F2) surfaces. TMP R-VIS-13 found the baseline
  NSPanel never set `appearance` (`:100-122,593-601`), giving a light titlebar
  over dark content (unverified visually).
- **Proposal:** validate text, hairlines, tracks, status accents and transparency
  on actual light and dark surfaces; run the dataviz palette validator against the
  light surface before calling it validated. Keep window identity separate from
  provider branding. Apply MAC-06's targets in both appearances.
- **Tests / acceptance:** captures in Light, Dark, Increase Contrast and Reduce
  Transparency; validator output for the light surface.
- **Relations:** #73, MAC-06, MAC-29, MAC-35. MAIN W08.

### MAC-17 The primary color picker has no effect without a limit window

- **Status / severity / effort / platform:** open. Low (TMP). Effort S.
  Linux-testable.
- **Sources:** TMP R-BUG-44 (SETTINGS-9).
- **Problem and evidence:**
  - Locations: `APP/Views/SettingsView.swift:926-943`;
    `APP/AppModel.swift:1470-1510`; `QC/ProviderMetricSelection.swift:87-100`;
    `Shared/LimitKindColorScheme.swift:12-18`;
    `QC/Clients/ClineQuotaClient.swift:106-114`.
  - Credit-only Cline and balance-only Venice accounts have no primary slot, so a
    picked color renders nowhere.
  - The swatch falls back to `defaultPrimaryKind`, a color that appears nowhere for
    these accounts. Settings already calls `primaryLimitSlot`; only the fallback is
    wrong.
- **Proposal:** when usage exists and the slot is nil, disable the picker and
  explain: "This account reports no limit window, so it has no primary color".
- **Tests / acceptance:** credit-only and balance-only fixtures give a nil slot and
  a disabled picker.
- **Relations:** MAC-18. TMP R-BUG-34: the "empty" placeholder currently becomes a
  primary slot and paints #B8A8FF; once excluded, placeholder-only accounts take
  this path too. #93's amount-only `extra_usage` metric must not become a primary
  slot.

### MAC-18 defaultPrimaryKind lacks OpenCode Go

- **Status / severity / effort / platform:** open. Low (TMP). Effort S.
  Linux-testable once moved.
- **Sources:** TMP R-BUG-35 (CORE-9).
- **Problem and evidence:**
  - Locations: `APP/AppModel.swift:1500-1510`; `QC/ProviderMetricSelection.swift:87-100`;
    `Packages/QuotaCore/Tests/QuotaCoreTests/ProviderMetricSelectionTests.swift:74-81`.
  - `defaultPrimaryKind` falls through `default: .weekly`, but OpenCode Go's
    longest window is monthly, so the Settings color preview shows the weekly color
    until usage arrives and flips on load.
  - AGENTS.md says the `default:` case needs an explicit case in exactly this
    situation. The function lives in the app target, where no Linux test reaches
    it, so future providers can repeat the mistake unnoticed.
- **Proposal:** move it to `ProviderMetricSelection.swift` as `public func
  defaultPrimaryWindowKind(for:)`, an exhaustive switch with no `default`, with
  `.openCodeGo: .monthly`. Update the AGENTS.md list of exhaustive switches.
- **Tests / acceptance:** for every provider, fixture metrics give
  `primaryLimitSlot(...).kind == defaultPrimaryWindowKind(for:)`, with Antigravity
  as `.other`.
- **Relations:** MAC-17. TMP R-BUG-07 and R-VIS-02 edit the same file.

### MAC-19 Legacy style fallback gives two same-provider accounts one color

- **Status / severity / effort / platform:** open. MAIN does not rate it (a pass-D
  report); effort not estimated. Linux-testable.
- **Sources:** MAIN M13.
- **Problem and evidence:**
  - Pass D reports that the provider-keyed legacy style fallback in
    `QC/Models.swift` reuses one entry for two same-provider accounts and
    permanently saves an identical inherited `primaryHexColor` and style. Tiles are
    the trend legend, so the siblings become indistinguishable.
  - Source check: `normalizedProviderStyleSettings` (`QC/Models.swift:1584-1606`)
    picks `values.first(where:)` by provider raw value or provider at `:1594`, and
    keeps `primaryHexColor` when the entry is provider-keyed (`:1597-1599`). Every
    sibling without its own entry matches that same entry.
- **Proposal:** consume a legacy match only once (the first deterministic match),
  or clear only duplicate inherited primaries beyond it. Explicit account
  overrides stay authoritative. Migration only: never recolor existing deliberate
  custom matches.
- **Tests / acceptance:** fixtures for two siblings with one legacy entry, multiple
  entries, and save/reload. Automatic variants stay distinguishable, explicit
  overrides stay authoritative, and ids, backgrounds and history survive.
- **Relations:** MAC-10, MAC-12. TMP R-UX-01 (account color identity). MAIN W04.

### MAC-20 LimitKindColors writes bypass normalization

- **Status / severity / effort / platform:** open. MAIN does not rate it; effort
  not estimated (small). Linux-testable.
- **Sources:** MAIN M08.
- **Problem and evidence:** source check: `LimitKindColors`
  (`QC/Models.swift:872-900`) exposes `public var sessionHexColor` through
  `otherHexColors`; only the initializer runs `normalizeHexColor` (`:895-900`).
  Direct assignments skip it. #53 only canonicalizes a copy in `matching`.
- **Proposal:** make writes canonical with the existing normalizer
  (`QC/Models.swift:1086`); consider setters before widening visibility. Keep the
  legacy matching behavior and the validated palette.
- **Tests / acceptance:** lowercase, short and invalid assignments; uppercase
  canonical output; encode/decode round trips.
- **Relations:** #53, MAC-09, MAC-12.

### MAC-21 Count strings are not pluralized

- **Status / severity / effort / platform:** partial: #95 fixes the dropdown
  dashboard strings. Remaining: widget, AppModel and Linux daemon phrases. Low
  (TMP). Effort S. Linux-testable.
- **Sources:** TMP R-UX-24 (GAPB-8); LEDGER #95.
- **Problem and evidence:**
  - TMP's examples: "1 METRICS", "1 accounts" and "1 account issues"
    (VoiceOver). Source check: "1 METRICS" (`APP/LLimitApp.swift:1200`) and "1
    account issues" (`:753`) are in the dropdown, which is #95's part. The cluster
    summary's attribution of "1 METRICS" to the widget does not match the baseline.
  - Remaining, source check: `WX/LLimitQuotaWidget.swift:416` ("N accounts, lowest
    N% left") and `:419` ("N accounts tracked"); `APP/AppModel.swift:293-295` and
    `LD/QuotaDaemon.swift:326` ("Refreshed N account(s), N failure(s)"). The "(s)"
    forms were a deliberate hedge.
- **Proposal:** inflected `Text("^[\(count) account](inflect: true)")` in the
  widget, and a QuotaCore `countPhrase(_:singular:plural:)` for the plain strings
  shared with Linux.
- **Tests / acceptance:** "Refreshed 1 account, 0 failures" and "Refreshed 2
  accounts, 1 failure"; the widget renders "1 account".
- **Relations:** #95. DEBT-03 (localization). MAC-05 reuses the phrases.

### MAC-22 Failure and warning text is truncated with no tooltip

- **Status / severity / effort / platform:** open. Low (TMP). Effort S.
  macOS-only.
- **Sources:** TMP R-UX-15 (MENU-17).
- **Problem and evidence:** `APP/LLimitApp.swift:1408-1414,1453-1462,1574-1582,1643-1646`.
  Status lines use `lineLimit(2)` and failure messages `lineLimit(3)`, with no
  `.help`, while metric details in the same view do have `.help`.
- **Proposal:** add `.help(text)` now. Allow copying only once COR-06's redaction
  boundary lands; until then offer to copy only the failure kind and HTTP status.
- **Tests / acceptance:** manual: hovering a truncated status or failure shows the
  full text.
- **Relations:** COR-06. #70 and #63 (failure redaction and excerpts). MAC-01
  (Copy Usage Summary). BACKLOG "Actionable account state (sanitized copyable
  diagnostics)".

### MAC-23 Widget options are split across three Settings pages

- **Status / severity / effort / platform:** open. Low (TMP). Effort S.
  macOS-only, view-only.
- **Sources:** TMP R-UX-20 (SETTINGS-15).
- **Problem and evidence:** `APP/Views/SettingsView.swift:382-446` (the "Visible
  information" cards: All Widgets, Dashboard Widgets, Trend Widget), `:472-512`,
  `:582-637`.
- **Proposal:** move the "Visible information" cards onto the Widgets page as
  Provider Tiles, Dashboard and Trend sections, with a pointer from Appearance.
  The settings model is unchanged. Do it together with MAC-24 so each toggle sits
  under the surfaces it actually affects.
- **Tests / acceptance:** manual: every widget option is on the Widgets page and
  Appearance links to it.
- **Relations:** MAC-24, MAC-32.

### MAC-24 Widget visibility settings that do nothing

- **Status / severity / effort / platform:** open. MAIN does not rate it; effort
  not estimated. Round-trip compatibility is Linux-testable.
- **Sources:** MAIN M10, AM-LESSON-3.
- **Problem and evidence:**
  - `WidgetVisibilitySettings.showResetInfo` (`QC/Models.swift:1247`) is persisted
    but unused. Source check: it appears only in coding (`:1266,1279,1298,1315,1335`)
    and round-trip tests; Settings has no toggle for it. #80 reports removing the
    dead `resetSummaries`/`dashboardBarPercents` helpers; the field remains.
  - `showPercentageValues` applies only to the dashboard; tiles ignore it. Source
    check: the toggle reads "Show percentages in widgets" under "All Widgets"
    (`APP/Views/SettingsView.swift:384-389`), and the only consumers are
    `WX/LLimitQuotaWidget.swift:367,449`. Do not assert tile support.
- **Proposal:** for each field, clarify the label, deliberately extend the scope,
  or retire it while keeping round-trip compatibility. Verify the remaining
  consumers after #80 rather than repeat its cleanup. Keep the current reset
  presentation. Hidden percentages keep numeric AX semantics (MAC-04).
- **Tests / acceptance:** old settings files round-trip; each visibility label
  matches the surfaces it changes.
- **Relations:** MAC-23, #80, MAC-04 (MAIN W07).

### MAC-25 Settings lists lack account color swatches

- **Status / severity / effort / platform:** open. Low (TMP). Effort S.
  macOS-only.
- **Sources:** TMP R-UX-26 (THEME-15).
- **Problem and evidence:**
  - Locations: `APP/Views/SettingsView.swift:101-123,464-467,488-510,641-682,1169-1177`.
  - Sidebar dots, slot pickers and trend toggles show status colors or nothing,
    never the identity color. The Limit colors pickers show only the base hue, not
    the deep and pale variants.
  - Partly overstated (REF-16): each account page's Primary color picker already
    shows the resolved identity color, and the dropdown rows also act as a legend,
    so tiles are not the only one.
- **Proposal:** add a 10 pt `AccountColorSwatch` to sidebar rows, slot pickers and
  trend toggles; move status to shaped symbols (MAC-08); show a three-chip strip
  (base, deep, pale) next to each kind picker.
- **Tests / acceptance:** manual: each list row shows the same color the account's
  tile and trend line wear.
- **Relations:** MAC-08 (the status-shape part duplicates BACKLOG "Do not use
  status color as the only state channel"), MAC-12, #53. TMP R-UX-01.

### MAC-26 The card header ring repeats the only row

- **Status / severity / effort / platform:** open; a design suggestion. Low (TMP).
  Effort S. macOS-only.
- **Sources:** TMP R-UX-25 (THEME-21).
- **Problem and evidence:** `APP/LLimitApp.swift:1206-1251,1384-1392`. On
  single-metric cards the 46 pt ring repeats the value below it; Claude's 28%
  appears four times on one screen.
- **Proposal:** show the header ring only when the card has two or more bounded
  metrics, and use the freed space for the name or the reset chip.
- **Tests / acceptance:** manual screenshots of single- and multi-metric cards.
- **Relations:** check against #67 (gauge and caption name the limiting metric)
  and #95 (R-VIS-08 ring inset; TMP suggested a 40 pt card ring). MAC-04.

### MAC-27 Ring gradient seam at 12 o'clock

- **Status / severity / effort / platform:** open. Low (TMP). Effort S.
  macOS-only.
- **Sources:** TMP R-VIS-09 (THEME-13).
- **Problem and evidence:** `APP/LLimitApp.swift:326-338`;
  `WX/ProviderQuotaWidget.swift:760-773`. The `AngularGradient` runs from dim to
  full tint and is rotated -90°. Near 100%, and always for unlimited metrics, the
  brightest end meets the dimmest at the top. Visible on the Z.ai tile.
- **Proposal:** extract a shared `ringStyle(progress:tint:)` into `Shared/`. Draw a
  solid tint at progress 0.97 or more; otherwise start the gradient at 0.65
  opacity.
- **Tests / acceptance:** offscreen renders at 96%, 99%, 100% and unlimited show
  no seam.
- **Relations:** #82 and the Reset Celebration glow touch the same rings; MAC-07.
  TMP R-IDEA-12 (recent-bite marks on the same ring drawing).

### MAC-28 Sparklines misalign, clip their end dot, and extend stale values

- **Status / severity / effort / platform:** open. Low (TMP). Effort S.
  macOS-only.
- **Sources:** TMP R-VIS-10 (MENU-11).
- **Problem and evidence:**
  - Locations: `APP/LLimitApp.swift:470-473,503-506,1427-1441,1529-1553`.
  - The 88 pt sparkline sits directly before a variable-width value, so each row's
    sparkline starts at a different x.
  - The x axis has no inset, so the 4 pt end dot at `now` is half clipped.
  - Failed accounts draw flat lines up to now, mostly from carried history points
    (BND-08).
- **Proposal:** give the value text a fixed trailing column
  (`.frame(minWidth: 64, alignment: .trailing)`); inset x by 2.5 pt; append the
  live point at `usage.fetchedAt` and skip it when older than the last history
  point.
- **Tests / acceptance:** manual screenshots of mixed rows and of a LAST KNOWN
  card.
- **Relations:** BND-08. #75 reports that charts use source fetch time and exclude
  carried observations, and the baseline appended a point at now (MAIN C02);
  check what remains after it. TMP R-IDEA-16 (scrubbable sparklines). BACKLOG
  "Widgets > Trend chart (pad plot edges)" and "Fresh, stale" (append only fresh
  observations).

### MAC-29 The card shadow is cast by the text, not the card

- **Status / severity / effort / platform:** open. Low (TMP; subtle on graphite).
  Effort S. macOS-only.
- **Sources:** TMP R-VIS-12 (MENU-14).
- **Problem and evidence:** `APP/LLimitApp.swift:244,257-283` (`:281`),
  `:1417-1418`. The 28% shadow applies to the whole card. The fill is 5.5% white,
  so the body casts almost nothing while every glyph casts the full shadow. Every
  card's contents are also composited during hover animation and scrolling.
- **Proposal:** move the shadow onto the background shape, with an opaque graphite
  base under the translucent tint, or drop the shadow and rely on the rim
  (PRD-15).
- **Tests / acceptance:** before and after screenshots at 2x, in both appearances
  once #73 lands.
- **Relations:** PRD-15, MAC-06 (no glow shadows under Increase Contrast), MAC-16.

### MAC-30 Dropdown resizing: keyboard path, reset, and grip geometry

- **Status / severity / effort / platform:** open; the geometry checks are a
  hypothesis. Low (TMP). Effort S. macOS-only.
- **Sources:** TMP R-A11Y-08 (MENU-19); MAIN AM-MAC-NL-5.
- **Problem and evidence:**
  - `APP/LLimitApp.swift:537-538,855-878,961-1014` (`:1013`
    `accessibilityHidden`). The 10 pt grips are hidden from accessibility and are
    the only way to resize. Nothing restores `MenuBarPanelWidth`/`Height`.
  - MAIN hypothesis, not reproduced: verify both grips, frame and content
    geometry, remembered-size clamping, display changes, and wide overview density
    with few accounts.
- **Proposal:** add a "Dropdown Size" submenu with Compact, Default, Tall and Reset
  Size. Optionally add `.accessibilityAdjustableAction` on the grips, stepping by
  40 pt. Snap detents with haptics were rejected (REF-27).
- **Tests / acceptance:** manual: every size is reachable by keyboard and VoiceOver
  and Reset restores the default; the hypothesis checks above pass or produce a
  reproduced defect.
- **Relations:** MAC-31 (same geometry file). #95 deferred a Mac visual check at
  360 and 420 pt. #48 introduced the resizable dropdown.

### MAC-31 Detached dashboard placement and canceled-detach state

- **Status / severity / effort / platform:** open; the canceled-detach part is a
  hypothesis. Low (TMP). Effort S. The geometry test runs in the `scripts/tests`
  swiftc harness, which TMP marks not Linux-testable.
- **Sources:** TMP R-BUG-45 (MENU-18); MAIN AM-MAC-NL-4.
- **Problem and evidence:**
  - `APP/LLimitApp.swift:148-160,757-772,1148-1166`. The 430 pt panel is centered
    on the pointer, and `constrainFrameRect(_:to:)` keeps only the top edge on
    screen, so a detach near the right edge leaves part of it off-screen.
  - MAIN hypothesis, not reproduced: a canceled detach may leave `hasDetached` or
    `suppressOpen` set (`APP/LLimitApp.swift:1129-1165`). Source check: both are
    `@State` (`:1130-1131`) and are cleared only in the drag gesture's `onEnded`
    (`:1160-1165`).
- **Proposal:** add a pure `MenuBarPanelSize.detachedFrame(size:pointer:visibleFrame:)`
  in `MenuBarPanelGeometry.swift` that clamps to `visibleFrame` inset by
  `screenMargin` on all sides. For the detach state: cancel a detach, close and
  reopen, then detach again; change the code only if the button gets stuck.
- **Tests / acceptance:** MenuBarPanelGeometryTests with a pointer at the right
  edge, the left edge, near the bottom, and a panel taller than the screen.
- **Relations:** MAC-30. #92 deferred running `scripts/test-panel-geometry.sh` in
  the Linux job. #106 (global hotkey toggles the dashboard). #73.

### MAC-32 Settings fixed widths and nested rows

- **Status / severity / effort / platform:** open; hypothesis, not reproduced.
  Unrated. macOS-only.
- **Sources:** MAIN AM-MAC-NL-1.
- **Problem and evidence:** fixed 180 pt labels, split-view minimums and nested
  Appearance rows (`APP/Views/SettingsView.swift:20-36,997-1017,1090-1099`).
  Source check: the Settings window opens at 960x680 with a 720x480 minimum
  (`APP/LLimitApp.swift:62-63`). Source widths do not prove clipping.
- **Proposal:** render at 720x480 with long or localized names and larger text.
  Stack only the rows that fail, using adaptive Grid, Form or `ViewThatFits`.
- **Tests / acceptance:** at 720x480 with long names and larger text, nothing
  clips and every action stays reachable.
- **Relations:** MAC-23, MAC-33, DEBT-03.

### MAC-33 Sign-in sheet sizes

- **Status / severity / effort / platform:** open; hypothesis, not reproduced.
  Unrated. macOS-only.
- **Sources:** MAIN AM-MAC-NL-2.
- **Problem and evidence:** source check: the Claude terminal sheet requires
  `minWidth: 820, minHeight: 550` (`APP/Views/ClaudeTerminalView.swift:50`), larger
  than the Settings minimum of 720x480; the Codex sheet is fixed at 520 wide
  (`APP/Views/CodexLoginView.swift:44`).
- **Proposal:** verify fit, focus and reachable actions on the visible display,
  including Settings at its minimum size and small screens; change sizing only
  where a sheet fails.
- **Tests / acceptance:** both sheets fit the visible display, take focus, and
  every action is reachable.
- **Relations:** MAC-02, MAC-05, MAC-32.

### MAC-34 Settings window autosaves its frame, then centers

- **Status / severity / effort / platform:** open; hypothesis, not reproduced.
  Unrated. macOS-only.
- **Sources:** MAIN AM-MAC-NL-3; BKL-09's remaining items (TMP R-BKL-08,
  BACKLOG.md:388).
- **Problem and evidence:**
  - Source check: `APP/LLimitApp.swift:64-65` calls
    `setFrameAutosaveName("LLimitSettingsWindow")` and then `center()`, which may
    override the restored frame. The floating panel (`:117-120`) centers only when
    `setFrameUsingName` finds no saved frame.
  - From BKL-09: the `WindowAccessor` comment (`APP/Views/SettingsView.swift:1311-1312`)
    refers to the removed SwiftUI Settings scene, and the window title is "LLimit"
    (`APP/LLimitApp.swift:58`), not "LLimit Settings". The deminiaturize part of
    BACKLOG.md:388 was done in d08e460.
- **Proposal:** verify restore, hide, minimize, reopen and display removal before
  changing lifecycle code. If centering overrides restore, center only when no
  saved frame exists, as the floating panel does. Fix the comment and the title,
  and narrow BACKLOG.md:388 to what remains.
- **Tests / acceptance:** a moved Settings window reopens where it was, and lands
  on screen after its display is removed.
- **Relations:** MAC-31 (floating panel lifecycle), MAC-32.

### MAC-35 Menu-bar icon width and contrast on light bars

- **Status / severity / effort / platform:** open; hypothesis, not reproduced.
  Unrated. macOS-only.
- **Sources:** MAIN AM-MAC-NL-6.
- **Problem and evidence:** the icon width is `count * 3 + (count - 1) * 1.5`
  (source check: `APP/LLimitApp.swift:175-185`), about 52.5 pt for twelve
  accounts; the older 50-70 pt estimate is not a native layout measurement. The
  image is not a template, so pale bars may wash out on light menu bars.
- **Proposal:** re-test after #96 (bar track and danger cue) and #53 (palettes)
  with the notch and display variations, Increase Contrast and Reduce Transparency,
  before claiming crowding or poor contrast. Display modes (most-constrained
  single bar, gauge, monochrome template, split bars) belong to IDEA-18.
- **Tests / acceptance:** captures with 1, 6 and 12 accounts on light and dark
  menu bars, with and without the notch and both accessibility settings.
- **Relations:** #96 (deferred a manual Mac check of tooltip and light/dark bars,
  and re-applying the tooltip on display changes), #53, IDEA-18, MAC-13, MAC-16.
  TMP R-THM-03 (the pale variant falls below the chroma floor).

## Widgets, trend chart, color identity and freshness

This section covers the WidgetKit tiles, the dashboard and trend widgets, and the cross-surface color identity, freshness and danger rules they render. Frozen widget kinds and app-owned slot assignments apply to every entry (BND-07): no widget-side configuration or `AppIntentConfiguration`, literal kind strings, and plain `configurationDisplayName` text. Ring, bar and trace colors stay limit-window and account identity, and danger uses reserved accents only (BND-06). The dashboard truth work in #72, #54 and #80 is in the ledger; entries below cover only what remains. Line references are baseline `2d6ac1e`. All widget behavior here was checked from source only, not on installed widgets (WID-21).

### WID-01 Tiles and dashboard show a fixed window pair and can hide the exhausted one
- **Status / severity / effort / platform:** open; medium (TMP, next tier, not shortlisted); S; the selection rule is Linux-testable in QuotaCore, widget rendering is macOS-only.
- **Sources:** TMP R-BUG-07 (GAPA-2). It follows on from the done BACKLOG.md:483-484 dual-limit item (TMP R-BKL-07).
- **Problem and evidence:**
  - `QC/ProviderMetricSelection.swift:3-51` (`defaultRingMetrics`) takes the first two present ids from a fixed per-provider preference list. Only metrics with a percentage or explicitly unlimited are candidates (`:4`). Pairs: OpenCode Go `session-rolling` + `monthly` (weekly is third in the list), Cline `five_hour` + `weekly`, Anthropic `five_hour` + `seven_day`.
  - Tile rings (`WX/ProviderQuotaWidget.swift:424-437`), dashboard bars and the dual-percent text (`WX/LLimitQuotaWidget.swift:495-528`, `:658-693`) use that pair. Dashboard sorting and the "lowest X% left" summary (`WX/LLimitQuotaWidget.swift:397-418`), the menu bar and Linux `status` use the minimum over all metrics.
  - Example: an OpenCode Go account whose weekly window is rate-limited sorts first and drives "lowest 0% left", but its row and tile read "55% / 70%", and the dashboard row shows no warning. Widgets show a blocked account as healthy and disagree with the menu bar and the Linux bar.
  - The tile's reset timeline entries (`WX/ProviderQuotaWidget.swift:189-195`) and its stale check (`:610-622`) also look only at the pair, so a hidden window's reset gets no entry.
  - This matters more now: #81 renders OpenCode Go `rate-limited` windows as exhausted at any reported percent, and #93 adds Sonnet and other model-specific weekly windows to Anthropic.
  - `Packages/QuotaCore/Tests/QuotaCoreTests/ProviderMetricSelectionTests.swift:74-85` pins OpenCode Go rolling + monthly.
- **Proposal:**
  - Keep the provider's first preferred metric. For the second slot, substitute the most constrained other bounded metric when its `remainingPercent` is lower than the preferred second's. Ties keep the preference.
  - Never substitute an unlimited metric or one without a percentage. Amount-only metrics such as #93's `extra_usage` are already excluded by the candidate filter.
  - `defaultRingMetrics` is one of the six exhaustive switches in AGENTS.md. Keep the per-provider `switch` exhaustive and apply the substitution after it.
  - Identity colors are unaffected, because `limitSeriesSlots` and `primaryLimitSlot` run over the full metric list. This deliberately changes the "shortest and longest" design, so update the pinned test and the dual-text wording (BKL-08).
  - Consider sharing the "actual limiting metric" choice with #67's dropdown bottleneck caption (MAIN-reported), so every surface names the same window.
- **Tests / acceptance:** OpenCode Go with weekly at 0% gives `[session-rolling, weekly]`. Cline with monthly at 0% gives `[five_hour, monthly]`. An Anthropic account with an exhausted Sonnet weekly window shows that window. Healthy accounts keep today's pairs, and ties keep the preference. Unlimited and nil-percentage metrics are never substituted. The dashboard row, the summary and the tile name the same limiting window.
- **Relations:** BKL-08 (dual-text labeling). WID-02 (reset entries follow the selected pair). WID-04 (severity is only meaningful if the limiting window is visible). #81, #93, and #103 (draws pace ticks on these tile rings). MAIN-reported #67.

### WID-02 Widgets keep pre-reset values after a reset
- **Status / severity / effort / platform:** open; medium (TMP); M; the reset-pending helper is Linux-testable, timelines and rendering are macOS-only.
- **Sources:** TMP R-BUG-21 (WIDGET-10; extends BACKLOG "Fresh, stale, failed, and unknown state"); MAIN W09.
- **Problem and evidence:**
  - Refreshes run on a fixed 15 to 180 minute interval that is not aligned to resets (`APP/AppModel.swift:1763-1786`).
  - Tile: the timeline (`WX/ProviderQuotaWidget.swift:176-211`) adds an entry every 5 minutes up to `nextRefresh = now + interval`, plus one at each ring metric's `resetAt` inside the interval (`:189-195`). At that entry `isStale` turns true (`:610-622`), so the tile shows "now" and an orange "!" but keeps the old, often near-empty ring (`:677-681`, `:778-781`).
  - Dashboard: a single entry with `.after(nextRefresh)` (`WX/QuotaTimelineProvider.swift:43-53`), so it keeps the stale percentage with no marker (`WX/LLimitQuotaWidget.swift:495-533`).
  - A window that just reset reads, say, "3% left" for up to a full interval, exactly when the user is waiting for quota to return.
  - Stale boundary (W09): the tile's stale threshold is `fetchedAt + max(1 h, 2 x interval)` (`:620-622`), but its last entry is at `now + interval`. If macOS delivers the requested reload late, the last entry keeps saying "Data is current" (accessibility text, `:671`) with a frozen countdown (`:671-679`). How often macOS delays reloads is unmeasured.
- **Proposal:**
  - Add `UsageMetric.isResetPending(at:)` in QuotaCore and a display helper that returns `.resetPending` instead of a percentage once `resetAt` has passed and no fresh fetch has confirmed the refill.
  - Tile: a dashed or indeterminate track and a "reset" footer instead of the old ring. Dashboard: "reset" text and a neutral bar.
  - Add explicit timeline entries at the earliest `resetAt` inside the interval (the dashboard has none today) and at the stale threshold, even beyond the requested reload. A delayed reload then still turns stale, with an honest cached age.
  - The AppModel wake at the earliest `resetAt` plus 60 s, bounded by each provider's minimum poll interval, belongs to the scheduler (PRF-01 step 7).
  - Never show a refill based on the clock alone (BND-08). A passed reset stays "reset due" until a fresh fetch observes replenishment. Reuse #105's wording for carried metrics past their reset (R-BUG-08: "Window reset since the last successful refresh").
  - Balance this against PRF-06's entry budget (tiles emit up to about 37 entries per interval today): add only boundary entries, not more periodic ones. Timelines must be inspectable without extra provider calls.
- **Tests / acceptance:** the helper at, before and after `resetAt` (Linux). Timeline builders contain the reset and stale-boundary entries. An entry past the stale threshold renders stale without a reload. Delayed native delivery is verified on an installed widget.
- **Relations:** Reset Celebration work on the same tile rings: the in-flight `feat/reset-celebration` branch (commit `4768e74`) and MAIN-reported #82 (a near-reset glow is anticipation, not verified replenishment). TMP R-IDEA-06 reports, unverified, that `4768e74` glows whenever `abs(resetAt - entry.date) < 300 s`, which also lights stale data that never reset, and adds a `repeatForever` animation that widgets never run. #103 draws pace ticks on the same rings. PRF-01 (scheduler; #102 deferred R-BUG-22). PRF-06 (its fallback `.after` policy pairs with these boundary entries). WID-05 (age). #105 deferred recording the refresh interval in the snapshot (Linux stale threshold).

### WID-03 Tile and trend load outcomes
- **Status / severity / effort / platform:** partial. #109 gives the trend widget distinct empty-state reasons, and #72 (MAIN-owned) covers the dashboard. Remaining: tile load outcomes and the trend "store unavailable" state. Severity unrated in MAIN W03; TMP R-UX-22 is low. Effort S-M (estimate). Outcome resolution is Linux-testable if it moves to QuotaCore; the views are macOS-only.
- **Sources:** MAIN W03; TMP R-UX-22 (WIDGET-16); LEDGER #109 deferral; related TMP R-DEBT-01. TMP backlog note (R-UX-22): extends BACKLOG "Existing dashboard widgets (distinct entry states)".
- **Problem and evidence:**
  - Tiles load settings and the snapshot with `try?` and fall back to `AppSettings.default` and nil (`WX/ProviderQuotaWidget.swift:288-304`). A missing or unreadable App Group, settings file or snapshot therefore renders "No accounts yet / Add an account in LLimit to fill this tile" (`:557-568`). That advice invites a duplicate account.
  - The trend provider `print()`s the error and falls back to `.default` settings or a nil snapshot (`WX/QuotaTimelineProvider.swift:71-91`). At baseline every cause, including zero accounts, an unavailable App Group and amount-only accounts (Cline credits, Venice USD), showed "No history yet / Waiting for automatic refresh" (`WX/LLimitQuotaWidget.swift:118-128`, `:757-763`; `QC/ProviderMetricSelection.swift:163-165`). #109 adds the reasons but deferred `.storeUnavailable`, so a `SharedPaths` or settings failure still lands on a misleading reason.
  - `print()` output is discarded for WidgetKit extensions, so these failures never reach the unified log (DEBT-01).
  - MAIN-reported #79 only makes the App Group `SnapshotStore` init failable, with an NSLog breadcrumb.
- **Proposal:**
  - Resolve one explicit outcome per tile and trend entry: no accounts, awaiting data, all failed, stale, or storage/App Group unavailable. Keep settings, snapshot and history failures distinct.
  - Return `.storeUnavailable` when `SharedPaths` or the settings store throws.
  - Storage-failure copy points to opening LLimit, which republishes the App Group copy. It never suggests adding an account.
  - Replace the tiles' silent `try?` with do/catch, logged once per timeline (DEBT-01).
- **Tests / acceptance:** inject absent, corrupt and inaccessible container, settings, snapshot and history states. Each yields its own outcome, and none yields a false "No accounts yet" or "No accounts configured". One test per trend reason, including `.storeUnavailable`.
- **Relations:** #72, and #54/#80 (dashboard states; check whether they also change the trend widget). #109. #79. #94 (self-repairing App Group copy) and #78 (quarantine to `.corrupt`), which change which failures reach the widget. DEBT-01. PRF-09 (repair after transient App Group failures). WID-17 (the "awaiting account" tile state). WID-18.

### WID-04 One danger severity across surfaces, shown on widgets
- **Status / severity / effort / platform:** open; medium (TMP; the R-UX-09 verifier said low to medium); S-M; `QuotaSeverity` and StatusRenderer are Linux-testable, widget accents are macOS-only. A product decision comes first.
- **Sources:** TMP R-UX-09 (THEME-5), R-UX-10 (THEME-6); MAIN "Reliable notices" (earlier 30%/15%); LEDGER #110 and #96 deferral; MAIN-reported #100.
- **Problem and evidence:**
  - macOS: `MetricQuotaRow.valueColor` is orange at 25% or less and red at 10% or less, per metric (`APP/LLimitApp.swift:1601-1607`).
  - Linux: warning below 40 and critical below 15, on the aggregate minimum (`LD/StatusRenderer.swift:167-175`, documented in `Packages/LLimitd/examples/README.md:29-37`). The same account at 30% is "warning" on Linux and plain on macOS.
  - In flight: #110 fires events at 20% and 5%. #100 adds user-set warning and critical thresholds in Settings > General. MAIN's notice proposal used 30%/15%. The trend widget's 60% check was a projection precondition, not a severity.
  - Widgets never show the reserved accent. Tiles show no percentage, and their single orange "!" covers only stale data and provider warnings (`WX/ProviderQuotaWidget.swift:423-477`, badge at `:446`, `:571-589`). Dashboard percent text uses the default color at every value (`WX/LLimitQuotaWidget.swift:520-531`). A Claude tile at 2% differs from one at 40% only by arc length, so the primary surface gives no alarm before a limit runs out.
- **Proposal:**
  1. Decide the thresholds once: 25/10, 40/15, 20/5, 30/15, or #100's user-set values with one shared default.
  2. Add `QuotaSeverity { normal, warning, critical }` with `init(remainingPercent:)` and named constants in QuotaCore. Nil, unknown and stale data never cross a band.
  3. Use it in StatusRenderer (keep the JSON `class` strings; update the examples README if the Linux numbers move), `MetricQuotaRow.valueColor`, #110's `QuotaEvents`, #100's `QuotaAlertEvaluator` and the widgets.
  4. Tiles: color the limiting metric's footer countdown orange or red, and add a "3% left" capsule in the existing badge style. Dashboard: color the percent like `MetricQuotaRow`. Add the severity to the accessibility summary ("critically low").
  5. Ring, bar and trace hues stay identity colors. Severity uses the reserved accents only (BND-06).
- **Tests / acceptance:** `QuotaSeverity` boundaries at 9, 10, 14, 15, 39, 40 and nil. StatusRenderer `class` at the same values. Offscreen tile and dashboard renders at 50%, 20%, 5% and 0%.
- **Relations:** #110 vs #100 (two alert engines with two threshold sets). #96 deferred sharing the level, stale and failure-matching rules between MenuBarGraph, the dashboard's `MenuBarQuotaStyling` and the provider tile. MAIN M11 (state shown by color alone; Differentiate Without Color). WID-01. #97 and #108 `check` take per-invocation thresholds and do not need this.

### WID-05 Per-account freshness and age
- **Status / severity / effort / platform:** partial. #95 unifies the dropdown header and card age clocks and copy (TMP R-UX-03), and #80 (MAIN-reported) adds an aggregate widget stale badge. Remaining: per-account age on widgets and an "oldest N min ago" header note. Medium (TMP R-UX-03); S-M; `oldestFetchedAt` and the age rules are Linux-testable, widget rendering is macOS-only.
- **Sources:** TMP R-UX-03 (MENU-2); MAIN W14; LEDGER #95 deferral. TMP backlog note (R-UX-03): extends BACKLOG "Fresh, stale, failed, and unknown state".
- **Problem and evidence:**
  - Dashboard widget headers show `snapshot.generatedAt` (`WX/LLimitQuotaWidget.swift:351`, `:433`). A fresh aggregate attempt can still carry an old `ProviderUsage.fetchedAt` for a failing account, and a single-account refresh bumps `generatedAt` for everyone (COR-08). The header can therefore imply that every account just succeeded.
  - Tiles check staleness per account (`WX/ProviderQuotaWidget.swift:610-622`), but show it only as the orange "!" shared with provider warnings (`:446`) and as "Data is stale/current" in the accessibility text (`:671`). No age is shown.
  - #80's orange-clock header badge appears at 2x the refresh interval even with the clock setting off. It is aggregate, not per-account.
  - #95 deferred the optional "oldest N min ago" header note in the dropdown.
- **Proposal:**
  - Derive row age and health from each account's source `fetchedAt` and its current failure, with the same rules as LNX-01 (last attempt, last success, current failure, stale age). Do not invent a second freshness model.
  - Add `QuotaSnapshot.oldestFetchedAt` over the displayed usages and use it for header copy such as "Updated 2 min ago · oldest 35 min ago", in the dropdown and the dashboard widget. Leave `generatedAt` unchanged; bootstrap and widgets depend on it.
  - Dashboard rows: a compact age marker on stale or failing rows. Tiles: the age in the footer when stale.
  - Reuse the shared age formatter from #95's R-UX-03 work, `QuotaDisplayText.relativeAge` (#95 moves it out of `StatusRenderer`; verify that it lives in QuotaCore). Ages are English-only by design (#95).
- **Tests / acceptance:** `oldestFetchedAt` with carried usage. Fixtures for mixed fresh and stale accounts, a targeted sibling refresh, a cached failure, and hidden clock or percentages. No aggregate timestamp implies that every account succeeded.
- **Relations:** COR-08, REF-06, LNX-01. #105 (Linux per-account `fetchedAt`/`ageSeconds`) and #50 (interval-aware stale threshold). #72 (dashboard truth, which excludes age). WID-02 (stale boundary entries).

### WID-06 Account color identity is positional and repeats after three
- **Status / severity / effort / platform:** open; medium (TMP, next tier, not shortlisted); M; the identity rules are Linux-testable in QuotaCore, marker rendering is macOS-only. This is a design improvement, not a broken invariant (REF-16).
- **Sources:** TMP R-UX-01 (CORE-4, WIDGET-6, SETTINGS-3); MAIN W04.
- **Problem and evidence:**
  - `stableAccountOrder` sorts by provider, then display name, then id, and `accountColorStep` is `index % 3` (`QC/ProviderMetricSelection.swift:168-209`, which also holds `providerTileAutoOrder`; `QC/Models.swift:1452-1475`).
  - Adding a Claude account, which sorts first, shifts every later account's variant, so their historical trend lines recolor.
  - Renaming "Claude" to "Work" next to "Claude 2" swaps their base and deep variants and swaps automatic Tile 1, live while typing: the name binding writes on each keystroke (`APP/AppModel.swift:1170-1179`, `APP/Views/SettingsView.swift:875-879`).
  - A fourth account wraps to the base scheme. Claude A and an OpenAI account then draw identical cyan 5-hour and gold weekly lines. The duplicate-dash rule (`WX/LLimitQuotaWidget.swift:811-815`, `:851-868`) restarts per account and does not separate them, and the tiles are the chart's only legend.
  - Raising the modulus does not help: `steppedColor` renders every step of 2 or more as pale (`Shared/LimitKindColorScheme.swift:72-85`) (MAIN).
  - The three-variant wrap is documented and pinned (`Packages/QuotaCore/Tests/QuotaCoreTests/LimitKindTests.swift:111-143`, wrap at `:134-136`). AGENTS.md promises stability only under reorder and toggle (REF-16). The wrap does conflict with "two accounts must never share an exact color scheme" once four or more accounts share a window kind.
- **Proposal:**
  1. Persist identity: either `colorVariant: Int?` on `ProviderStyleSettings`, or an append-only `AppSettings.stableAccountRanks` id list that `stableAccountOrder` sorts by after provider. Seed missing values from today's order at decode time, so existing users see no change. A new account takes the variant least used among accounts that share a window kind. The field travels in the redacted App Group settings, so the widget agrees with the app.
  2. Add a non-color channel for four or more accounts: `accountIdentity(...) -> (colorStep, markerIndex)` with `markerIndex = index / 3` (circle, square, diamond, triangle), drawn as the trend endpoint dot and as a tile glyph. No in-chart legend (AGENTS.md). Alternative: extend the duplicate-dash rule across accounts. IDEA-08's user-chosen badges are the user-facing form; the automatic marker is the fallback.
  3. Keep the three validated variants. A fourth needs the palette validator (WID-09).
  4. Cheap partial fix for churn while typing: commit name edits on submit. Check whether #101's PendingEdits already covers the name field.
  5. Update the AGENTS.md wording.
- **Tests / acceptance:** adding or renaming accounts leaves existing variants and automatic tiles unchanged. Legacy settings decode to today's steps. Twelve accounts produce twelve unique (step, marker) pairs. Four, twelve, coincident, grayscale and custom-identical-color accounts stay traceable. Rename, add, reorder and disable never retarget identity.
- **Relations:** IDEA-08, WID-07 (a non-color channel also helps monochrome), WID-09. MAIN M13 (the legacy style fallback can save identical primaries for two siblings). MAIN F10/F11 (memoize primary colors; hoist the per-call sort in `accountColorStep`). #101, #85.

### WID-07 Widgets ignore vibrant, accented and monochrome rendering
- **Status / severity / effort / platform:** open; medium (TMP, next tier; the verifier lowered it from high because ring position, footer glyphs, trend width and opacity, and dashboard stop opacity keep some meaning); M; macOS-only.
- **Sources:** TMP R-A11Y-01 (WIDGET-3, THEME-1; BACKLOG covers contrast, transparency, motion and Differentiate Without Color, but not rendering mode).
- **Problem and evidence:**
  - Nothing in `WX/` reads `widgetRenderingMode` or uses `.widgetAccentable()`. macOS renders desktop widgets in a desaturated vibrant style when the desktop is not focused, and always under the Monochrome widget style.
  - Relative luminance of the default hues: session #3ED8F0 0.564, weekly #FFC145 0.598 (1.06:1 from session), daily 0.449, monthly 0.455, Other A 0.454. Session and weekly lines become the same gray, and daily, monthly and Other A nearly so. The warning chip keeps its glyph and text but loses its orange.
  - Locations: `WX/ProviderQuotaWidget.swift:705-782`; `WX/LLimitQuotaWidget.swift:205-237` (casing at `:223`), `:542-602`, `:851-868`, `:915-927`; `QC/Models.swift:880-885`.
  - For much of the day, the window identity that AGENTS.md treats as the core encoding cannot be read on the desktop.
- **Proposal:** read `@Environment(\.widgetRenderingMode)` in `ProviderQuotaTileView`, `TrendChartPlotView` and `MiniProgressBar`. When the mode is not `.fullColor`:
  - Add the secondary encoding AGENTS.md already allows: a stroke style per kind (session thin dotted, daily dashed, weekly and monthly solid, with distinct widths).
  - Draw the primary window at full opacity with `.widgetAccentable()` and the secondary at 0.5.
  - Drop shadows and the casing.
  - Hues stay unchanged, so the color semantics hold.
  - Open design point: per-kind dash styles and the same-hue duplicate-dash rule (whose caps and rhythms #109 reworked under R-VIS-06) cannot both use dash patterns. Pick one channel per mode, or use WID-06's markers.
- **Tests / acceptance:** manual, under System Settings > Desktop & Dock > Widget style = Monochrome, plus the tinted appearance on macOS 26. Session and weekly stay distinguishable in each mode. Recorded in WID-21.
- **Relations:** WID-06 (marker channel), IDEA-08, WID-08 (ring backing), WID-21, #109 (R-VIS-06 dash caps), MAIN M11.

### WID-08 Identity hues and text vanish on bright or custom widget backgrounds
- **Status / severity / effort / platform:** open; medium (TMP); M; the contrast math is Linux-testable in QuotaCore, rendering is macOS-only.
- **Sources:** TMP R-THM-02 (SETTINGS-4, THEME-3; extends BACKLOG "Validate the provider slot tiles"); MAIN W08.
- **Problem and evidence:**
  - The 3:1 floor was validated only on graphite #1D1F27 (worst case 3.08:1).
  - On the default widget blue #5994F2: deep session #059BB6 1.09:1, deep weekly #BF8512 1.06:1, deep unlimited #7396B3 1.03:1, Other B base 1.06:1.
  - Against the white 0.14 ring track (`WX/ProviderQuotaWidget.swift:758`) on the Anthropic, Z.ai, Zhipu and Google tile gradients, deep monthly and deep Other A measure 1.01 to 1.06:1 (verifier recomputation). On the OpenAI, Copilot and OpenCode Go tiles, deep session and weekly reach only about 2.1 to 2.4:1. Deep variants measure about 1.0 to 1.7:1 on most presets and 1.45 to 2.49:1 on Classic. Tile rings have no casing.
  - Deep is step 1, worn by the 2nd, 5th, 8th and later accounts. An account's rings can disappear purely because of its rank in stable order, which breaks "tiles are the legend".
  - Text and chrome (W08): light and custom backgrounds keep hard-coded white or faint text and weak scrims (`WX/ProviderQuotaWidget.swift:479-500`, `:571-587`, `:735-738`, `:819-836`; trend chip `WX/LLimitQuotaWidget.swift:184-199`).
  - Further locations: `Shared/LimitKindColorScheme.swift:66-119`; `WX/ProviderQuotaWidget.swift:750-776`, `:802-867`; `WX/LLimitQuotaWidget.swift:1191-1201`; `APP/WidgetStylePreset.swift:29-287`; `QC/Models.swift:880-885`; `QC/ProviderMetricSelection.swift:168-170`.
- **Proposal:**
  - Put a dark backing under tile rings and dashboard bars: a ring stroked at `lineWidth + 2` in black 0.30 under the arc, or a dark inset disc. The trend chart already uses a +1.5 pt casing at 0.28.
  - Use luminance-aware neutral chrome or a controlled scrim for text, keeping identity hues and primary overrides exactly as chosen.
  - Move `LimitKindColors.steppedHex(for:step:)` (base, deep and pale hex math) and a WCAG luminance helper into QuotaCore.
  - If a default hex or the deep formula changes instead, re-run the dataviz validator against graphite and #5994F2 (AGENTS.md).
- **Tests / acceptance:** every variant against #1D1F27, #5994F2, the twelve tile palettes and every preset, with the backing applied (Linux). Captures on white, black, saturated, transparent and high-contrast surfaces.
- **Relations:** TMP R-THM-01 and MAIN M05/M07 (preset darkening and white-text contrast, for example Crazy Banana at 2.03:1). #109's R-A11Y-02 work (dark plot scrim and dark chip capsule on the trend); verify it on light and custom backgrounds. WID-07 (drop the backing outside full color). WID-09. MAIN W11 (one background and alpha contract).

### WID-09 Validate the pale variant and every palette
- **Status / severity / effort / platform:** open; medium (TMP); M; Linux-testable.
- **Sources:** TMP R-THM-03 (WIDGET-12); TMP rejected idea "Validated limit-color packs" (RJ-IDEA-COLOR-PACKS); MAIN-reported #53. TMP backlog note (R-THM-03): new, as part of the BACKLOG hex-parser consolidation.
- **Problem and evidence:**
  - The pale variant (step 2, worn by the 3rd, 6th, 9th and later accounts) is a 50% blend toward white (`Shared/LimitKindColorScheme.swift:72-85`, blend at `:83-84`). OKLCH chroma: session 0.077, daily 0.102, weekly 0.086, monthly 0.079, aux 1 0.060, aux 2 0.079. Five of the six fall below the documented 0.10 floor.
  - The reviewer's own CVD distance metric (not re-checked) drops from 4.0 for base colors to 1.3 for pale.
  - Pale was never validated. `scripts/tests/LimitKindColorTests.swift` (run by `scripts/test-limit-colors.sh`) checks only color identity.
  - MAIN-reported #53 already ships five `LimitKindPalette`s (Standard, Ocean, Sunset, Forest, Vivid) across rings, bars, sparklines, the menu bar, widgets and the trend. MAIN asks for contrast, CVD and canonical-write validation when extending it. TMP's ideation rejected new color packs until pale is fixed.
- **Proposal:**
  - Derive pale in OKLCH: raise L by about 0.12, keep chroma at 0.10 or more, and keep the hue.
  - Port the dataviz palette validator to a Linux `swift test` in QuotaCore, together with the color math from WID-08.
  - Validate all 18 variants (six hues x base, deep, pale) of every shipped palette against #1D1F27 and #5994F2, using the AGENTS.md floors: CVD all-pairs ΔE of 12 or more for the six base hues, 8 or more with secondary encoding for base plus deep, chroma of 0.10 or more, and 3:1 or more on graphite. Define the pale floor explicitly. The unlimited hue is stepped too (`metricColor` passes it through `steppedColor`), so include it.
  - Fix or withdraw any #53 palette that fails. New packs (MAIN's Catppuccin Mocha, Nord, Tokyo Night and Monokai Pro ideas) must pass the same test.
- **Tests / acceptance:** chroma floor and pairwise CVD distance for every variant of every palette. The test fails for today's pale variant and passes after the fix.
- **Relations:** WID-06 (a fourth variant needs this validator), WID-08, MAIN M08 (canonical `LimitKindColors` writes), #53, AGENTS.md "Color semantics".

### WID-10 Trend chart readability, remainder
- **Status / severity / effort / platform:** partial. #109 implements most of R-VIS-05. Remaining: a primary-window-only small widget, separating overlapping flat lines, and short-term limits off by default. Medium (TMP); S; the selection rule is Linux-testable, rendering is macOS-only.
- **Sources:** TMP R-VIS-05 (WIDGET-8, THEME-14); LEDGER #109 deferral. TMP backlog note (R-VIS-05): extends BACKLOG "Widgets > Trend chart" (segment paths; reset boundaries render as vertical snaps; per-metric selection).
- **Problem and evidence:**
  - Every enabled account's bounded metrics share one 0-100 axis, and short windows are shown by default (`showShortTermLimitsInTrend` defaults to true in the initializer, `QC/Models.swift:1271`, and in the decode fallback, `:1320`).
  - Unused quotas lie exactly on the top edge and hide each other.
  - `.systemSmall` draws the same set into about 110 pt with no axis.
  - Locations: `WX/LLimitQuotaWidget.swift:205-225`, `:298-301`, `:798-887`.
- **Proposal:**
  1. In `.systemSmall`, chart only each account's primary slot (`primaryLimitSlot`).
  2. Offset coincident flat series by ±1 pt, or stack their endpoint dots.
  3. Optionally default `showShortTermLimitsInTrend` to false for new installs only: change the initializer default and keep the decode fallback, so saved files keep their explicit or legacy value. This is a product decision.
  - No legend is added (AGENTS.md).
- **Tests / acceptance:** the small-family selection (Linux). Coincident flat series render apart. A new install defaults off while existing files keep their value.
- **Relations:** WID-11, WID-19, WID-06 (endpoint markers), #109.

### WID-11 Trend sampling loses extrema and bridges gaps
- **Status / severity / effort / platform:** open; severity unrated in MAIN; effort S-M (estimate); Linux-testable once sampling lives in QuotaCore.
- **Sources:** MAIN W05; MAIN widget visual check on gap-spanning paths (AM-WID-VC-3).
- **Problem and evidence:**
  - `downsampleTrendPoints` (`WX/LLimitQuotaWidget.swift:930-945`, applied with at most 240 points at `:838`) samples source index `round(i x (n - 1) / (max - 1))`. For 241 points sampled to 240, i = 119 gives 119.497, rounded to 119, and i = 120 gives 120.502, rounded to 121. Source index 120 is never drawn, so a zero there disappears. Short refill spikes and exhaustion minima can vanish the same way.
  - Solid paths span gaps between observations (sleep, offline, failures), implying continuous measurement and an exact refill instant. A later observation establishes neither.
- **Proposal:**
  - Use chronological, extrema-preserving buckets (each bucket's minimum and maximum, in time order) that always keep endpoints and reset transitions, with a bounded output size.
  - Sample source-time observations (#75) so display sampling never creates points.
  - Split paths at gaps longer than a threshold derived from the refresh interval, and show the gap neutrally (PRD-19's coverage rail) instead of bridging it.
- **Tests / acceptance:** the fixture's zero at index 120 of 241 survives, and so do short refill spikes. The output bound holds and endpoints are kept. A gap above the threshold yields two segments.
- **Relations:** #109 (its path builder and `QuotaForecast` touch the same code; forecasts must use observations from before display sampling, MAIN W06). #75 (source-time history). #98 (forward fill is decoration, not observation). PRF-03 (bounded widget projection; downsample before sharing). WID-10.

### WID-12 Dashboard row geometry and capacity
- **Status / severity / effort / platform:** partial. #80 (MAIN-reported) replaces the fixed systemSmall columns with flexible ones. Remaining: the medium family's fixed columns, geometry-derived capacity, and dual text. Medium (TMP R-VIS-03); S-M; macOS-only.
- **Sources:** TMP R-VIS-03 (WIDGET-5; extends BACKLOG "Existing dashboard widgets": remove fixed-width columns, use `ViewThatFits`, derive row capacity from geometry); MAIN widget visual check (AM-WID-VC-1).
- **Problem and evidence:**
  - At baseline, `CompactProviderUsageRow` fixes the name at 58 pt (`WX/LLimitQuotaWidget.swift:505`) and the percent at 40 pt, or 72 pt with dual text (`:528`). Dual percentages are on by default (`QC/Models.swift:1268-1269`).
  - In small rows, name, dual text and spacing fix 142 pt. A small widget is about 158 to 170 pt wide, minus 16 pt of padding and the system margins (WID-13). That leaves the bar about 12 pt or less, or the row overflows. #80's fix for systemSmall is reported, not natively verified.
  - The medium dashboard attempts up to twelve rows (`mediumProviderLimit` clamped to 12 at `:440`; small clamps to 4 at `:358`) plus header, footer and padding, with no capacity check derived from geometry.
- **Proposal:**
  - In `.systemSmall`, use two-line rows (name and one percent on top, then a full-width bar with two stops), or drop the dual text there.
  - Replace the remaining fixed widths with `.layoutPriority` and `ViewThatFits`.
  - Derive row capacity from geometry and disclose omitted accounts. Reconcile with #54's reported medium-family "+N more".
  - Label or order the dual text by window (BKL-08).
  - Consider medium tiles or a `.systemLarge` dashboard only after the overflow work, with kinds frozen (BND-07).
- **Tests / acceptance:** manual renders with 1, 2, 4, 6 and 12 accounts, long names, dual values on and off, failures and enlarged text. No clipping, and omitted accounts are disclosed.
- **Relations:** WID-13, BKL-08, WID-01, WID-16 (row space for amounts), #54, #72, #80.

### WID-13 Dashboard and trend widgets double their content margins
- **Status / severity / effort / platform:** open; medium (TMP); S; macOS-only.
- **Sources:** TMP R-VIS-04 (WIDGET-13).
- **Problem and evidence:** neither the dashboard nor the trend widget calls `.contentMarginsDisabled()` (`WX/LLimitQuotaWidget.swift:8-30`), and both then pad by another 7 to 10 pt (`:114`, `:394`, `:469`). The tiles do this correctly (`WX/ProviderQuotaWidget.swift:110`). The result is less room for the plot and the rows. The reclaimable space depends on macOS's default margin, which was not measured.
- **Proposal:** add `.contentMarginsDisabled()` and keep one deliberate 10 to 12 pt inset matching the tiles, or keep the system margins and remove the custom padding. Tighten the trend VStack spacing.
- **Tests / acceptance:** manual renders in light and dark, small and medium, measuring the margin before and after.
- **Relations:** WID-12, WID-10.

### WID-14 Antigravity's two rings share a color, and aux colors shift
- **Status / severity / effort / platform:** open; medium (TMP); M; Linux-testable.
- **Sources:** TMP R-VIS-02 (CORE-3).
- **Problem and evidence:**
  - All four Antigravity models (`QC/Clients/GoogleAntigravityClient.swift:18-23`) classify as `.other` and take aux slots 0 to 3 by metric position (`limitSeriesSlots`, `QC/ProviderMetricSelection.swift:72-82`).
  - The rings show pro-high (slot 0) and flash (slot 2; ring preference at `:24`). There are two `otherHexColors`, indexed `% count` (`QC/Models.swift:884`, `:921`), so slot 2 wraps to `otherHexColors[0]`, and both rings are #B8A8FF in the same account step.
  - When the server omits the image model, flash moves to slot 1 and its color flips between refreshes, despite the `limitSeriesSlots` comment promising stable colors. In the trend chart, the duplicate-dash rule keeps the lines apart, but they still recolor.
  - The test fixture omits pro-high (`Packages/QuotaCore/Tests/QuotaCoreTests/LimitKindTests.swift:34-36`, `:79-94`).
- **Proposal:**
  - Reorder `modelSpecs` to pro-high, flash, image, claude.
  - Make `.other` slot assignment independent of which metrics are present: add `limitSeriesSlots(for usage:)`, which ranks `.other` metrics by the provider's ring preference and then by id.
  - Google's trend colors change once.
- **Tests / acceptance:** for each provider fixture, the two default ring metrics resolve to different hex values unless they share a kind. Removing the image model does not move flash.
- **Relations:** PRV-10 (TMP R-BUG-18, hardcoded Antigravity model ids in the same client). WID-15. WID-16 (an amount-only `extra_usage` metric also takes an aux slot).

### WID-15 Copilot monthly quotas classified as .other
- **Status / severity / effort / platform:** open; low (TMP); S; Linux-testable.
- **Sources:** TMP R-THM-06 (CLIENT-14).
- **Problem and evidence:** the labels "chat Chat" and "completions Completions" (`QC/Clients/CopilotClient.swift:175-181`) carry no cadence word, so `QuotaWindowKind.classify` (`QC/Models.swift:807`) returns `.other`. They take aux hues instead of the monthly hue, breaking the AGENTS.md rule that metrics with a reset cadence use labels the classifier understands.
- **Proposal:** relabel them "Monthly chat" and "Monthly completions", together with PRV-11 (TMP R-BUG-19's decoder work in the same client). History is keyed by id and is unaffected; the line colors change once.
- **Tests / acceptance:** add both pairs to `testClassifyKnownProviderMetrics`, expecting `.monthly`.
- **Relations:** PRV-11, WID-14, TMP R-DEBT-05 (English labels are persisted and parsed for the window kind).

### WID-16 Claude extra usage on widgets
- **Status / severity / effort / platform:** partial. #93 emits an amount-only `extra_usage` metric, with R-BUG-06's cents fix, that reaches Linux usage lines. Remaining: ring tiles and the dashboard widget (deferred by #93). Medium (TMP); S; macOS-only rendering.
- **Sources:** TMP R-FEAT-01 (PRODUCT-11); LEDGER #93 deferral.
- **Problem and evidence:** at baseline, `extra_usage` was only a grey dropdown subtitle (`QC/Clients/AnthropicClient.swift:109-123`, `APP/LLimitApp.swift:1444-1451`). After #93 it is a metric with a nil percentage. `defaultRingMetrics` excludes such metrics (`QC/ProviderMetricSelection.swift:4`), and a dashboard row shows a usage line only when its primary metric has no percentage (`WX/LLimitQuotaWidget.swift:520`). Neither widget shows extra usage.
- **Proposal:**
  - When extra usage is enabled, show the amount (for example "Extra $12.34 / $50.00") in the Claude tile footer or a capsule, and as a secondary line or suffix on the dashboard row. Follow MAC-14's amount-only presentation.
  - Keep it out of headline minimums, rings, trend lines and the primary slot. It never gets a percentage.
  - Never add the card subtitle to the Linux JSON (BND-02): Antigravity's subtitle is an email.
- **Tests / acceptance:** tile and dashboard renders with extra usage enabled and disabled. The metric never becomes a ring, the primary slot or a trend series.
- **Relations:** #93 (non-USD amounts need a capture; deferred). MAC-14. WID-12 (row space). WID-14 (aux slot).

### WID-17 Tile gallery previews and the "awaiting account" copy
- **Status / severity / effort / platform:** open; medium (TMP); M; slot resolution is Linux-testable, previews are macOS-only.
- **Sources:** TMP R-UX-11 (WIDGET-14). Partly unverified: the previews are not identical, because `sampleEntry` cycles the color variants and neighboring slots differ (REF-19). They still do not show which account a slot maps to.
- **Problem and evidence:**
  - Every preview shows the same Z.ai 82%/64% sample (`WX/ProviderQuotaWidget.swift:168-174`, `:214-256`, `:342-383`).
  - The automatic rank counts every lower-numbered unassigned slot, placed or not (`:381`, `:408-412`; `QC/Models.swift:1471-1475`). A user with three accounts who places only Tile 5 is told that "lower-numbered tiles cover them all".
  - The trend sample history climbs from 54% to 72% (`WX/QuotaTimelineProvider.swift:260-272`), showing quotas refilling, the opposite of real traces.
- **Proposal:**
  - In previews, read the real settings and snapshot and render the account the slot maps to. With no accounts, show "Tile N shows your Nth account".
  - State the rule in the awaiting copy, for example: "Tile 5 shows your 5th unpinned account; you have 3. Use Tiles 1-3 or pin one in Settings > Widgets."
  - Move slot resolution into `AppSettings.providerTileResolution(forSlot:)` in QuotaCore.
  - Make the trend sample drain and then reset.
  - No widget-side configuration is added (BND-07).
- **Tests / acceptance:** slot resolution in QuotaCore for pinned, automatic, beyond-account-count and removed-pin cases. Previews show the mapped account.
- **Relations:** REF-19, WID-03, WID-06 (automatic order), WID-20 (the resolved account feeds the deep link), WID-21.

### WID-18 "Unlimited plans only" shown alongside unknown quotas
- **Status / severity / effort / platform:** open; severity unrated in MAIN; S (estimate); Linux-testable where #109's builder lives in QuotaCore.
- **Sources:** MAIN W10.
- **Problem and evidence:** the trend builder sets `sawUnlimitedMetric` for any unlimited metric and skips metrics without a percentage (`WX/LLimitQuotaWidget.swift:745-762`), then reports `hasOnlyUnlimitedData = series.isEmpty && sawUnlimitedMetric` (`:908`). The empty state then says "Unlimited plans only / Every tracked limit reports unlimited" (`:124-125`), even when, for example, Copilot's premium quota is unknown and only chat is unlimited, or other included accounts are amount-only.
- **Proposal:** track explicitly unlimited metrics separately from unknown and non-chartable ones. Report unlimited-only only when every metric of every included account is explicitly unlimited; otherwise give a mixed reason. Check whether #109's `.onlyUnlimited` and `.onlyAmounts` reasons still use the old predicate.
- **Tests / acceptance:** unknown premium plus unlimited chat never says unlimited-only. All-unlimited accounts do. Amount-only plus unlimited reports the mix.
- **Relations:** #109, WID-03.

### WID-19 Trend context and multiple warnings
- **Status / severity / effort / platform:** open; severity unrated in MAIN; M (estimate); warning selection is Linux-testable, layout is macOS-only.
- **Sources:** MAIN W12 (an incoming-main request); extends the BACKLOG "Trend chart" bullet "show more than one warning" cited by TMP R-BUG-12.
- **Problem and evidence:** at baseline the widget shows only `warnings.first`, in provider rawValue order, as one 8.5 pt line (`WX/LLimitQuotaWidget.swift:99-111`). It has no current-value, time or percentage context beyond the small axes. #109 moves the forecast into QuotaCore as `QuotaForecast` (R-BUG-12), but still renders a single warning.
- **Proposal:** add bounded summaries (current value, time, percentage) and more than one warning when space allows, built from corrected observations through #109's `QuotaForecast`. Disclose omitted warnings (for example "+2 more"). Keep unknown and freshness context and the accessibility summary (MAC-04). Summaries must not obscure the traces.
- **Tests / acceptance:** sparse, dense and multiple-warning fixtures in each family. Omitted warnings are disclosed, and the accessibility summary covers every warning.
- **Relations:** #109 vs #87 (`PaceEstimator`; converge on one estimator). #103 (pace). WID-10, WID-11, MAC-04.

### WID-20 Widgets have no deep links
- **Status / severity / effort / platform:** open; severity unrated in MAIN; M (estimate); route parsing can be a Linux-testable QuotaCore function, everything else is macOS-only.
- **Sources:** MAIN W13 (pass D).
- **Problem and evidence:** nothing in `WX/` uses `.widgetURL` or `Link`, and the host app registers no URL scheme (`LLimitApp/Info.plist` has no `CFBundleURLTypes`). Tiles cannot open their assigned account, and the dashboard cannot open a failing account.
- **Proposal:**
  - Add a scoped app URL scheme with an account route (for example `llimit://account/<id>`). Parse it in a pure QuotaCore function and handle it in `LLimitApp/` through an application service that opens the dashboard or Settings > Accounts on that account.
  - Tiles use `.widgetURL` for their resolved account. Medium dashboard rows use `Link` for failing accounts; small widgets support only one `.widgetURL`.
  - URLs carry only the account id, never credentials. Opening one never mutates an account, starts a sign-in or switches a CLI login. Kinds stay frozen.
- **Tests / acceptance:** routes for assigned, failing, unknown and removed account ids; unknown and removed ids recover to the account list with a notice. Generated URLs are credential-free. A manual click-through on installed widgets focuses the right account.
- **Relations:** WID-17 (slot resolution supplies the tile's account), WID-21, BND-07.

### WID-21 Installed widget validation matrix
- **Status / severity / effort / platform:** open; unrated; M (manual, repeated when the widgets change); macOS-only.
- **Sources:** MAIN widget visual/runtime checks (AM-WID-VC-4, AM-WID-VC-5).
- **Problem and evidence:** every widget claim in this section comes from source inspection. Nothing has been checked on installed widgets. The repository screenshots (`screenshot-widgets.png`, `screenshot-window.png`) show cohesive rings and cards but dense traces, tiny axes and prominent warnings. They are aesthetic context, not current pixels.
- **Proposal:** install with `scripts/build.sh --install` (keep its lsregister cleanup and the chronod and NotificationCenter restarts). Place the twelve slot tiles, the dashboard and the trend widget in each family, and capture:
  - automatic mapping, pinned assignments, the `#N AUTO` badge, every palette (#53) and source-account identity;
  - light, dark, tinted and monochrome desktop presentation;
  - Differentiate Without Color, Increase Contrast, Reduce Transparency and Reduce Motion;
  - long names;
  - every quota state: fresh, stale, failing, reset pending, unlimited, unknown, amount-only and exhausted;
  - maximum archives: twelve accounts, a 30-day trend, and the 3,000-entry history cap.
  - Correlate reloads with `scripts/widget-diagnostics.sh`.
- **Tests / acceptance:** a recorded matrix with one capture per cell and a pass or fail per row. Failures are filed against WID-07, WID-08, WID-09, WID-12, WID-13 and WID-17.
- **Relations:** every entry above. PRD-15 (MAIN's check of 6.5 pt axes and 7 pt tile badges at real desktop scale). AGENTS.md "Widget registration".

## Linux daemon, CLI and tray

This section covers the `llimit` CLI, the daemon, the tray and the bar examples.
Before writing new code, reconcile this pass's #104, #105, #108 and #110 with
MAIN-reported #50, #51, #64, #83, #88 and #97-#99. Several of them add keys,
flags or exit codes for the same need, and the bar JSON contract is additive-only
(BND-02): once a key ships, its name is permanent. Packaging and installer issues
are in Build, except the XDG part of the installer (LNX-04). Line references are
baseline `2d6ac1e` starting points. Path prefixes: QC/, LD/, CLI/, APP/, WX/ as
elsewhere, plus TRAY/ = `Packages/LLimitd/tray/`, EX/ =
`Packages/LLimitd/examples/`, SD/ = `Packages/LLimitd/systemd/` and LDT/ =
`Packages/LLimitd/Tests/LLimitdCoreTests/`. "Source check" marks a location
re-read in the baseline tree while merging. "Worktree check" marks a read of the
PR's local worktree on 2026-10-07, which may differ from the PR head. Everything
else is as the sources report it.

### LNX-01 Bar and tray show failing and stale accounts as healthy

- **Status / severity / effort / platform:** partial. #105 (this pass) and #64
  (MAIN-reported) each implement most of the failure display; the remaining work
  is reconciling them, interval-aware staleness (one rule shared with #108's
  commands), cross-account ordering and the tray's provider warnings. TMP rates it
  high; verifiers split between high and medium-high because the waybar hover
  tooltip does list ERROR lines. MAIN does not rate it. Original effort M;
  remaining S to M. Linux-testable
  (StatusRendererTests, `TRAY/tests/test_menu_model.py`).
- **Sources:** TMP R-LNX-01 (LINUX-2, PRODUCT-1, LINUX-8, LINUX-9; CORE-1 for the
  class part); MAIN L02, L03, #64 and #50 reports; LEDGER #105 and its integration
  check. TMP backlog note (R-LNX-01): extends BACKLOG "Data correctness > Fresh, stale, failed, and unknown state", which has no Linux coverage.
- **Done elsewhere:** #105 adds per-account `failed`, `lastKnown`, `errorKind`,
  `error` (one sanitized line) and `fetchedAt`, failure-only accounts with
  `remainingPercent: null, metrics: []`, a top-level `failures` array (id,
  provider, name, errorKind; no messages), a trailing "!" in `text`, class
  elevation, account-named ERROR lines with a "Provider (id8)" fallback, and tray
  error rows. #64 reports additive `failing`/`error`/`errorKind`, a failure title
  fallback (recorded title, then cached usage title, then provider),
  most-actionable duplicate collapse, green-to-warning escalation and full error
  tooltips in the tray.
- **Problem and evidence:**
  - Baseline behavior (for regression tests): once an account had succeeded once,
    an expired Claude token, a revoked key or an outage left, for example,
    "Claude 82%" green `ok` indefinitely (`LD/StatusRenderer.swift:114-143`
    builds accounts only from `providers`; `:162-181` lets failures matter only
    when `providers.isEmpty`). Failure-only accounts were missing from `accounts`
    and the tray. ERROR lines used the provider name and sorted by UUID
    (`:55-57`), so "Claude Work" and "Claude Personal" could not be told apart.
    The examples README (`EX/README.md:21-37`) documents `error` as "every account
    failed", which was effectively unreachable. `LDT/StatusRendererTests.swift:223-231`
    covered only `providers: []`. Linux Claude tokens expire routinely, so this
    is the primary Linux surface presenting stale numbers as current.
  - Key-set overlap: #105 emits `failed` (plus `lastKnown`, `fetchedAt`,
    `failures`); #64 emits `failing`. Both emit `error` and `errorKind`. Merging
    both freezes two synonyms into the contract.
  - Staleness: baseline `:130` used a fixed 2 h, wrong both ways. At a 180-minute
    interval healthy accounts were stale between 2 h and 3 h; at a 15-minute
    interval a failing account took 2 h to be marked stale. Worktree check: #105
    uses `2 x AppSettings.refreshIntervalRange.upperBound` (6 h), because the
    snapshot does not record the interval, and flags failing accounts at once
    through `failed`. A healthy-looking account whose daemon stopped at a
    15-minute interval therefore goes 6 h before it is stale. #50 reports
    "configured-interval staleness instead of a hardcoded two hours"; how it gets
    the interval while `status` is snapshot-only (#66, #108) is unverified.
  - Integration check (#105 + #108): once both land, staleness disagrees. #108's
    template `{stale}` and `check`/`pick` use 2 h (`HeadroomRanking.defaultMaxAge`),
    while #105's status output uses 6 h. Pick one rule, ideally from a recorded
    refresh interval (proposal 2).
  - Freshness stamp: the tooltip's and tray's "Updated just now" comes from
    `generatedAt`, the time of the current cycle, not the age of the data.
    Worktree check: #105 keeps this stamp and adds per-line "(last known, age)"
    and "(stale, age)" notes. It emits `fetchedAt` but no `ageSeconds`, although
    R-LNX-02 asked for both and the LEDGER overlap notes list both; check the PR
    head.
  - All-failed: #105 maps "every account failed" to `error` (worktree check).
    MAIN notes that #64 does not cover all-failed health, so the rule must survive
    whichever key set is kept.
  - Ordering: #105 sorts by provider, name, then id; #64 reports per-account
    ranking (duplicate collapse) only. Neither orders accounts or ERROR lines by
    severity and recency.
  - Class cap: TMP caps only a failing account's carried value at `warning`
    (CORE-1). Worktree check: #105 also excludes stale, non-failed accounts from
    the critical computation, so with a stopped daemon a 2% account reads
    `warning`. TRACKING records this "needsAttention filter" as a possible
    important finding in #105's second review round. LEDGER's final update
    records the outcome: in #105's final head, stale accounts cap the class at
    `warning`. #108's template `{class}` does not apply that cap yet (LNX-10).
  - Tray (MAIN L03, reproduced with in-memory probes): the baseline popup hides
    spending warnings and errors whenever any account has data
    (`TRAY/llimit_tray.py:145-162`; MAIN cites `:138-159,301-304`, TMP
    `:144-163,276-307`), and adds "stale" to the header only after 2 h (`:106-107`).
    Worktree check: #105 adds error rows, a "failed" header suffix and a failure
    count, but still never renders the per-account `warning` key (for example a
    key spending cap), which only nudges the icon class.
  - Per-account source age is not shown on bars or in the tray (WID-05).
- **Proposal:**
  1. Before either merges, choose one key set. #105's is the larger set; if it is
     kept, port #64's title fallback chain and most-actionable duplicate collapse
     into it (#105 keeps the first failure per id). Never ship both `failed` and
     `failing`.
  2. Have the daemon record `refreshIntervalMinutes` in the snapshot (additive,
     credential-free) and base `stale` on 2x that interval, falling back to the
     6 h constant for snapshots without it. Reconcile with #50's implementation
     instead of building a second one; `status` must not read settings to get it.
     Use the same rule for #108's template `{stale}`, `check` and `pick`.
  3. Check that `EX/README.md` documents #105's cap (stale accounts raise the class
     to `warning` at most) next to the class table.
  4. Define one cross-account order (severity, then most recent failure using
     COR-06's timestamps) for ERROR lines, the human output and the tray. Keep the
     JSON `accounts` order stable unless the README documents order as part of
     the contract.
  5. In the tray, show the account `warning` as a row under its header whether or
     not other accounts have cached data. Keep cached metrics and actions.
  6. Derive fetch health from current failure ids and per-account source age, not
     attempt time (MAIN L02): model last attempt, last success, current failure
     and stale age consistently, and replace or qualify the "Updated" stamp with
     per-account source age (WID-05), for example the oldest `fetchedAt` shown.
  7. Update the examples README tables and CSS comments for the final keys.
- **Tests / acceptance:** StatusRendererTests: every account failed with carried
  data gives `error`; one failed account gives `warning` plus flags and the "!"
  marker; a failure-only account is present; two same-provider accounts are named
  apart; a snapshot with a 180-minute interval is not stale at 2.5 h and one with a
  15-minute interval is stale after 30 min; an old snapshot without the interval
  uses the fallback; `status`, the template `{stale}` and `check`/`pick` agree on
  staleness for the same snapshot; ordering follows severity then recency.
  `test_menu_model.py`: a mixed payload shows the error row and the provider
  warning row; a failure-only account gets a header. No test asserts both `failed` and `failing`.
- **Relations:** overlaps #64 and #50 (MAIN). R-BUG-08's carried-window clearing
  (in #105 as `clearingElapsedWindows`) feeds this. LNX-16 and R-IDEA-17 depend on
  the chosen per-account keys. LNX-03 adds a settings-error state that should use
  the same `error` class path. #108's template `{class}` mirrors the baseline
  cutoffs and ignores #105's cap, and #108's templates and `pick` ignore #105's
  failure title (LNX-10). #103 deferred `paceDelta` in this JSON.

### LNX-02 In-place account update, remainder

- **Status / severity / effort / platform:** partial. #104 adds `llimit accounts
  update <id> [--name N] [--set key[=value] ...]`, `rename <id> <name>`,
  `reimport <id> [--from <stable-id>]`, and an update/new/skip choice in `import`
  (non-interactively it imports nothing for an ambiguous login, prints the
  `reimport`/`import --new` commands and exits 1). Worktree check: #104 also
  compares only primary secrets when deciding "already imported" and documents
  `rename` in the README. TMP rates the item high (Linux Claude imports never
  self-renew, so this is the routine recovery path); one verifier rated it medium
  because remove-and-add is a workaround. Remaining effort S. Linux-testable.
- **Sources:** TMP R-LNX-03 (LINUX-3, PRODUCT-2); LEDGER #104 deferrals; MAIN L09
  (same need, proposed as `llimit accounts set`). TMP backlog note (R-LNX-03):
  extends BACKLOG "Honest OAuth ownership (always offer an Update/Re-import
  action)" and "Multi-account discovery and replacement".
- **Problem and evidence:**
  - At baseline a renewed Claude token shared no value with the old one, so
    `import` added a second account also named "Claude"
    (`LD/QuotaDaemon.swift:189-195` used `suggestedName` verbatim) while the old
    one kept failing; remove-and-add purged history (`:207-216`) and changed the
    id. #104 fixes this path.
  - Still open: the import records no source, so `reimport` without `--from`
    cannot know which discovered login an account came from and must list
    choices when several exist.
  - Still open: Claude discovery's `expiresAt` is dropped
    (`QC/CredentialDiscovery.swift:94-122`), so nothing warns before an imported
    token expires.
- **Proposal:**
  1. Store a non-secret `importSource` stable id on the account at import and
     update it on reimport; make `reimport <id>` default to it.
  2. Carry the discovered Claude `expiresAt` into `anthropic.expires_at`. Surface
     "token expired: run llimit accounts update" (or `reimport`). Because
     `status` is snapshot-only, the daemon must publish the expiry state (an
     expiry timestamp, never the token) or a typed failure into the snapshot;
     `accounts list` may read it from settings. Shared with PRV-16.
  3. Keep #104's invariants: id and history kept, managed Claude metadata cleared
     when the token changes, the Venice estimate cleared on key change.
- **Tests / acceptance:** import stores `importSource`; `reimport <id>` without
  `--from` picks that source; an expired imported token shows the update hint in
  `status` and `accounts list`; no credential appears in the snapshot.
- **Relations:** secret input on stdin or a file descriptor (MAIN L09's second
  half) is SEC-06. LNX-11's misleading "ready" also needs the expiry. LNX-06
  removes the need for reimport for managed accounts.

### LNX-03 An unreadable settings file is reported nowhere

- **Status / severity / effort / platform:** partial. #104 reports the failure
  in the CLI and daemon. Worktree check: mutating and listing commands fail with
  "Settings file <path> is unreadable: <reason>. Fix it or move it aside; LLimit
  will not overwrite it."; the reason comes from the `DecodingError` case, coding
  path and expected type only (never the decoder's message, which can echo a
  value); the daemon logs it once per distinct error and no longer logs "No
  enabled provider accounts..."; `status` prints the warning on stderr from
  `makeDaemon`. TMP rates it medium; remaining effort S. Linux-testable.
- **Sources:** TMP R-LNX-06 (LINUX-6); LEDGER #104 interplay note. TMP backlog
  note (R-LNX-06): new; BACKLOG "Settings recovery" targets only the macOS UI.
- **Problem and evidence:**
  - Baseline: only `statusMessage` was set (`LD/QuotaDaemon.swift:78-87`) and no
    CLI path printed it; the daemon logged "No enabled provider accounts with
    complete credentials configured." every cycle (`:271-279`); `accounts list`
    said "No accounts. Add one with ..." (`CLI/main.swift:81-88`); the
    `DecodingError` context was discarded. One typo in the only settings file
    silently disabled the Linux product with every diagnostic pointing the wrong
    way.
  - Remaining: once `status` is snapshot-only (#108 or #66), it never loads
    settings, so #104's stderr warning goes dead. The integration check drops that
    `makeDaemon` branch and the README sentence about it; whichever of #104 and
    #108 lands second must carry that fix. Bars and the tray then show the
    last-known snapshot (which the #104/#66 guard preserves) with no sign that
    refreshing has stopped, until it eventually turns stale.
- **Proposal:**
  1. Have the daemon (and the one-shot `llimit refresh`) publish a credential-free
     `settingsLoadError` (path, structural reason, first-seen time). TMP proposes
     a separate `daemon-state.json` (settings error, last cycle); the cluster
     alternative is an additive snapshot field. Prefer the separate file: the
     unreadable-settings guard promises unchanged snapshot bytes, which a new
     snapshot field would break. Clear it after the next successful load.
  2. Render it in `status`: class `error` (TMP), a tooltip line naming the file,
     and a tray row, while still listing cached accounts. Document this second
     meaning of `error` in `EX/README.md`.
  3. Never include file contents. Reuse #104's `SettingsLoadError`.
- **Tests / acceptance:** corrupt settings plus a valid snapshot: snapshot-only
  `status --json` shows `error` with the path and reason, the cached accounts stay,
  and a secret-shaped value placed at the decoding error location appears in no
  output; the daemon logs once; fixing the file clears the state next cycle.
- **Relations:** recovery (backup, restore, guided reset) is COR-07. The guard
  against wiping the snapshot is #104 (daemon) and #66 (MAIN Linux C03). LNX-11's
  `doctor` checks the same condition. LNX-01 for the class rules.

### LNX-04 Daemon and CLI can use different XDG paths

- **Status / severity / effort / platform:** open. TMP rates it medium, effort S.
  The comparison logic is Linux-testable; the installer part needs shell tests.
- **Sources:** TMP R-LNX-08 (LINUX-14); MAIN L06; TMP R-BUG-04 (interaction).
- **Problem and evidence:**
  - `LD/LinuxPaths.swift:20-41,69-74` resolves `XDG_CONFIG_HOME`/`XDG_DATA_HOME`
    from the process environment (absolute values only, else `~/.config` and
    `~/.local/share`). Users often export `XDG_*` in shell rc files, which the
    systemd user manager never reads, and `SD/llimit.service:8` sets no
    Environment. The CLI then writes accounts where the service never looks.
  - When only the config path differs, the daemon reconciles the shared snapshot
    against an empty configuration every cycle and wipes it (R-BUG-04; REF-22:
    the daemon, not `status`, wipes it). Source check: `SettingsStore.load()`
    returns defaults without error when the file is missing, so the
    unreadable-settings guard in #104/#66 does not cover this case.
  - Only the journal startup lines (`CLI/main.swift:358-363`) and `llimit paths`
    (`:411-415`) reveal either side's view.
  - Installer (MAIN L06): `SD/install.sh:44-49,59-61` ignores custom XDG config
    roots (it hard-codes `$HOME/.config/systemd/user`), writes unquoted home paths
    into the tray unit's `ExecStart`, and its raw `sed` replacement mishandles `&`
    in the path.
- **Proposal:**
  1. Add the XDG comparison to `llimit doctor` (LNX-11): compare the CLI's
     `LinuxPaths` with `systemctl --user show-environment` and the unit's
     Environment, and warn on a mismatch. Keep the comparison a pure function.
  2. Document `~/.config/environment.d/*.conf` in the README as the way to give
     the daemon the same XDG values.
  3. Optional, not in the sources: log a one-time daemon warning when its settings
     file is missing while the snapshot it is about to reconcile lists accounts.
     Do not block reconciliation of an existing, intentionally empty file (MAIN
     C03 rule).
  4. Installer: resolve valid XDG roots the same way as `LinuxPaths`, emit
     correctly quoted systemd argv (systemd also treats `%` as a specifier), and
     stop passing raw paths through `sed` replacements.
- **Tests / acceptance:** the pure comparison flags a shell-only
  `XDG_CONFIG_HOME`. Installer tests with spaces and `&` in the home path and with
  absolute, relative and unset XDG values check the exact executed paths.
- **Relations:** LNX-11 (`doctor`), LNX-03, LNX-06 (managed profiles add another
  path the daemon must share), R-BUG-04's guard in #104/#66. Other installer
  issues (L05, L07, L08, L10) are in Build.

### LNX-05 Account id matching and remove confirmation

- **Status / severity / effort / platform:** partial. #104 rejects blank ids
  (trimmed) and matches prefixes case-insensitively, with an error listing the
  candidates when a prefix is ambiguous (worktree check). Remaining: a 4-character
  minimum prefix and a TTY confirmation with `--yes`. TMP rates it medium,
  effort S. Linux-testable.
- **Sources:** TMP R-LNX-09 (LINUX-15); LEDGER #104 deferrals.
- **Problem and evidence:** at baseline `hasPrefix("")` matched every id
  (`LD/QuotaDaemon.swift:219-225`), so with one account `llimit accounts remove
  "$UNSET"` (quoted) removed it and purged its history; an unquoted unset
  variable failed safely. Ids are uppercase UUIDs, so lowercase prefixes failed.
  `remove` (`CLI/main.swift:66-75,295-312`) never confirms. Short prefixes such
  as one character still resolve after #104 whenever they are unique.
- **Proposal:** reject prefixes shorter than 4 characters (exact ids always
  match). On a TTY, ask "Remove <name> [provider] and its history? [y/N]";
  `--yes` skips it. The sources do not say what a non-TTY `remove` without
  `--yes` should do: requiring `--yes` is safer but breaks existing scripts;
  decide and document it.
- **Tests / acceptance:** a 3-character prefix is rejected; a 4-character
  lowercase prefix resolves; declining the prompt leaves settings and history
  unchanged; `--yes` removes without prompting.
- **Relations:** the confirmation overlaps the BACKLOG entry "Add
  destructive-removal confirmation" (macOS). Save-before-purge ordering for
  `remove` is #104 (R-LNX-05).

### LNX-06 Managed (independent-login) connections on Linux

- **Status / severity / effort / platform:** open. TMP rates it medium (a new
  capability), effort L. Linux-testable with fake managed sources.
- **Sources:** TMP R-LNX-18 (PRODUCT-3). TMP backlog note (R-LNX-18): extends
  BACKLOG "Honest OAuth ownership (prefer first-party flows)"; BACKLOG never
  mentions Linux.
- **Problem and evidence:**
  - Linux OpenAI accounts copy the Codex CLI's rotating grant, which LLimit and
    Codex then invalidate for each other. Linux Claude accounts hold a bare access
    token that must be re-imported on expiry.
  - The daemon builds `.live()` without `managedOpenAI`
    (`LD/QuotaDaemon.swift:56`, `:379-382`). The managed Codex pieces are portable
    and already tested on Linux: `QC/CodexAccountService.swift:12`,
    `QC/CodexRPCSession.swift:2-5` (already has a Glibc branch),
    `QC/CodexProfileStore.swift:44-61`. The CLI has no connect command
    (`CLI/main.swift:59-78`).
- **Proposal:**
  - Phase 1 (Codex):
    1. Create `CodexAccountService(root: $XDG_DATA_HOME/LLimit/CodexProfiles)` and
       pass it to `.live(managedOpenAI:)`. The data directory otherwise holds only
       credential-free files, so the profile root must be `0700`.
    2. Add `llimit accounts connect <id>`: `beginLogin`, print the URL and try
       `xdg-open`, `finishLogin`, build credentials with
       `loginCredentials(for:identity:existingIdentities:)`, save under the
       settings lock, and `remove(profile)` on failure.
    3. The CLI must wait for or reap the app-server child before exiting; an
       interrupted short-lived process would otherwise orphan the operation
       record (verifier correction).
    4. Keep every AGENTS.md managed-Codex rule: profile directories `0700`,
       credential files `0600`, no adoption of global Codex/OpenCode tokens into
       managed accounts, verified identity before committing a login or
       publishing usage, nothing from app-server in logs, an exclusive durable
       operation record before launch that is removed only after the child exits,
       timeouts keep child and record, an orphaned record requires reconnecting
       into a fresh profile, and no namespace removal with a pending operation.
  - Phase 2 (Claude): an XDG Claude profile service that reads
    `.credentials.json` under a profile-specific `CLAUDE_CONFIG_DIR`, with
    `claude auth login` run in the user's terminal. Claude Code stays the sole
    owner of refresh-token rotation; match profile UUID plus verified account and
    organization UUIDs; a timed-out renewal keeps its process and pending marker
    and never replays the old token.
- **Tests / acceptance:** daemon wiring with a fake managed source;
  identity-collision rejection; cancel cleanup; an interrupted `connect` leaves a
  record that forces the next attempt into a fresh profile.
- **Relations:** BND-04 applies. The daemon and CLI must agree on paths (LNX-04).
  Cross-process ownership of fetches is COR-02/C05; imported OpenAI identity
  binding is MAIN C07. R-IDEA-04's phase 2 helps Linux accounts only once this
  lands. Reduces LNX-02's reimport burden.

### LNX-07 No CLI way to change the refresh interval

- **Status / severity / effort / platform:** open. TMP rates it medium, effort S.
  Linux-testable.
- **Sources:** TMP R-LNX-19 (PRODUCT-6; also LINUX-24 item 6).
- **Problem and evidence:** the CLI has no config command (`CLI/main.swift:402-420`).
  The only route is hand-editing the mode-600 credential file. A syntax error
  there blocks every save (`LD/QuotaDaemon.swift:106-108`) and, at baseline, made
  the daemon fall back to empty defaults. (TMP notes that a wrong-typed interval
  value is tolerated and does not trigger the fallback.) The daemon clamps to
  `AppSettings.refreshIntervalRange` = 15...180 minutes (`QC/Models.swift:1370`;
  `LD/QuotaDaemon.swift:571-577`). The timer unit hard-codes 30 minutes
  (`SD/llimit-refresh.timer:6`).
- **Proposal:** add `llimit config get [key]` and `llimit config set
  refresh-interval <minutes>` through `QuotaDaemon.setRefreshInterval(_:)`, which
  clamps to `refreshIntervalRange`, reports any clamping, and saves under the
  settings lock with a fresh load (or through #104's `SettingsTransaction` handle
  from `editingSettings`, the only route to settings mutations there). Whitelist
  Linux-relevant keys only. Say that the change applies after the current sleep,
  or wake the daemon with SIGUSR1 once COR-02 adds it. When the timer unit is
  active, print the `systemctl --user edit llimit-refresh.timer` override instead.
- **Tests / acceptance:** clamping at both ends; the value persists; the command
  refuses with a non-zero exit and leaves the file unchanged when settings are
  unreadable; timer mode prints the override hint.
- **Relations:** the recorded interval feeds LNX-01's stale threshold. LNX-14
  (timer ignores the interval), PRF-01, COR-02.

### LNX-08 Tray accessibility: disabled quota rows and full rebuilds

- **Status / severity / effort / platform:** partial. LEDGER: #105 implements the
  tray part of R-A11Y-04. Worktree check: #105 keeps content rows sensitive with
  no handler (`MenuRow.selectable`), adds `plan_menu_update` (unchanged models
  skip the menu, same-layout models are relabeled in place, others rebuild), and
  passes a status sentence with the failure count to `set_icon_full`, with tests
  for each. Remaining: confirm the PR head matches, verify on real desktops, and
  the dbusmenu tooltip gap. TMP rates it medium; remaining effort S. The model is
  Linux-testable; screen-reader behavior needs a manual check.
- **Sources:** TMP R-A11Y-04 (GAPB-3); LEDGER #105.
- **Problem and evidence:** at baseline header, metric and note rows were
  `set_sensitive(False)` (`TRAY/llimit_tray.py:288-297`), which GNOME, KDE and GTK
  skip during keyboard navigation and draw greyed out, so Orca and keyboard users
  could not reach any quota line. The menu was torn down and rebuilt every 60 s
  (`:276-299`, `:313-337`), which can reset focus in an open menu. dbusmenu
  ignores row tooltips, so metric `detail` tooltips never reach tray users.
- **Proposal:**
  1. Check the #105 PR head for the three pieces above.
  2. Manual check with Orca and the keyboard on GNOME (AppIndicator extension)
     and KDE: rows are reachable, focus survives a poll, the icon description is
     read.
  3. Move any information that matters out of row tooltips into row text, since
     dbusmenu drops tooltips. Activating a content row stays a no-op: a copy
     action would close the menu.
  4. Optional: watch the snapshot with `Gio.FileMonitor` instead of polling.
- **Tests / acceptance:** existing `test_menu_model.py` cases (content rows
  selectable; equal models do not rebuild) pass on the PR head; a recorded manual
  checklist covers the desktop checks.
- **Relations:** #64 (MAIN) reports "full error tooltips in tray"; under
  AppIndicator/dbusmenu those may never display (unverified). LNX-13's
  "Refreshing..." row must follow the same reachability rule.

### LNX-09 Tray icons are nearly invisible on light panels

- **Status / severity / effort / platform:** open; #105 deferred it. TMP rates it
  medium, effort S. Linux-testable (selection function).
- **Sources:** TMP R-LNX-16 (THEME-18); LEDGER #105 deferral.
- **Problem and evidence:** the five icons (`TRAY/icons/llimit-{ok,warning,
  critical,error,empty}.svg`, selected at `TRAY/llimit_tray.py:35-42,254-262`)
  use Catppuccin Mocha pastels. On white or `#EFF0F1`: ok 1.30-1.49:1, warning
  1.11-1.27:1, critical 2.03-2.32:1. The grey empty track is about 1.3-1.4:1
  everywhere; colored tracks reach 1.6-2.2:1 on dark panels. There is no light
  variant. The SVG comment "only the colour carries meaning" is wrong: arc length
  also varies by class.
- **Proposal:** ship a light set (Latte red `#d20f39`, 5.4:1; a darkened yellow
  such as `#a86b00`, about 4.4:1; track opacity 0.45). Add `--icon-variant
  auto|light|dark`; `auto` reads the freedesktop portal's `color-scheme`, then
  falls back to GTK settings. Make selection a pure `icon_name(status_class,
  variant)`. Fix the comment. These are status (danger) colors, not identity
  colors.
- **Tests / acceptance:** `icon_name` covers every class and variant; measured
  contrast of the light set on white and `#EFF0F1` is recorded.
- **Relations:** R-IDEA-06 (reset moment) keeps v1 text-only until this exists,
  and R-IDEA-17's tray SVG needs a light-panel track.

### LNX-10 Status output presets and --worst N

- **Status / severity / effort / platform:** partial. #108 adds `status --format
  <template> [--separator]`, repeatable `--account <id|provider>`, `--worst`,
  `--kind` and `--watch [<duration>]` (default 60 s), with tmux, starship and
  agent-wrapper examples; the JSON contract is untouched. Remaining: presets,
  `--worst N`, and aligning the template's `{class}` and account names with
  #105's StatusRenderer rules. TMP rates the item medium, original effort M;
  remaining S. Linux-testable.
- **Sources:** TMP R-LNX-20 (LINUX-16, PRODUCT-10); LEDGER #108 and its integration
  check; MAIN #88, #99.
  TMP backlog note (R-LNX-20): extends Product backlog #10 (redacted
  status-line companion); mark it partly done for Linux.
- **Problem and evidence:**
  - Baseline: `LD/StatusRenderer.swift:149-159` joins every account into one
    line; `CLI/main.swift:332-339` offers only text or JSON;
    `EX/polybar/llimit.sh:10-14` needs `jq`.
  - Worktree check: #108's placeholders are `{id} {name} {provider} {remaining}
    {metric} {kind} {reset} {class} {age} {stale}`; TMP's `{short}` is absent.
    `--worst` selects one account only.
  - Worktree check: #108's `StatusTemplate` copies the 15/40 class cutoffs as
    private constants "mirroring" `StatusRenderer`; TRACKING lists sharing them
    as a follow-up, and #108 deferred it until #95 and #105 land. Once LNX-01's
    class rules (failed, stale, all-failed) land, the template's `{class}` can
    disagree with the JSON `class`.
  - Integration check (#105 + #108): with both merged, the template `{class}`
    does not apply #105's rule that failed or stale accounts raise the class to
    `warning` at most. #108's `StatusTemplate` and `HeadroomRanking` name an
    account with no usage by its provider display name and ignore #105's
    `ProviderFailure.title`. Staleness also disagrees (2 h versus 6 h; LNX-01).
- **Proposal:** add presets `short`, `tmux` (segments wrapped in `#[fg=...]` by
  class) and `i3blocks`; add `--worst N`, ordered by R-NOV-03's
  `HeadroomRanking` in QuotaCore; decide whether `{short}` is still wanted. Derive
  `{class}` from the same function as the JSON class (R-UX-09's `QuotaSeverity`),
  including #105's `warning` cap. Name accounts with no usage through the same
  title fallback as `status` (#105's `ProviderFailure.title`).
- **Tests / acceptance:** golden output per preset; `--worst 2` returns the two
  lowest in ranking order with ties broken the same way as `pick`; the template
  `{class}` equals the JSON `class` for failed, stale and mixed fixtures; a
  failure-only account has the same name in the template, `pick` and `status`;
  existing checks (unknown placeholders left literal, empty snapshot, "≈" kept on
  estimates) still pass.
- **Relations:** OVERLAP: #99 (MAIN) adds `status --watch [seconds]` with ANSI
  clear/home repaint, and #88 (MAIN) adds `llimit compact`; keep one of each.
  #108's `llimit check` (exits 0 ok, 1 below minimum, 2 stale or failing, 3 no
  data, 64 usage) conflicts with #97's `check --below/--stale-hours` (exit 1 with
  reasons). The rejected `llimit top` idea (RJ-IDEA-TOP) is covered by `--watch`.

### LNX-11 CLI gaps: doctor, strict flags, JSON listing, completions

- **Status / severity / effort / platform:** partial. #83 (MAIN-reported) adds
  `llimit version`/`--version`/`-v` and `accounts list` data-state summaries from
  the snapshot-only `StatusRenderer.accountQuotaSummary` (worst remaining
  percentage, estimate marker, balance, failure kind, or no data). Worktree check:
  #108 rejects unknown `status` options, so `status --jsno` no longer prints text.
  TMP rates the item low, effort M. Linux-testable.
- **Sources:** TMP R-LNX-23 (LINUX-24, PRODUCT-17); MAIN L11, #83 report. TMP
  backlog note (R-LNX-23): extends BACKLOG "Platform polish (version/build,
  diagnostics export)".
- **Problem and evidence:** baseline `CLI/main.swift:22-43,53-57,99-127,397-420`:
  usage goes to stdout with exit 1; `refresh` and `daemon` ignore unknown flags;
  `--set` keys are neither validated nor listed, so a typo is saved as a junk key
  while the real field is still prompted; no `accounts list --json`; no shell
  completions; `:90-96` prints "ready" for accounts whose token has expired or
  that fail every refresh. Source check:
  `Packages/LLimitd/packaging/build-deb.sh:23` sets only the package version
  (default `0.0.0~dev`); whether #83's binary embeds the release version is
  unverified.
- **Proposal:**
  1. `llimit doctor`: settings readable, owned by the user, mode `0600`,
     directory `0700`; snapshot age against the interval; `systemctl --user
     is-active` for the units; the XDG comparison (LNX-04); whether PATH's
     `llimit` matches the unit's `ExecStart`; per-account failure kinds. Exit
     non-zero on problems; print names and kinds only. Build it as a pure
     `DoctorReport` over injected paths and snapshots.
  2. Reject unknown flags for every command; usage errors go to stderr. TMP
     proposes exit 2, but #108's `check` uses 2 for "stale or failing" and 64
     (EX_USAGE) for usage errors; use 64 everywhere.
  3. `accounts fields <provider>`, and validate `--set` keys against
     `credentialFields` in `add` and #104's `update`.
  4. `accounts list --json`: stable and credential-free (id, provider, name,
     enabled, missing fields, last refresh status), reusing
     `accountQuotaSummary`.
  5. `completions bash|zsh|fish`.
  6. `daemon --quiet`; keep JSON output clean.
  7. Replace "ready" with the data state, including expiry (LNX-02).
  8. Order accounts across commands by severity and recency using COR-06's
     timestamps.
  9. Verify that the release embeds the version (TMP proposed a CI-generated
     `Version.swift` defaulting to "dev") rather than rebuilding #83's flags.
  10. Move argument parsing into LLimitdCore so it is unit-testable.
- **Tests / acceptance:** parser tests (unknown flags, usage exit code); a pure
  `DoctorReport` builder test per check; `accounts list --json` schema test that
  finds no credential substrings; the packaged binary prints the tag version.
- **Relations:** LNX-04, LNX-02, LNX-12 (exit codes), COR-06.

### LNX-12 `llimit refresh` always exits 0 and logs to stdout

- **Status / severity / effort / platform:** open. TMP rates it low, effort S.
  Linux-testable.
- **Sources:** TMP R-LNX-14 (LINUX-21). TMP backlog note (R-LNX-14): extends
  BACKLOG "Count only genuinely fresh providers in refresh summaries".
- **Problem and evidence:** `CLI/main.swift:316-330` prints
  `humanReadable(daemon.snapshot)` after `refreshNow()` and exits 0. With no
  accounts (`LD/QuotaDaemon.swift:271-279`), every account failing, or a failed
  save, it prints the previous snapshot as if fresh. The default log sink writes
  `[llimitd]` lines to stdout (`:58-62`), mixed with the status output. The
  summary (`:311-327`) counts carried accounts as refreshed and never names the
  failing ones. Since #104, an unreadable settings file already exits 1.
- **Proposal:** have `refreshNow` return a `RefreshOutcome` (refreshed, failed
  with kind, carried, no accounts, save error). Exit 0 on success, 3 on partial
  failure, 1 for no accounts or a save failure; document the codes and add
  `--json`. Send logs to stderr. Log one line per failed account
  (`account=<name> provider=<id> kind=<kind>`), never bodies.
- **Tests / acceptance:** `RefreshOutcome` cases for each state; CLI exit codes;
  stdout holds only the status output.
- **Relations:** exit 3 means "no data" in #108's `check`; document per command
  or align. Once COR-02 makes the daemon the sole fetcher, `refresh` signals it
  and must still report the cycle's outcome. #110 deferred alerts from `llimit
  refresh` and the timer units (DEBT-06). LNX-13 can use these codes.

### LNX-13 Manual refresh from the tray or waybar gives no feedback

- **Status / severity / effort / platform:** open. TMP rates it low, effort S.
  Linux-testable (tray model).
- **Sources:** TMP R-LNX-15 (LINUX-26).
- **Problem and evidence:** the tray fires a detached `llimit refresh`
  (`TRAY/llimit_tray.py:200-212`, `:268-270`) and shows nothing until its next
  60 s poll (`:311-337`); repeated clicks start parallel fetches (see COR-02).
  Its docstring wrongly says the daemon holds the settings lock during refresh.
  Waybar re-runs `exec` right after `on-click`, before the refresh finishes, then
  waits its 300 s interval (`EX/waybar/llimit.jsonc:16-18`).
- **Proposal:** run the refresh on a worker thread (`subprocess.run(...,
  timeout=120)`), show a "Refreshing..." row (TMP says disabled; keep it
  reachable per LNX-08), ignore clicks while it runs, and poll when it finishes;
  show a failure row from LNX-12's exit code. Fix the docstring. Waybar example:
  `"signal": 8` and `"on-click": "llimit refresh >/dev/null; pkill -RTMIN+8
  waybar"`.
- **Tests / acceptance:** a pure "refreshing" row variant; a second click while
  running starts no second process.
- **Relations:** COR-02 (daemon as sole fetcher: the tray would signal the daemon
  and wait for `generatedAt` to advance); LNX-08's relabel path; LNX-12.

### LNX-14 systemd unit correctness

- **Status / severity / effort / platform:** open. TMP rates it low (verifier
  correction), effort S. Not Linux-unit-testable; verify with systemd.
- **Sources:** TMP R-LNX-12 (LINUX-13); LEDGER #110 deferral.
- **Problem and evidence:**
  - `SD/llimit.service:3-4` and `SD/llimit-refresh.service:3-4` order after
    `network-online.target`, which the user manager does not have, so the
    ordering is a no-op. After an all-network failure nothing retries for 30 to
    180 minutes (R-BUG-22).
  - `SD/llimit-refresh.timer:5-7` uses `OnBootSec=2min`, `OnUnitActiveSec=30min`
    and `Persistent=true`; `Persistent=` works only with `OnCalendar=`, so runs
    missed during suspend are not caught up. The 30 minutes ignore the
    configured interval (PRF-01; `SD/install.sh:9` documents "every 30 min").
  - `SD/llimit-refresh.service` (Type=oneshot) has no start timeout by default.
  - #110 deferred alerts from the timer units (DEBT-06): timer users get no
    threshold notifications.
- **Proposal:** drop the network-online lines or comment that they are no-ops,
  and rely on the scheduler retry (R-BUG-22/PRF-01). Timer: `OnCalendar=*:0/30`,
  `Persistent=true`, `RandomizedDelaySec=60`, `OnStartupSec=2min`, and document
  that it ignores the configured interval (LNX-07 prints the override). Add
  `TimeoutStartSec=5min` to the oneshot. Optionally run `systemd-analyze verify`
  in CI; it would not flag the no-op.
- **Tests / acceptance:** `systemd-analyze --user verify` passes; a manual
  suspend across a timer slot triggers a catch-up run on resume; a hung oneshot
  is stopped after 5 minutes.
- **Relations:** unit hardening is SEC-02; installer restart of active services
  (MAIN L05) is in Build; DEBT-06; PRF-01.

### LNX-15 The tray unit restarts forever without GTK bindings

- **Status / severity / effort / platform:** open. TMP rates it low, effort S.
  Linux-testable.
- **Sources:** TMP R-LNX-13 (LINUX-20).
- **Problem and evidence:** the tray returns 1 when PyGObject or the typelibs
  are missing (`TRAY/llimit_tray.py:215-250`); the bindings are only Suggests
  (`Packages/LLimitd/packaging/build-deb.sh:92`). `SD/llimit-tray.service:9-12` uses
  `Restart=on-failure` with `RestartSec=10s`, which never reaches the default
  start limit, so the journal gets the same message every 10 s indefinitely.
- **Proposal:** exit 78 (EX_CONFIG) for both missing-binding paths and add
  `RestartPreventExitStatus=78`. Optionally add `StartLimitIntervalSec=5min` and
  `StartLimitBurst=5`. `install.sh` copies the unit through `sed`, so the change
  reaches `~/.local` installs too.
- **Tests / acceptance:** patching the `gi` import to fail, and separately the
  typelib `require_version`, makes `main` return 78.
- **Relations:** packaging dependencies are in Build.

### LNX-16 Bar examples color everything by the worst account; eww ignores accounts

- **Status / severity / effort / platform:** open. TMP rates it low, effort S.
  Linux-testable.
- **Sources:** TMP R-LNX-17 (THEME-19).
- **Problem and evidence:** account objects carry no class
  (`LD/StatusRenderer.swift:125-141`); `class` comes from the aggregate minimum
  (`:167-175`), so waybar and polybar color every account by the worst one
  (`EX/waybar/llimit.css:14-33`). The eww example (`EX/eww/eww.yuck:49-53`)
  ignores the `accounts` array that `EX/README.md:43-47` advertises.
- **Proposal:** add an additive per-account `class` using R-UX-09's shared
  thresholds and LNX-01's failed/stale rules. Make eww iterate accounts:
  `(for acct in {llimit.accounts} (label :class "llimit-seg ${acct.class}" :text
  "${acct.name} ${acct.remainingPercent}%"))` with matching SCSS, handling the
  `null` percentage of failure-only and amount-only accounts. Document that
  waybar and polybar color the whole module by the worst class.
- **Tests / acceptance:** per-account classes for a mixed 82%/5% snapshot; a
  failed account's class follows LNX-01's cap.
- **Relations:** depends on LNX-01's chosen keys. R-IDEA-17 extends this with
  per-account identity colors and keeps `class` semantics unchanged.

### LNX-17 Tray headline for amount-only accounts, and a tray reset radar

- **Status / severity / effort / platform:** open. MAIN does not rate it.
  Linux-testable.
- **Sources:** MAIN L12, #51 report.
- **Problem and evidence:** source check: `format_account_header`
  (`TRAY/llimit_tray.py:93-109`) shows a percentage only when `remainingPercent`
  is an integer and "unlimited" when every metric is unlimited; otherwise only
  the name. An amount-only account, such as credits-only Cline, has no headline.
  The tray has no reset section at baseline.
- **Proposal:** show the reported amount in the header without a percentage,
  using the same `label value` text the bar's `text` segment builds from
  `usageLine`; never fabricate a percentage for a balance. Add a "Next resets"
  section from #51's `QuotaSnapshot.upcomingResets(now:within:)` (or `llimit
  resets --json`): chronological absolute server resets with account names and
  reported/estimated labels, a stale-schedule indication (#51 reports an
  older-than-one-day policy), and passed dates shown as "reset due" until a
  fresh fetch observes the replenishment.
- **Tests / acceptance:** a credits-only Cline header shows `$4.25`; missing
  snapshot data is distinct from an empty schedule (LES-01); resets are in
  absolute order; stale schedules are labeled.
- **Relations:** PRD-07 (reset radar), LES-01, LNX-16 (null percentages), #105
  and #50 (`resetAt` in the JSON). #88 (MAIN) also reports a reset listing next
  to `llimit compact`; check it against #51 before adding a third.

## Build, release, packaging and documentation

This section covers CI, release, Debian packaging, the installer, and documentation accuracy. The macos-14 retirement on Nov 2, 2026 is the only dated deadline. Line numbers refer to baseline 2d6ac1e. Workflow, script and repository-root paths are written in full. TMP cites AGENTS.md lines (:207, :252) that do not match the baseline file, so the baseline lines are given instead.

### BLD-01 macOS CI on macos-14 is retired on Nov 2, 2026
- **Status / severity / effort / platform:** partial. #92 (`opus/release-unblock`) moves `ci.yml` and `release.yml` to `macos-15` and pins `ubuntu-24.04`. Three items remain: run the geometry script in the Linux job, add the three geometry tests (#92's final head `53350b7` does not add them; see the assembly notes), and merge #92 before Nov 2 (ORD-02). Severity: high (TMP). Effort: XS for the remainder. Platform: CI. The remaining step is Linux-testable, and the script already passes on Linux (16 checks).
- **Sources:** TMP R-BLD-01 (BUILD-1, plus the MENU-21 coverage gaps that survived refutation).
- **Problem and evidence:**
  - At baseline, `.github/workflows/ci.yml:20` and `.github/workflows/release.yml:22` use `runs-on: macos-14`. actions/runner-images#13518 makes macOS 14 unsupported from Nov 2, 2026. Scheduled brownouts fail jobs on Oct 5, 12, 16, 19, 23, 26, 29 and 30, from 14:00 to 24:00 UTC. From Nov 2, no PR can pass its macOS job and no release can publish.
  - `release-linux` has `needs: release` (`release.yml:94`), so a tag pushed during a brownout publishes neither platform (BLD-03). This holds until #92 merges.
  - `scripts/test-panel-geometry.sh` runs only in the macOS job (`ci.yml:50-51`). It compiles `APP/MenuBarPanelGeometry.swift` standalone with `swiftc` and needs no AppKit.
  - Run 37363625985 is not brownout evidence: it failed to acquire hosted runners for both the macOS and the Ubuntu jobs. The retirement date alone justifies the change. The rejected claims are listed in REF-03.
- **Proposal:**
  - Merge #92 before Nov 2, preferably before the next brownout on Oct 12. Its `macos-15` arm64 image ships Xcode 16.2 (16.4 is the default), so the existing 16.2 pin keeps working.
  - Add `scripts/test-panel-geometry.sh` to the `linux-test` job, which already installs Swift, and keep it in the macOS job.
  - Add TMP's three geometry tests to `scripts/tests/MenuBarPanelGeometryTests.swift` (listed in ORD-02).
  - Optional (TMP): add a matrix of Xcode 16.2 and 26.x.
  - TMP asked for `BACKLOG.md:16-17` ("Restore runnable CI") to become "Migrate off macos-14 before Nov 2, 2026". That edit is tracked with R-BKL-01. #92's final head (`53350b7`) leaves `BACKLOG.md` identical to baseline, so it is still open.
- **Tests / acceptance:** a PR run on `macos-15` where all three harness steps pass (#92), and a Linux job log that shows the geometry checks passing.
- **Relations:** BLD-03 (Linux publication depends on the macOS job). BLD-08 (#92 deferred CI toolchain caching). #92's other deferrals belong to the security cluster for R-SEC-01/R-SEC-03, not to this section: checksum or PGP verification of the toolchain through a shared composite action, restoring echo on signal, Musl branches in the `LD/SettingsLock.swift` and `CLI/main.swift` import blocks, and a v1.0.1 release note about scrollback. Measured: #92 merges cleanly with every other PR of this pass, including the `CLI/main.swift` edits in #104, #108 and #110 (ledger table 1).

### BLD-02 Signed, notarized distribution that supports widgets
- **Status / severity / effort / platform:** open. Severity: high (MAIN). Effort: L (estimate; MAIN gives none). It needs more than one PR, plus an Apple Developer ID and repository secrets, which are owner decisions. Platform: macOS-only.
- **Sources:** MAIN AM-BUILD-1 ("Widget-capable distribution").
- **Problem and evidence:**
  - `.github/workflows/release.yml:37-45` builds with `CODE_SIGNING_ALLOWED=NO`. `:47-55` then runs `codesign --force --deep --sign -` (ad-hoc) with no entitlements and no notarization, and there are no local entitlement or notarization gates. The TMP verifier notes that releases are therefore "ad-hoc signed without App Group", so the widgets of an official release cannot share the App Group snapshot.
  - Gatekeeper warns on first launch. The release body (`release.yml:82-89`) tells users to right-click Open or run `xattr -dr com.apple.quarantine`.
  - The cdhash changes with every ad-hoc release, so a Claude profile's Keychain approval is lost after an update (TMP R-UX-13; the recurrence part of PRV-07). TMP R-UX-13 calls Developer ID signing "the only fix that keeps approval across updates".
  - TMP R-IDEA-02 also flags, unverified, that ad-hoc builds may not get notification authorization.
  - `RELEASING.md:64-79` documents signing secrets that `release.yml` never reads (BLD-07). `RELEASING.md:33-43` documents a local Developer ID and notarization path through the external `lkm-build` engine. Unverified: neither source exercised it.
- **Proposal:**
  - Scope Developer ID signing and provisioning (the App Group in both the app and the appex), matched monotonic app and extension versions (BLD-04), the hardened runtime, notarization and stapling, and clean-Mac validation of shared data.
  - Gate nested signatures, entitlements, architectures and Gatekeeper before publishing.
  - Smoke artifacts that remain unsupported (ad-hoc builds) must not claim working widget distribution.
  - Preserve the AGENTS.md "Widget registration" rules: installed-only LaunchServices registration (`REGISTER_WITH_LAUNCH_SERVICES: NO`), the recursive `lsregister` cleanup, the `chronod` restart and the NotificationCenter restart gates in `scripts/build.sh --install`.
  - The host app stays unsandboxed and the widget stays sandboxed. Direct Developer ID distribution with an App Group is compatible with that (`RELEASING.md:81-83`).
  - Keep signing secrets in the gated publish or signing job (BLD-03).
- **Tests / acceptance:** on a release artifact, `codesign --verify --deep --strict` passes. The entitlement dump shows the App Group in both the app and the appex, `lipo -archs` gives the expected architectures, `spctl --assess` accepts the app and `stapler validate` succeeds. The app and appex `CFBundleVersion` match. On a clean Mac, the installed widgets display the app's snapshot.
- **Relations:** BLD-04 (matched monotonic versions are a precondition). BLD-03 (publish job and secrets scope). BLD-07 (RELEASING.md must describe the real path). It unblocks PRV-07's recurrence, IDEA-03 (the nested `llimit` helper must be signed with the hardened runtime and notarized with the bundle) and PRD-13 (a verified signed, Sparkle-style update path).

### BLD-03 A release can go live with only some artifacts
- **Status / severity / effort / platform:** open. Severity: medium (TMP, which lists it in the next tier rather than the shortlist). Effort: M. Platform: CI (workflow only, not testable with `swift test`).
- **Sources:** TMP R-BLD-04 (BUILD-5). TMP backlog note (R-BLD-04): extends BACKLOG "CI structure and release policy (split read-only build from protected publication)".
- **Problem and evidence:**
  - The macOS job's "Publish GitHub Release" step (`.github/workflows/release.yml:74-89`, `softprops/action-gh-release@v3`) creates a non-draft release, marked Latest, before the `.deb` is built. `release-linux` (`:91`) then appends to it (`:94` `needs: release`, `:129-133`).
  - A macOS failure blocks the `.deb`. A Linux failure leaves a Latest release without the `.deb`, although `README.md:12-13` and `:33` promise one.
  - TMP R-BLD-02 gives a concrete case: the musl build broke after b47497b, so the next tag would have published a release without a `.deb`. #92 fixes that build, but not the structure that let it happen.
  - No tests run before publishing.
  - `release.yml:11-12` grants `contents: write` to every job.
- **Proposal:**
  - Split the workflow into `build-macos` and `build-linux` jobs that only upload artifacts and run with `contents: read`.
  - Add a `publish` job with `needs: [build-macos, build-linux]` and `contents: write`. It downloads both artifacts and creates the release, optionally as a draft that is published only after every asset is attached.
  - Run `swift test` and the harness scripts before uploading.
  - Set read-only permissions at the top of the workflow (R-SEC-02).
  - MAIN treats tested-main release gating as a scoped release follow-up, not new global policy. Checksums and attestations are another such follow-up (BLD-11), and the publish job is where they would be generated.
  - Leave the release concurrency group unchanged (BLD-09).
- **Tests / acceptance:** in a test-tag run on a fork, a forced failure in either build job leaves no public release (at most a draft). A successful run publishes one release with the `.dmg`, `.zip` and every `.deb` at once. Only `publish` holds `contents: write`.
- **Relations:** BLD-01 (the chained jobs also carry the brownout risk). BLD-02 (where the signing secrets live). BLD-05 (an arm64 leg joins `build-linux`). BLD-07 (the docs must describe the new job layout). REF-15: a tag pushed with `GITHUB_TOKEN` does not trigger `release.yml`. The real risk of a broad write token is direct use of the Releases API or branch pushes.

### BLD-04 Releases stamp CFBundleVersion from github.run_number
- **Status / severity / effort / platform:** open. Severity: medium (TMP). The verifier notes that the practical impact is limited while releases are ad-hoc signed without an App Group. Effort: S. Platform: macOS-only.
- **Sources:** TMP R-BLD-03 (BUILD-4).
- **Problem and evidence:**
  - `.github/workflows/release.yml:44` passes `CURRENT_PROJECT_VERSION="${{ github.run_number }}"`. As a result, LLimit-1.0.1.zip has `CFBundleVersion` 2 in both the app and the widget extension, while `project.yml` was at 20 at that tag. `project.yml:41` is now at 37.
  - AGENTS.md:275-276 requires a single, monotonically increasing `CURRENT_PROJECT_VERSION` for the app and extension, or WidgetKit keeps stale extensions. Installing a release over a dev build lowers the version.
  - `lkm-release` bumps only `MARKETING_VERSION` (see `scripts/release.sh:4-15`).
  - `CICD.md:84-85` documents the run-number behavior, and `RELEASING.md:52` wrongly claims that both versions are bumped (BLD-07).
- **Proposal:**
  - Drop the `CURRENT_PROJECT_VERSION` override.
  - Add a release gate that fails when the tag differs from `MARKETING_VERSION`, or when the app and appex `CFBundleVersion` differ. Copy the check from `scripts/build.sh:98-103`.
  - Set `RELEASE_POST_BUMP` in `scripts/release.sh` so that `CURRENT_PROJECT_VERSION` is bumped. This hook belongs to the external `lkm-release`, whose contract is not pinned (BLD-08).
- **Tests / acceptance:** a tagged build's app and appex both carry `project.yml`'s `CURRENT_PROJECT_VERSION`. A tag that does not match `MARKETING_VERSION` fails before anything is published. Running `release.sh` leaves a higher `CURRENT_PROJECT_VERSION` committed in both `project.yml` and the generated project.
- **Relations:** BLD-02 (matched monotonic versions are part of a signed distribution). BLD-07 (CICD.md and RELEASING.md wording). BLD-08 (`lkm-release` contract).

### BLD-05 Debian package: upgrades, metadata, trust roots, arm64, smoke test
- **Status / severity / effort / platform:** open. Severity: low (TMP); MAIN does not rate it. Effort: S (TMP) for the packaging metadata. The smoke-test and arm64 legs add CI work. Platform: Linux-only. It is verifiable on a Linux runner with `dpkg-deb`, `lintian` and `file`, not with `swift test`.
- **Sources:** TMP R-BLD-06 (LINUX-22, BUILD-17); MAIN L05, L07, L10.
- **Problem and evidence:**
  - **Upgrades keep the old daemon running.** The `.deb` has no maintainer scripts: `Packages/LLimitd/packaging/build-deb.sh:83-108` writes only `DEBIAN/control`. After an upgrade, the running daemon keeps executing the replaced binary. For manual installs, `Packages/LLimitd/systemd/install.sh:44-49` replaces the binary and units, and `:64-76` runs `systemctl --user enable --now`. That call does not restart a daemon or tray that is already active (L05).
  - **Trust roots are optional.** `build-deb.sh:91` declares only `Recommends: ca-certificates` (the control block is at `:84-108`, which MAIN cites as `:85-92`), although `:13` says TLS needs it. An install without recommendations fails on TLS trust (L07).
  - **Debian metadata.** There is no `copyright` and no `changelog.Debian.gz`, which are lintian errors. The description (`:93-98`, provider list at `:94-95`) names 7 of the 12 providers (BLD-10). The layout comment (`:15-19`) omits `llimit-tray` and `/usr/share/llimit/tray`.
  - **amd64 only.** `build-deb.sh:2`, `:24`, `:89` and `:110`, `.github/workflows/release.yml:124` and `:133`, and `README.md:13`, `:33` and `:179` ("Any x86_64 distro") all assume amd64, although the 6.2.3 static SDK also ships an aarch64 sysroot.
  - **No smoke test.** The release (`release.yml:123-133`) never runs the packaged binary; only source tests run (L10).
  - `install.sh:36-41` defaults to `.build/release/llimit` and suggests a dynamically linked build.
- **Proposal:**
  - **.deb upgrades:** add a `postinst` that prints `systemctl --user daemon-reload && systemctl --user try-restart llimit.service`. Root should not restart user units.
  - **install.sh upgrades:** after replacing the files and reloading, restart services that are already active (daemon and, when installed, the tray).
  - Change `ca-certificates` to `Depends`.
  - Ship `copyright` and `changelog.Debian.gz`. Make the description generic (BLD-10), and fix the layout comment.
  - Parameterize the architecture: SDK triple, binary path, `Architecture:` and the file name. Add an aarch64 build leg. MAIN says "if scoped". It depends on R-BLD-02, which #92 fixes.
  - In `install.sh` and the docs, recommend `--static-swift-stdlib`.
  - In CI, extend #92's "Linux (static .deb)" job, which already asserts that the packaged binary is statically linked, with `lintian`, `dpkg-deb -I` and `file`. Add fixture-XDG smoke checks on the installed artifact: binary, dependencies, units, GTK-free tray output, and the installed CLI flags.
- **Tests / acceptance:**
  - First-install and upgrade fixtures verify the running PID and version, and the optional tray behavior (L05).
  - A minimal install without recommendations reaches HTTP responses rather than a TLS trust failure. The control metadata and the shipped binary are inspected (L07).
  - lintian is clean. The smoke job exercises the installed binary against a fixture `XDG_DATA_HOME` snapshot, plus an arm64 `.deb` if scoped (L10).
- **Relations:**
  - BLD-01 and #92 (the static `.deb` CI job is where these checks go). BLD-03 (`build-linux` matrix and publish). BLD-10 (description). BLD-06 (README install text).
  - Same files as MAIN L06: the installer ignores custom XDG roots, emits unquoted home paths and mishandles `&` in its sed replacement (`install.sh:44-49`, `:59-61`).
  - TMP R-LNX-13: the tray bindings are only `Suggests` (`build-deb.sh:92`), so the tray unit restarts forever. TMP R-LNX-12 covers unit ordering and timeouts.
  - TMP R-LNX-23 (`build-deb.sh:23` default version) and the reported #83 `llimit version`, which the PID/version check can reuse.

### BLD-06 Documented Linux install commands and contract docs
- **Status / severity / effort / platform:** open. Severity: low (TMP, because the not-found error prints the right command). Effort: S. Platform: Linux docs. A contract-keys test in LLimitd makes it partly Linux-testable.
- **Sources:** TMP R-BLD-05 (BUILD-10, LINUX-23); MAIN L08.
- **Problem and evidence:**
  - `README.md:214-215` builds a debug binary (`swift build --package-path Packages/LLimitd`, output in `.build/debug/llimit`). `Packages/LLimitd/systemd/install.sh:36` defaults to `.build/release/llimit`, so it stops at `:38-41` (the message prints the correct build command).
  - `Packages/LLimitd/README.md:89` documents `install.sh -- --timer`. The parser (`install.sh:22-26`) exits 2 with "unknown option: --". Both reviews reproduced this; MAIN reproduced it before any install.
  - The contract table (`Packages/LLimitd/examples/README.md:21-37`) is incomplete:
    - It omits the per-account `metrics` array (`LD/StatusRenderer.swift:134`, whose objects carry `id`, `label`, `unlimited`, `remainingPercent`, `estimated`, `resetIn`, `usageLine` and `detail` at `:82-99`), the per-account `warning` (`:137`), and the per-account and top-level `estimated` keys (`:140`, `:200`).
    - It describes `error` as "every account failed to refresh". In fact `error` applies only when no account has usage and failures exist (`:163-164`), and `empty` also covers a snapshot that has no accounts.
    - It omits the warning-text elevation from `ok` to `warning` (`:179-181`).
  - `UBUNTU_PORT.md` is dated: the test count (`:5`, "97 tests", against 416 QuotaCore tests at baseline), the signal-handler claim (`:138-140`, see R-LNX-11), and the slot count (`:185`, "8 provider-tile slots"; #48 made it twelve).
  - The `TRAY/llimit_tray.py:201-203` docstring says the daemon holds the settings lock during its refresh. It does not: the lock is held only around the load and the merge-save, never across a network fetch.
- **Proposal:**
  - Change the README to `swift build -c release --package-path Packages/LLimitd`, with output at `Packages/LLimitd/.build/release/llimit`.
  - Document `install.sh --timer`. Optionally, accept a literal `--` in the script.
  - Note that `--tray` needs `python3-gi`.
  - Regenerate the contract table from the renderer. Do it after the LNX-01 and LED-15 keys settle.
  - Mark `UBUNTU_PORT.md` as a historical assessment, and fix the tray docstring.
- **Tests / acceptance:** an LLimitd test asserts that the documented key set equals the emitted keys. The documented commands, including the `install.sh --timer` parser path, run successfully (L08).
- **Relations:**
  - LNX-01 and LED-15: additive keys from #105, #64 and #50 (failure keys, `resetAt`, `fetchedAt`/`ageSeconds`). #108 adds `status --format`.
  - BLD-05 (README Linux install). BLD-07 (the README release line). TMP R-LNX-01 (`examples/README.md:21-37` misstates `error`). TMP R-LNX-11 (the `CLI/main.swift` comments repeat the SIGTERM claim).

### BLD-07 Release and CI documentation
- **Status / severity / effort / platform:** open. Severity: the sources disagree. TMP rates R-BLD-08 and R-BLD-09 low, and MAIN rates "Executable docs" medium. Effort: S. Platform: docs only.
- **Sources:** MAIN AM-BUILD-2; TMP R-BLD-08 (BUILD-11) and R-BLD-09 (BUILD-12).
- **Problem and evidence:**
  - **CICD.md describes a different CI.**
    - `CICD.md:3-6` and `:13-17` claim two macOS-only workflows that need no secrets, and `:113-116` repeats "None are required". In fact there are three workflows: `zai-code-review.yml` reads `ZAI_API_KEY` (`.github/workflows/zai-code-review.yml:39`) and skips without it (`:134-135`). `ci.yml` also has two Ubuntu jobs (`linux-test` `:67-90`, `tray-test` `:92-102`), and `release.yml:91-133` is a Linux release job. MAIN: CICD.md omits the Linux, tray and review workflows.
    - The step list (`:22-32`) omits the three harness steps (`ci.yml:47-54`) and the first QuotaCore run.
    - The local reproduction (`:59-65`) writes `TestResults.xcresult` into the repository root (`:63`), so a second run fails, and `.gitignore` does not ignore `*.xcresult`.
    - The release section (`:73-79`) tags by hand, bypassing `scripts/release.sh`.
    - `:84-85` documents the run-number build version (BLD-04), and `:34-35` documents the cancellation behavior (BLD-09).
  - **RELEASING.md and the README misstate `scripts/release.sh`.**
    - `RELEASING.md:12` and `:48` say the script pushes. `lkm-release` pushes only with `--push` (`scripts/release.sh:2-15`).
    - `:49` documents `--local`, which dies with "unknown option".
    - `:52` claims that both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are bumped; only `MARKETING_VERSION` is.
    - `:58` mentions a manual "Run workflow" dispatch that does not exist (`release.yml:3-5` triggers only on `v*` tags).
    - `:61` says artifacts come from `dist/`; the workflow writes them to `$RUNNER_TEMP` (`release.yml:59-60`).
    - `:64-79` describes secret-driven signing that the workflow does not implement.
    - The `.deb` is not mentioned.
    - `README.md:226` (`./scripts/release.sh 0.3.0  # bump version, tag, push`) omits `--push`.
- **Proposal:**
  - Rewrite CICD.md from the current workflows, listing the local equivalents: both `swift test` runs, the tray `unittest`, and the three `scripts/test-*.sh`.
  - In the local reproduction, use `-resultBundlePath "$(mktemp -d)/TestResults.xcresult"`, and add `*.xcresult` to `.gitignore`.
  - Point the release section at `scripts/release.sh`.
  - In RELEASING.md:
    - document `release.sh X.Y.Z` versus `--push`, plus `--check`;
    - explain that the tag drives `MARKETING_VERSION`;
    - list both macOS artifacts and the `.deb`;
    - remove the dispatch and secret-signing text until BLD-02 makes them real.
  - Change `README.md:226` to `./scripts/release.sh 0.3.0 --push`.
  - MAIN: reconcile the exact commands with parser and artifact checks, and retire resolved backlog entries without deleting the evidence that remains.
- **Tests / acceptance:** every documented command runs as written against the current parser (`--local` is gone, `--push` is present). The documented artifact names match what `release.yml` attaches. A repeated local CI reproduction succeeds.
- **Relations:** BLD-03 and BLD-04 change the release facts, so update the docs after them, or together with them. BLD-01 (runner names). BLD-02 (signing docs). BLD-09 (the concurrency note). BLD-11 (ignore result bundles; TMP notes that the `*.xcresult` part duplicates BACKLOG "Repository policy"). TMP R-BKL-01 (BACKLOG validation state and CI items). BACKLOG "Supply chain, artifacts, and documentation" asks to describe the one executable release path exactly.

### BLD-08 CI coverage: LLimitd on macOS, XcodeGen drift, toolchains
- **Status / severity / effort / platform:** open. Severity: the sources disagree. TMP rates R-BLD-10 and R-BLD-11 low, and MAIN rates "Focused CI" medium. Effort: S per TMP item; MAIN's wider scope is M. Platform: CI. The LLimitd-on-macOS step needs a macOS runner.
- **Sources:** MAIN AM-BUILD-3; TMP R-BLD-10 (BUILD-13) and R-BLD-11 (BUILD-16); LEDGER #110 note. TMP backlog note (R-BLD-11): extends BACKLOG "Canonical project generation".
- **Problem and evidence:**
  - **LLimitd never builds on macOS.** AGENTS.md:51-52 and `:341` say LLimitd's tests run in macOS CI, but the macOS job (`.github/workflows/ci.yml:17-65`) never builds LLimitd. Its Darwin branches therefore never compile in CI: the termios path in `readField` (`CLI/main.swift`), the `LD/SettingsLock.swift` import, and #110's `AlertDelivery` Darwin branches.
  - **Toolchain order and duplicate runs.** The macOS job runs QuotaCore `swift test` (`ci.yml:23-25`) before "Select Xcode" (`:27-30`), so that first run uses the runner's default toolchain. It runs the same tests again at `:56-57`.
  - **XcodeGen drift.** `project.yml:3` sets `minimumXcodeGenVersion: 2.38.0`, but `LLimit.xcodeproj/project.pbxproj:6` has `objectVersion = 77`, which needs XcodeGen 2.44.1 or later.
  - **Local signing in the generated project.** The project embeds local signing configuration: a concrete `DEVELOPMENT_TEAM` at `project.pbxproj:347`, `:492`, `:517` and `:543`, against `DEVELOPMENT_TEAM: ""` at `project.yml:36`. A regenerate-and-diff check must handle this.
  - **Unpinned engines.** The external `lkm-build` and `lkm-release` engines are resolved from `PATH` with no version (`scripts/build.sh:19-21`, `scripts/release.sh:27-31`).
  - **Floating tooling.** Actions are tag-pinned (`actions/checkout@v7`, `maxim-lobanov/setup-xcode@v1`, `softprops/action-gh-release@v3`) and Homebrew tools float (`brew install xcbeautify create-dmg`). `zai-code-review.yml:26` also uses `ubuntu-latest`; R-SEC-03 cites only `ci.yml` and `release.yml`. #92's pin does not cover this workflow: its final head (`53350b7`) still uses `ubuntu-latest` there (ORD-02).
- **Proposal:**
  - Add `swift test --package-path Packages/LLimitd` to the macOS job, folded into the cleanup of the duplicate QuotaCore run, and select Xcode before any test. Otherwise, correct AGENTS.md.
  - Raise `minimumXcodeGenVersion` to the version actually used. Add a regenerate-and-diff CI check that installs that exact XcodeGen release with a checksum, and decide whether the committed project or `project.yml` owns the team setting. Have `scripts/bootstrap.sh` print `xcodegen --version`.
  - Pin the relevant Actions and tooling (SEC-04), and give `lkm-build`/`lkm-release` a pinned bootstrap contract.
  - Add meaningful lifecycle, rendering, concurrency and artifact gates. #92 deferred CI toolchain caching.
- **Tests / acceptance:** the macOS job compiles and tests LLimitd, which also runs #92's PTY secret-input test on Darwin. A drifted `project.pbxproj` fails CI. MAIN: the relevant platform, options and produced artifacts are exercised, not unrelated green jobs. Portable tests do not prove native UI or live OAuth.
- **Relations:** IDEA-03 (a macOS `llimit` helper would also build LLimitd on macOS). BLD-01 and #92 (same workflow, the `macos-15` image, deferred caching). SEC-04 (pinning). The R-SEC-03 remainder (a shared setup-swift composite action). BLD-04 (`lkm-release` hook). MAIN's strict-Swift migration item (an opt-in strict CI leg) is tech debt, not part of this entry.

### BLD-09 CI concurrency cancels runs on main
- **Status / severity / effort / platform:** open. Severity: low (TMP). Effort: S. Platform: CI.
- **Sources:** TMP R-BLD-07 (BUILD-9).
- **Problem and evidence:** `.github/workflows/ci.yml:8-11` sets `group: ci-${{ github.ref }}` with `cancel-in-progress: true`, which also applies to push runs on `main`. Run 36306682635 was cancelled after 7 s, so commit 4ecaaba has no CI result. `CICD.md:34-35` documents the behavior as intended.
- **Proposal:** use `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`, or key push runs by SHA. Leave the release workflow's group (`release.yml:7-9`, `cancel-in-progress: false`) unchanged.
- **Tests / acceptance:** two quick pushes to `main` both produce completed CI runs, and a re-pushed PR branch still cancels its older run.
- **Relations:** BLD-07 (update the CICD.md concurrency note).

### BLD-10 User-facing provider and import-source lists lag the code
- **Status / severity / effort / platform:** open. Severity: low (TMP). Effort: S. Platform: Linux-testable (drift test). The Settings copy is macOS-only.
- **Sources:** TMP R-BLD-12 (SETTINGS-14, PRODUCT-19, BUILD-15).
- **Problem and evidence:**
  - `APP/Views/SettingsView.swift:281` names 4 import tools (Claude Code, Codex, GitHub Copilot, OpenCode).
  - `README.md:24-26` names 7 tools and is missing Antigravity, Venice and Cline.
  - `Packages/LLimitd/packaging/build-deb.sh:94-95` lists 7 providers.
  - `QC/Models.swift:78`, `:169` and `:184` say "Auto-detected from …", although the fields fill only through Auto-fill or Import.
  - `QC/CredentialDiscovery.swift:75-89` runs 10 scanners: Claude Code, Codex, Copilot, Kimi, Antigravity, Venice, Cline, OpenCode, Devin and Muse.
  - `CLI/main.swift:199-204` prints only diagnostics when nothing is found.
  - The AGENTS.md adding-a-provider checklist (`:142-152`) has no step for these lists.
- **Proposal:**
  - Add `CredentialDiscovery.supportedSources` (provider plus tool name) in QuotaCore.
  - Render the Settings sentence from it with `ListFormatter`, and list it in `llimit accounts import` when nothing is found (the diagnostics are already printed).
  - Change the help text to "Use Auto-fill to import it from …".
  - Split the Settings paragraph into "what Import does" and "only Connect Claude and Connect OpenAI renew automatically".
  - Update the README and the `.deb` description (BLD-05).
  - Add the lists to the AGENTS.md checklist.
- **Tests / acceptance:** every scanner has a `supportedSources` entry. Optionally, every `displayName` appears in the README.
- **Relations:** DEBT-05 (the provider metadata consolidation that would own these names). BLD-05 (`.deb` description). BLD-06 (README).

### BLD-11 Repository support files
- **Status / severity / effort / platform:** open. Severity: low (MAIN). Effort: S. Platform: repository docs and config.
- **Sources:** MAIN AM-BUILD-5 ("Repository support").
- **Problem and evidence:**
  - The baseline has no vulnerability-reporting policy, no contribution guide, no ownership file and no documented lint conventions.
  - The host app's unsandboxed file access is documented only in AGENTS.md: it reads `~/.claude`, `~/.codex`, other tool directories and the Keychain.
  - `.gitignore` ignores neither result bundles (`*.xcresult`, see BLD-07) nor private signing material.
  - `CHANGELOG.md` (8c6b2bd) and `.github/dependabot.yml` (1eced2a, weekly `github-actions` updates) already exist.
- **Proposal:**
  - Document vulnerability reporting and the unsandboxed access.
  - Document contribution, ownership and lint conventions.
  - Ignore result bundles and private signing material.
  - Keep checksums and attestations as scoped release follow-ups (in BLD-03's publish job), not new global policy.
- **Tests / acceptance:** the support files exist and match AGENTS.md's access list. `git status` stays clean after a local CI reproduction and after exporting signing material into the worktree.
- **Relations:** BLD-07 (`*.xcresult`). BLD-02 (signing material). BLD-03 (checksums and attestations). SEC-04 (Dependabot plus SHA pinning).

## Security

Credential exposure, identity binding, file modes, supply chain and CI permissions.
The two documents rate SEC-01 and SEC-02 differently (MAIN high, TMP low); both
ratings are given. Line numbers refer to baseline 2d6ac1e. Entries marked
"verified" were rechecked against the baseline source while merging.

### SEC-01 Imported OpenAI token sync must bind workspace and user
- **Status / severity / effort / platform:** Open. Severity disputed: MAIN high; TMP low
  (verifier: narrow trigger). Effort S. Linux-testable (QuotaCore sync helper and daemon);
  the AppModel wiring is macOS-only.
- **Sources:** TMP R-SEC-06 (AUTH-8); MAIN C07.
- **Problem and evidence:**
  - `QC/OpenAICredentialSync.swift:36-41` matches live Codex/OpenCode logins to an
    imported account only by `openai.account_id`, the `chatgpt_account_id` claim; `:44-59`
    then adopts the candidate with the longest-lived access token if it is strictly
    fresher (MAIN cites `:36-59`). For Team, Business and Enterprise plans that id is the
    shared workspace id, not a user id.
  - If `~/.codex` is later logged in as a different member of the same workspace,
    LLimit adopts that user's access and refresh tokens into the account
    (`APP/AppModel.swift:675-693`; `LD/QuotaDaemon.swift:411-429`, TMP cites `:411-425`)
    and later rotates that user's grant.
  - Refresh acceptance can replace identity: `refreshOpenAIAccount` writes
    `result.accountID` over the stored account id without comparing it
    (`APP/AppModel.swift:712-714`; `LD/QuotaDaemon.swift:446-448`, MAIN cites `:438-448`).
  - Verified: the same adoption runs on the refresh-failure path (`AppModel.swift:719`,
    `QuotaDaemon.swift:452`) and in failed-token recovery (`AppModel.swift:747`,
    `QuotaDaemon.swift:477`). `adoption` already skips managed accounts (`:31`) and
    accounts with no stored account id (`:34`). `adopting` fills the account id only when
    it is missing (`:88-93`).
  - Managed Codex already makes the distinction: `CodexAccountIdentity.matches`
    compares account and user ids (`QC/CodexAccountProfile.swift:14-16`), and
    `parseIdentity` reads `chatgpt_user_id`, then `user_id`, then `sub`.
  - Unverified: TMP also cites `OpenAICredentialSync.swift:153-181`, which is past the
    end of the 97-line file at baseline.
- **Proposal:**
  1. In `OpenAICredentialSync.adoption`, compare the user claim (`chatgpt_user_id`,
     `user_id`, then `sub`), reusing `CodexAccountProfile`'s claim extraction instead of
     a second parser. Reject a candidate whose workspace or user differs.
  2. Make an established identity immutable. In `refreshOpenAIAccount` (app and
     daemon), discard refresh results whose account id or user id differs from the
     stored identity instead of overwriting it (shared with R-BUG-40).
  3. Unknown identity. The sources disagree. TMP: when the stored token cannot be
     decoded, adopt only if exactly one candidate exists, and reject only when both
     tokens carry a user claim and the claims differ. MAIN: unknown identity requires an
     explicit reimport, and missing identity can never retarget an account. MAIN's rule
     is stricter. Choose one and record it in AGENTS.md next to the Codex constraints.
  4. Preserve the reported #86 `env:NAME` references: decode identity from the resolved
     value, keep rotations writing through the reference as #86 does, and never persist
     resolved values. Keep managed-profile isolation (`isManaged` exclusion); AGENTS.md
     forbids adopting global Codex/OpenCode tokens into managed accounts.
- **Tests / acceptance:** Same account id with different user ids yields nil. A refresh
  result with a changed account or user id is rejected and the stored identity is
  unchanged. A same-user, fresher token is still adopted. A stored account without a
  decodable identity is never retargeted (or, under TMP's rule, only with a single
  candidate). An `env:NAME` reference survives adoption and rotation. Cover QuotaCore and
  the daemon path on Linux.
- **Relations:** PRF-07 (R-PERF-03) changes the same `adoptLiveOpenAITokens` scan;
  a scoped `discover(providers:)` must keep the identity check. PRV-19 (R-BUG-40) is the
  manual-paste variant; its refresh-result check by account id also covers part of this
  item. R-BUG-10's forced OpenAI recovery calls the same adoption. #86 (MAIN-reported).
  Extends BACKLOG "Honest OAuth ownership". No PR from this pass touches it.

### SEC-02 Private file and directory modes on both platforms
- **Status / severity / effort / platform:** Partial. #71 and #74 (MAIN-reported) write
  settings, snapshot and history at 0600 from the first byte. Severity disputed: MAIN high;
  TMP low. Effort S. Store modes, umask and units are Linux-testable; the App Group mode
  is macOS-only.
- **Sources:** TMP R-SEC-07 (LINUX-19); MAIN C09; MAIN ledger #71, #74.
- **Problem and evidence (remaining):**
  - Directories are created with the process umask, typically 0755:
    `QC/SettingsStore.swift:25-28`, `QC/SnapshotStore.swift:37-40`,
    `QC/QuotaHistoryStore.swift:44-47`, `LD/SettingsLock.swift:63-66` (the lock file itself
    is opened 0600 at `:67`). On Linux this covers `$XDG_CONFIG_HOME/LLimit/`, which holds
    credentials, and `$XDG_DATA_HOME/LLimit/`.
  - Baseline file modes, now reported fixed: snapshot and history were chmodded 0644
    (`SnapshotStore.swift:43`, `QuotaHistoryStore.swift:52`) although they hold account
    names and raw failure bodies; settings became 0600 only after the atomic write, and a
    chmod failure was ignored (`SettingsStore.swift:32`). #71 reports
    `O_CREAT|O_EXCL` at 0600, `fchmod`, file `fsync`, same-directory rename, `stat`
    type/mode check and directory `fsync`, removing the intermediate and throwing on
    failure; its polling test saw thousands of intermediate 0644 samples before and only
    0600 after a large save. #74 reports `writeOwnerOnlyAtomically` (0600 temporary file
    before rename) for snapshot and history, with chmod/write errors on stderr. Neither
    establishes directory, owner, symlink or shared-container invariants.
  - `Packages/LLimitd/systemd/llimit.service:6-10` and `llimit-refresh.service:6-8` set
    no `UMask` and no sandboxing. Unverified: `llimit-tray.service` is not covered by the
    sources, and whether the same restrictions suit its GTK/D-Bus needs is untested.
  - Ubuntu 21.04+ home directories are 0750, which limits the exposure.
  - macOS: the App Group snapshot goes through the same `SnapshotStore`. The narrowest
    mode the sandboxed widget can still read is unverified.
- **Proposal:**
  1. Reuse the #71 and #74 helpers; do not rebuild byte-one protection or swallow its
     cleanup and `fsync` errors.
  2. Create local credential directories 0700 (TMP: all LLimit-created directories).
     Decide whether to tighten directories that earlier versions already created 0755.
  3. Validate owner, type, symlinks and final mode on files and directories, and
     propagate verification failures as errors instead of `try?`.
  4. Add a permissions parameter to the stores so Linux writes 0600 and the App Group
     copy uses the narrowest mode that still works for the sandboxed widget. Keep local
     temporary and replacement files 0600.
  5. Call `umask(0o077)` at CLI start.
  6. Add to both service units: `UMask=0077`, `NoNewPrivileges=yes`,
     `LockPersonality=yes`, `RestrictRealtime=yes`, `RestrictSUIDSGID=yes`,
     `SystemCallArchitectures=native`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`,
     `SystemCallFilter=@system-service`. Avoid `ProtectHome` and `PrivateTmp`: import reads
     `~/.codex`, and user namespaces may be restricted.
- **Tests / acceptance:** Daemon-created files are 0600 and directories 0700.
  First-save, overwrite, permission-failure, symlink, wrong-type and wrong-owner tests
  prove no public credential temporary file and no falsely successful save. Verify
  replacement, directory restrictions and shared-container widget access, not only a
  chmod after exposure. The hardened units still start, fetch, and import from `~/.codex`
  (manual systemd check).
- **Relations:** #71, #74 (MAIN-reported). Managed profile directories already use 0700
  (`QC/CodexProfileStore.swift:98-105`, `ClaudeProfileService.prepareDirectory`). New
  state files such as #110's alert dedupe state should use the same helper. The store
  half duplicates BACKLOG "Credential security > Enforce local permissions"; unit
  hardening is new. Installer path handling is L06.

### SEC-03 Removed accounts keep live refresh grants
- **Status / severity / effort / platform:** Open. Medium (TMP; in TMP's "next tier",
  not shortlisted). Effort M. The Codex sweep is Linux-testable in QuotaCore; the Claude
  Keychain sweep and Settings UI are macOS-only.
- **Sources:** TMP R-SEC-05 (AUTH-5).
- **Problem and evidence:**
  - The UI reports "cleanup is pending" (`APP/AppModel.swift:435`, `:456`, `:819`,
    `:833`, `:870`, `:1020`; surrounding flows `:430-438`, `:455-457`, `:815-820`,
    `:828-834`, `:997`, `:1026`), but nothing ever does it.
  - `ClaudeProfileService.retain` writes `RetainedProfiles/<uuid>.json`
    (`APP/Services/ClaudeProfileService.swift:139-162`), and `remove` (`:173-197`) refuses
    while the profile is refresh-locked (`:181`). Nothing reads `RetainedProfiles/` or
    lists `CodexProfiles/`.
  - `CodexAccountService.remove` (`QC/CodexAccountService.swift:110-113`) returns false
    when a session is live and swallows errors with `try?`; a failed Codex removal is never
    retried. `try? claudeProfiles.remove` errors are dropped.
  - Refresh tokens of removed accounts therefore outlive the removal on disk and in the
    Keychain, with no UI to find or delete them. README:143-147 and :155-157 disclose the
    retention (and say these namespaces are "not imported, polled, or automatically
    deleted"), so the misleading part is the word "pending".
- **Proposal:**
  1. Run a sweeper at bootstrap and after each refresh. Claude: remove retained profiles
     that no account references and that have no session, no renewal and no refresh lock.
     Codex: add `CodexProfileStore.namespaces()` and remove unreferenced namespaces with no
     `.pending` marker and no in-memory session. Never remove a namespace that has a
     marker (AGENTS.md). Keep the existing rule that removal never invokes logout.
  2. List whatever the sweeper cannot remove in a Settings "Leftover sign-ins" section
     with an explicit, warned delete. This is a policy decision; record it in AGENTS.md
     and update the README text that promises no automatic deletion.
  3. Replace "cleanup is pending" with an actionable notice.
- **Tests / acceptance:** A sweep over referenced, unreferenced and marker-bearing
  namespaces removes only the unreferenced, marker-free ones. A refresh-locked Claude
  profile survives. A removal that failed once succeeds on a later sweep.
- **Relations:** Must honor BND-04 (pending markers, timed-out children). PRD-11 builds
  on per-account removal. SEC-02 (directory modes). AppModel.swift is also edited by
  #94, #101, #102, #104, #106 and #107, so expect a rebase.

### SEC-04 CI runs repository code with a write-all token
- **Status / severity / effort / platform:** Open. Medium (TMP). Effort S. CI-only; not
  testable with `swift test`.
- **Sources:** TMP R-SEC-02 (BUILD-7). TMP backlog note (R-SEC-02): extends BACKLOG "Supply chain, artifacts, and documentation"; persisted checkout credentials and SHA pinning are already listed there, and read-only top-level permissions are new.
- **Problem and evidence:**
  - `.github/workflows/ci.yml` has no `permissions:` block (`:17`). Run 37509656521 shows
    write access to Actions, Contents, Issues, Deployments and PullRequests.
  - `actions/checkout@v7` (`:22`; also `:71`, `:96`) persists the token in `.git/config`
    while floating `brew install xcbeautify` (`:33`), `swift test` and the harness
    scripts run.
  - `release.yml:11` grants `contents: write` at the top level, so every job holds it.
  - Correction (rejected BUILD-7 sub-claim): a tag pushed with `GITHUB_TOKEN` does not
    trigger release.yml. The real risk is that compromised code can use the Releases API
    or push branches directly.
  - Verified: actions are tag-pinned (`actions/checkout@v7`,
    `maxim-lobanov/setup-xcode@v1` at `ci.yml:28`, `actions/upload-artifact@v7` at `:61`,
    `softprops/action-gh-release@v3` at `release.yml:130`). `zai-code-review.yml` already
    declares `permissions:` and SHA-pins its one action, and `.github/dependabot.yml`
    already updates the github-actions ecosystem weekly.
- **Proposal:** Set top-level `permissions: contents: read` and `persist-credentials:
  false` on every checkout. In release.yml, go read-only at the top and grant
  `contents: write` only to the publish job (R-BLD-04). Pin xcbeautify with a checksum, or
  drop it. SHA-pin actions; the existing Dependabot config keeps them current.
- **Tests / acceptance:** The "GITHUB_TOKEN Permissions" section of a CI run log lists
  only read scopes. No checkout leaves an auth header in `.git/config`. Every `uses:` is a
  full commit SHA. Only the release publish job holds write access.
- **Relations:** BLD-08 (SHA pinning), R-BLD-04 (split release into read-only build jobs
  and a write-scoped publish job), SEC-05 (same workflows). MAIN's build item 3 ("pin
  relevant Actions/tooling") and item 5 (checksums, attestations and tested-main release
  gating as scoped release follow-ups) overlap. #92 edits both workflows.

### SEC-05 Unverified Swift toolchain download for the shipped .deb
- **Status / severity / effort / platform:** Partial. #92 pins `ubuntu-24.04`; its
  review declined adding the toolchain verification and CI caching, so both stay
  here. Medium (TMP). Effort S. CI-only.
- **Sources:** TMP R-SEC-03 (BUILD-6); LEDGER #92 deferrals.
- **Problem and evidence (remaining):**
  - The toolchain tarball is downloaded with `curl` and extracted with `sudo tar` without
    a checksum or signature check (`ci.yml:75-84`, curl at `:80`; `release.yml:101-110`,
    `:106-108`), unlike the static SDK step right below it, which passes `--checksum`
    (`release.yml:116-118`).
  - The install block is duplicated across workflows; #92's new "Linux (static .deb)" CI
    job makes three copies.
  - The download is HTTPS from swift.org, so verification is defense in depth.
  - Context for the #92 pin: `ubuntu-latest` (`ci.yml:69`, `release.yml:93`) moves to
    26.04 between Oct 19 and Nov 19, 2026 (runner-images#14748); whether
    `libgcc-13-dev` exists there is unverified. Unverified: whether #92 also pinned
    `tray-test` (`ci.yml:94`).
- **Proposal:** Either run the jobs in `container: swift:6.2.3-noble@sha256:<digest>`,
  or add `sha256sum -c` or `gpg --verify` before extraction. Move toolchain and static-SDK
  setup into `.github/actions/setup-swift/action.yml` and use it in all three jobs. Let
  Dependabot bump the image digest (unverified: the current config covers only the
  github-actions ecosystem and may need a docker entry). CI toolchain caching, also
  deferred from #92, fits the same action.
- **Tests / acceptance:** A wrong checksum or signature fails the job before extraction.
  All three jobs use the composite action, and no copy of the curl/tar block remains. The
  `.deb` still builds.
- **Relations:** #92; R-BLD-02 (asks for the same composite action); R-BLD-01 (pin in the
  same PR); SEC-04; MAIN build items 3 and 5; BLD-08.

### SEC-06 Scripted account setup forces secrets onto argv
- **Status / severity / effort / platform:** Partial. #104 adds in-place update without
  remove-and-add; #86 (MAIN-reported) adds `env:NAME` references. Medium (TMP). Effort S.
  Linux-testable.
- **Sources:** TMP R-SEC-04 (LINUX-12); MAIN L09; LEDGER #104 and its deferral.
- **Problem and evidence (remaining):**
  - Non-interactive `accounts add` accepts secrets only as `--set key=value`
    (`CLI/main.swift:117-122`). Without a TTY, missing required fields must come from
    `--set` (`:140-146`). The value is visible in `/proc/<pid>/cmdline` for the life of
    the process, and more durably in shell history and committed scripts. Nothing warns.
    `Packages/LLimitd/README.md:41-53` documents only the prompting form.
  - A systemd timer command (R-IDEA-02) persists in the unit, so argv secrets would
    persist there too.
  - Unverified: whether the CLI accepts `--set key=env:NAME` under #86 as a scripted
    alternative.
  - #104: `--set key` without a value fails on a non-TTY instead of prompting.
    Deferred by #104: that error should name every key that would have been
    prompted.
- **Proposal:**
  1. Accept `--set key=-` (read the value from stdin) and `--set-file key=<path>`, plus
     file-descriptor input (MAIN). When stdin is a pipe and exactly one secret is missing,
     read it from stdin. Document
     `printf %s "$KEY" | llimit accounts add --provider venice --set venice.api_key=-`.
  2. Warn on stderr when an `isSecret` field (`QC/Models.swift:58`, default true) is
     passed inline. Keep secrets out of argv, history and diagnostics.
  3. Parse in a testable `AccountAddArguments.parse` in LLimitdCore and use it for
     #104's update command too.
  4. Check #104's update against L09: MAIN asks for a transactional
     `llimit accounts set <id> [--name …] [--set key=value …]` under the settings lock
     that preserves ids, history and tile slots, invalidates key-dependent estimates, and
     is tested with injected durable-save failures. TMP's design (R-LNX-03) names it
     `accounts update` with a `rename` alias and `reimport`; keep one name. LEDGER gaps:
     R-LNX-10 is deferred, so an in-flight daemon refresh can re-save an old Venice
     estimate after the update; the stored import source and Claude `expiresAt` are also
     deferred. Whether #104 tests update with an injected save failure is unverified.
- **Tests / acceptance:** Inline, `-`, file, fd and missing-value cases. An inline secret
  prints the warning. On a non-TTY, the error names every key that would have been
  prompted. Secrets never appear in errors. An injected save failure leaves
  settings unchanged and exits nonzero.
- **Relations:** #104, #86, R-LNX-10, R-IDEA-02. SEC-07 can share the secret reader.
  `CLI/main.swift` is also edited by #92, #104, #108 and #110 (separate regions).

### SEC-07 The static .deb echoed secrets at the prompt (remainder)
- **Status / severity / effort / platform:** Partial. #92 adds the Musl echo-off branch
  and a PTY test. Medium (TMP; verifiers lowered it from high because the secret shows
  only on the user's own terminal and scrollback and is neither persisted nor sent).
  Effort S. Linux-testable (openpty).
- **Sources:** TMP R-SEC-01 (BUILD-3; GAPB-10 signal note); LEDGER #92 deferrals.
- **Problem and evidence (remaining):**
  - At baseline `readField` (`CLI/main.swift:373-393`, guard at `:380`) disabled echo only
    under `canImport(Glibc) || canImport(Darwin)`. The musl static SDK has no Glibc module,
    so the shipped binary (built at `release.yml:124`) used plain `readLine()`. Verified by
    TMP: the static build has no `tcgetattr`/`tcsetattr` symbols, and a probe showed
    `canImport(Glibc)` false and `canImport(Musl)` true. v1.0.1 has the same guard, and
    the README quickstart prompts for the token, so secrets typed into v1.0.1 may remain
    in scrollback, tmux logs or screen shares.
  - Between turning echo off (`:385`) and restoring it (`:387`) no handler restores the
    terminal on SIGINT, SIGTERM or SIGHUP. Only dash reproduced the stuck-echo case
    (REF-07): bash restores the tty after a signal-killed foreground job, zsh and fish echo
    input themselves, and EOF is already handled. This is hardening.
  - The `main.swift:5-8` and `LD/SettingsLock.swift:2-5` import blocks have no Musl branch
    and compile only because Foundation re-exports Musl. Harmless today (DEBT-06).
- **Proposal:** Restore termios on SIGINT, SIGTERM and SIGHUP during the read, then
  re-raise with the default disposition so the exit status stays signal-based. Keep it
  scoped to the prompt; daemon mode already owns SIGTERM/SIGINT through
  `installShutdownHandlers` (`CLI/main.swift:341-356`). TMP suggests a LLimitdCore
  `TerminalSecretReader` that takes file descriptors (unrecorded whether #92 adopted it).
  Once #92 ships, publish a release note advising v1.0.1 users who typed tokens to clear
  their scrollback.
- **Tests / acceptance:** An openpty test signals a child blocked in the secret read
  and finds ECHO restored for each of the three signals. The release that first ships #92
  carries the note.
- **Relations:** #92; R-BLD-02 (musl CI build); REF-07; DEBT-06; SEC-06 (shared secret
  input). `CLI/main.swift` is also edited by #104, #108 and #110; it merges cleanly
  with #92 (measured, ledger table 1).

## Tech debt

Structural cleanups with low direct user impact, plus the small follow-ups this
pass's PRs deferred. Locations refer to baseline 2d6ac1e unless an entry names a
PR branch.

### DEBT-01 Structured logging for the app, widgets and QuotaCore
- **Status / severity / effort / platform:** partial. #78 (MAIN-reported,
  `fix/store-corruption-quarantine`) adds `reportPersistenceIssue` for persistence
  problems (Darwin `os.Logger`, Linux stderr), and #79 (MAIN-reported) adds an
  `NSLog` breadcrumb for the failable App Group `SnapshotStore` init. Remaining:
  app/widget `print()` calls, silent tile load errors and a QuotaCore logging hook.
  Medium (TMP). Effort S. Mostly macOS-only (manual `log show` check); the QuotaCore
  hook is Linux-testable.
- **Sources:** TMP R-DEBT-01 (GAPB-4); MAIN C06 (pass D note), #78 and #79 reports;
  LEDGER #90 deferral.
- **Problem and evidence:**
  - macOS sends stdout to /dev/null for LaunchServices-launched apps and WidgetKit
    extensions, so none of these lines reach the unified log:
    `APP/AppModel.swift:278`, `:717`, `:1723`, `:1742-1754`, `:1911-1944`,
    `:1986-1988`, `:2003-2012`; `WX/QuotaTimelineProvider.swift:77`, `:88`, `:109`.
  - Provider tiles load settings and snapshot with `try?`
    (`WX/ProviderQuotaWidget.swift:288-304`), so any load error falls back to the
    "No accounts yet" view (`:561`) with no trace (see WID-03).
  - Every snapshot sync prints a success line and runs `debugInfo()` on the main
    actor (`APP/AppModel.swift:1918`, `:1940-1941`; `QC/SnapshotStore.swift:46-65`
    stats the file and resolves the App Group container). MAIN C06 records the same
    pass D finding as separate from #78's persistence logger.
  - QuotaCore has no logger, so #90 could not log unknown Z.ai/Zhipu
    (unit, number) pairs. `QuotaDaemon(log:)` (`LD/QuotaDaemon.swift:52`, `:58`)
    already shows the closure-injection pattern.
  - Correction: `scripts/widget-diagnostics.sh:110-115` still captures WidgetKit
    and system logs (its predicate matches the extension process and messages
    containing `ch.lkmc.llimit`). Only LLimit's own lines are missing.
- **Proposal:**
  1. Add a shared `os.Logger` wrapper in `Shared/` with subsystem `ch.lkmc.llimit`
     and categories app, widget, sync and auth. Error kinds and status codes are
     `.public`; paths, names and descriptions are `.private`; credentials and
     response bodies are never logged.
  2. Replace the tiles' `try?` with do/catch, logged once per timeline.
  3. Remove the success prints and the `debugInfo()` call from the sync path.
  4. Filter `widget-diagnostics.sh` on the new subsystem.
  5. Give QuotaCore an injected log closure, as `QuotaDaemon(log:)` does, so it stays
     Foundation-only (AGENTS.md); Linux maps it to stderr.
  6. Reuse or fold in #78's `reportPersistenceIssue` rather than keeping two
     mechanisms. MAIN C06 asks that sync diagnostics go through
     `reportPersistenceIssue`-style logging with safe structured fields, not stdout
     dumps.
  - Constraint: AGENTS.md requires anything written to logs to be redacted.
- **Tests / acceptance:** manual: corrupt the App Group settings and find the error
  in `log show` under the new subsystem. MAIN C06: captured sync logs keep useful
  severity and context, contain no secrets, and Linux JSON stdout stays clean.
  Linux: a unit test that the QuotaCore hook receives the event and never a body.
- **Relations:** WID-03 (explicit tile/trend load outcomes instead of "No accounts
  yet"); MAIN C06 (durable outcomes for persistence failures); R-DEBT-02 (clients
  echo response bodies into failure messages today, which must not flow into the
  new logs); #90's deferred unknown-unit logging; #94 and #78 touch the same store
  paths.

### DEBT-02 Provider client registration invariants
- **Status / severity / effort / platform:** open. Sources disagree on severity:
  TMP rates it low (preventive; all 12 providers are registered today), MAIN C12
  rates it medium (reported latent risk). Effort S. Linux-testable.
- **Sources:** TMP R-DEBT-03 (CORE-11); MAIN C12 (pass D).
- **Problem and evidence:**
  - `QC/QuotaCoordinator.swift:6-8` builds `clientsByProvider` with
    `Dictionary(uniqueKeysWithValues:)`, which traps if two clients report the same
    provider.
  - `:10-37` (`live()`) registers 12 clients. Zhipu and Z.ai are two
    `ZhipuQuotaClient` instances with distinct provider cases (`.zhipu`, `.zai`) and
    endpoints, so they do not collide. MAIN notes pass D cites them as multi-client
    motivation, but distinct provider cases do not establish that duplicate
    same-provider registration is supported.
  - `:42-44` filters out enabled configurations whose provider has no client. Such
    an account appears in neither `providers` nor `failures`, with no message.
- **Proposal:**
  1. Define the registration invariant first (one client per provider) before
     changing construction.
  2. For a configuration with no client, append
     `ProviderFailure(kind: .notConfigured, "<Provider> is not supported by this build")`.
  3. Duplicates: TMP proposes `uniquingKeysWith` plus `assertionFailure`. MAIN keeps
     the `Dictionary(_, uniquingKeysWith:)` option only with an explicit, documented
     deterministic duplicate policy or an actionable configuration failure; never
     silently select the wrong client, and do not add a broad registry. Note that
     `assertionFailure` is compiled out of release builds, so TMP's variant still
     needs MAIN's explicit release policy.
  - Zhipu and Z.ai stay distinct providers.
- **Tests / acceptance:** refresh `.live()` with one configuration per
  `QuotaProvider.allCases`; every account id appears in either usage or failures
  (TMP). Inject duplicate provider clients: documented deterministic handling or an
  actionable configuration failure, no process trap; normal registration and
  Zhipu/Z.ai identity unchanged (MAIN).
- **Relations:** MAIN's follow-up order keeps C12 bounded. DEBT-05 (a provider
  descriptor's tests cover incomplete registration).

### DEBT-03 Localization readiness: persisted English and literal sentinels
- **Status / severity / effort / platform:** partial. #103 (this pass) adds an
  optional `UsageMetric.windowSeconds` and populates it in the OpenAI, Codex, Kimi
  and Muse clients; on the #103 branch `classify` does not read it yet. #80
  (MAIN-reported) makes dashboard rows speak unlimited/unknown instead of literal
  `INF`/`--`. Remaining: persisted `windowKind`, coded warnings, display-time
  formatting, Unlimited/Unknown on the other surfaces, and a String Catalog. Low.
  Effort M. The QuotaCore model changes are Linux-testable; String Catalog and
  SwiftUI surfaces are macOS-only.
- **Sources:** TMP R-DEBT-05 (GAPB-9); MAIN M12. Mostly duplicates BACKLOG
  "Appearance model cleanup (declare window kind)" and "Platform polish (String
  Catalog, locale-aware formatting)".
- **Problem and evidence:**
  - `usageLine` is computed, but labels, details, warnings and `resetIn` are
    persisted English strings (`QC/Models.swift:257-326`).
  - `QuotaWindowKind.classify` (`QC/Models.swift:804-855`) tokenizes the metric id
    plus label ("N-hour", "N-minute", "N-day", weekly, monthly; Copilot `premium`
    is a special case). Anthropic's `seven_day` relies on its label for
    classification. Kimi (`QC/Clients/KimiQuotaClient.swift:144`) and Muse
    (`QC/Clients/MetaMuseQuotaClient.swift:146`) spell labels so `classify` can
    parse them ("5-hour limit", not "5h limit"). A translated label would change
    window kind and therefore color.
  - `QC/Utilities.swift:12-23` (`formatShortDuration`) builds English "4d 6h 56m"
    strings that end up in `resetIn`; `:115-126` uses `String(format: "%.1f")` and
    `"%.1fM"`, which are not locale-aware.
  - Literal sentinels remain: `APP/Views/SettingsView.swift:1294-1306` (`--`,
    `INF`), `WX/LLimitQuotaWidget.swift:1050-1058` (`--`, `INF`),
    `WX/ProviderQuotaWidget.swift:701` (`--` for an unknown reset), and the
    dashboard's visible `--` (`APP/LLimitApp.swift:357` ring center, `:1267`
    LOWEST cell). #80 changes only the spoken text. MAIN also lists the tray; at
    baseline the tray (`Packages/LLimitd/tray/llimit_tray.py:75-76`, `:103-104`)
    and `LD/StatusRenderer.swift:43-44` print the English words "unlimited" and
    "no data" rather than `INF`, so there this is a localization item, not a
    sentinel.
  - MAIN: incoming main reports no localization infrastructure.
  - Unverified: translation is hypothetical today, and several providers already
    carry the cadence in stable ids.
- **Proposal:**
  1. Add a persisted optional `windowKind` next to #103's `windowSeconds`
     (`decodeIfPresent`), and have `classify` prefer `windowKind`, then
     `windowSeconds`, then today's id/label parsing for old snapshots. Never infer
     a length from the label (R-NOV-01).
  2. Persist warnings as codes plus parameters, keeping the English text as the
     fallback for old snapshots.
  3. Format countdowns and amounts at display time from `resetAt` and raw amounts.
     Keep `resetIn` for old snapshots and the Linux bar contract (adding keys is
     fine, renaming is not).
  4. Localize Unlimited and Unknown with semantic equivalents across Settings,
     widgets, dashboard visuals and tray through one shared presentation (MAIN M03).
  5. Treat a String Catalog as a bounded project.
  - Constraints: widget `configurationDisplayName`/`description` stay plain,
    non-formatted text and kind strings stay literal (AGENTS.md). Classification
    drives `LimitKindColors`, so existing kind results and pins must not change.
- **Tests / acceptance:** old snapshots without `windowKind` classify as before; a
  translated label does not change kind or color; coded warnings round-trip and
  fall back to stored English. MAIN M12: test hidden percentages and localized long
  labels without changing amount/unknown semantics; dashboard speech alone is not
  full localization.
- **Relations:** removes PRV-23's label parsing and R-BUG-13's root cause
  (positional metric ids). R-BUG-32 (classify bucketing; bucket by `windowSeconds`
  once present). #103 deferred window lengths for Muse weekly and Devin, which
  `classify` would need. R-A11Y-06 (spoken countdowns, locale-aware durations).
  MAIN M03 (Settings prints `--` for valid amounts) and W07 (widget AX reads
  `INF`/`--`). #95's ages are English-only by design.

### DEBT-04 Strict Swift 6 migration
- **Status / severity / effort / platform:** open. Low (MAIN). Effort not given by
  the sources; the known blockers are small. Linux-testable.
- **Sources:** MAIN AM-BUILD-4 (Build item 4) and MAIN "Evidence and validation
  limits".
- **Problem and evidence:**
  - Both packages declare `swift-tools-version: 5.10`
    (`Packages/QuotaCore/Package.swift:1`, `Packages/LLimitd/Package.swift:1`), so
    supported builds use Swift 5 language mode.
  - QuotaCore built in Swift 6 language mode. LLimitd's optional Swift 6 build
    failed at `LD/StatusRenderer.swift:222`:
    `private static let titleOrder: (ProviderUsage, ProviderUsage) -> Bool` is a
    non-Sendable stored closure. Supported-mode tests passed.
  - Async test fixtures also need synchronization work. MAIN does not name them.
    Candidates with hand-rolled shared state are
    `Packages/LLimitd/Tests/LLimitdCoreTests/SettingsConcurrencyTests.swift:204`
    (`CompletionFlag`), `:223` (`FetchGate`) and `QuotaDaemonTests.swift:395`
    (`EchoingClient`), all `@unchecked Sendable` (unverified which ones fail).
- **Proposal:**
  1. Make the comparator a static function or a `@Sendable` value. While there,
     make it a total order: it ties on equal provider and title, and MAIN notes
     that Swift's `sorted` does not give stable tie behavior; add the account id as
     a final key.
  2. Move async fixtures to modern async test synchronization.
  3. Then add an opt-in strict CI job.
  - Do not add broad MainActor isolation just to silence diagnostics. Builds in the
    declared language mode must stay green.
- **Tests / acceptance:** Swift 6 language-mode builds of QuotaCore and LLimitd
  succeed on Linux; all tests pass in the declared mode; the opt-in job runs in CI;
  a tie case sorts deterministically.
- **Relations:** MAIN F03 (stores keep codecs under `@unchecked Sendable` with
  unlocked read-modify-write; a real race, not something to annotate away) and
  F11 (`ISO8601DateFormatter` synchronization). R-BLD-10 (nothing builds LLimitd
  on macOS). #92 adds a Linux static `.deb` CI job; toolchain caching is deferred
  (DEBT-06). `StatusRenderer.swift` is also edited by #95 and #105 (#93 adds a
  test case), so expect rebases.

### DEBT-05 Provider metadata consolidation (optional)
- **Status / severity / effort / platform:** open, optional. Low (MAIN). Effort M
  if done fully, but it is meant to proceed one duplication at a time. QuotaCore
  data is Linux-testable; UI rendering is macOS-only.
- **Sources:** MAIN AM-BUILD-6 (Build item 6); AGENTS.md "Hard constraints"; related
  TMP R-BUG-35.
- **Problem and evidence:** six exhaustive `switch`es duplicate names, credential
  descriptors, default metric ids and presentation identifiers:
  `QC/Models.swift:17` (`displayName`), `:71` (`credentialFields`),
  `QC/ProviderMetricSelection.swift:3` (`defaultRingMetrics`),
  `WX/LLimitQuotaWidget.swift:1006` (`compactProviderName`),
  `WX/ProviderQuotaWidget.swift:832` (`ProviderTile.palette`) and
  `APP/LLimitApp.swift:1489` (`ProviderMark.symbolName`). The seventh,
  `APP/AppModel.swift:1500` (`defaultPrimaryKind`), has a `default:` that already
  hid a missing OpenCode Go case (R-BUG-35). Adding a provider touches all of them.
- **Proposal:** keep the proposed `ProviderDescriptor`/`ProviderMetadata` idea as
  optional. Put Foundation data (names, credential descriptors, default metric ids,
  default primary window kind) in QuotaCore; keep rendering (colors, views) in the
  UI targets. Migrate one genuine duplication at a time and update the AGENTS.md
  switch list as each moves. Provider brand metadata stays separate from
  `LimitKindColors` window/account identity.
- **Tests / acceptance:** tests cover every provider: labels, defaults, icons,
  colors, and incomplete registration.
- **Relations:** BLD-10; R-BUG-35 (move `defaultPrimaryKind` into QuotaCore as an
  exhaustive switch); DEBT-02 (registration completeness); AGENTS.md "Adding a
  provider" steps.

### DEBT-06 Small follow-ups deferred by this pass's PRs
- **Status / severity / effort / platform:** open. Low. Each item is XS to S.
  Platform per item below.
- **Sources:** LEDGER rows #92, #95, #96, #101, #102, #105, #106, #108, #109, #110.
  Larger deferrals from these PRs are tracked in their own clusters.
- **Problem, evidence and proposal per PR:**

| PR (branch) | Follow-up | Platform |
|---|---|---|
| #92 (`opus/release-unblock`) | Add a `canImport(Musl)` branch to the libc import blocks in `LD/SettingsLock.swift:2-6` and `CLI/main.swift:5-9` (harmless today; #92 added Musl only to the `CLI/main.swift:380` condition). Add CI toolchain caching. | Linux |
| #95 (`opus/dropdown-layout`) | Visual check on a Mac: 360 and 420 pt widths, floating window, long subtitles, the `≈100%` ring. | macOS, manual |
| #96 (`opus/status-item-health`) | Share the level, stale and failure-matching rules across `MenuBarGraph`, the dashboard's `MenuBarQuotaStyling` and the provider tile. Re-apply the status-item tooltip on display changes. Manual check of the tooltip and light/dark bars. | macOS |
| #101 (`opus/venice-key-commit`) | Drop `@discardableResult` on `updateAccount` (`APP/AppModel.swift:1587` on the branch). Trim legacy stored credentials for display. The SwiftUI commit triggers (submit, focus loss, selection, close, quit) are untested; manual check of close and quit with an open draft. | macOS |
| #102 (`opus/refresh-during-signin`) | Verify the tooltip on a disabled button on macOS 14. | macOS, manual |
| #105 (`opus/linux-honest-status`) | Besides dropping trailing unclosed tag fragments after each cut, also strip a lone trailing `<`, and repeat the fragment strip until the text is stable. Sample one `now` per tray menu build. | Linux |
| #106 (`opus/global-hotkey`) | Use `@ObservedObject` instead of `@StateObject` for `AppModel.shared` (`APP/LLimitApp.swift:28` on the branch). Check the hot key id, not only the signature, in the Carbon handler (`APP/Services/GlobalHotkeyService.swift:167` on the branch). The remembered previous app can go stale if the user switches apps before dismissing. | macOS |
| #108 (`opus/llimit-check-pick`) | Pre-existing: the snapshot merge (`QC/SnapshotMerge.swift:17`) and macOS lookups (for example `APP/AppModel.swift:304`, `:324`, `:353`; `WX/ProviderQuotaWidget.swift:264`; `APP/Views/SettingsView.swift:1261`) match failures by account id only, while #108's `HeadroomRanking` keys them by provider plus account id. Deferred by #108: a deterministic order for failure-only rows that share an account id. | Linux-testable (QuotaCore); macOS for app sites |
| #109 (`opus/trend-widget`) | Update the one stale doc comment on `recentPaceDepletion`. | QuotaCore (comment only) |
| #110 (`opus/linux-alerts`) | Alerts fire only from `llimit daemon` (`--notify`, `--on-event`, `LLIMIT_NOTIFY`); `llimit refresh` and the timer units (`Packages/LLimitd/systemd/llimit-refresh.service:8` runs `llimit refresh`) never evaluate them. `llimit paths` does not print the alerts state file (`$XDG_DATA_HOME/LLimit/alerts-state.json`). | Linux |

- **Tests / acceptance:** Linux items get unit or CLI tests (`llimit paths` lists
  the alerts file; a timer-driven refresh emits a threshold event once; a failure
  for another provider with the same account id does not attach; a text ending in
  a lone `<` or a nested fragment strips to a stable result; failure-only rows
  that share an account id keep one order across runs). macOS items are
  closed by a recorded manual check or a unit test where the logic moves into
  QuotaCore (shared level/stale rules).
- **Relations:** measured merge conflicts between this pass's PRs are in ledger
  table 1; in code only `LD/StatusRenderer.swift` (#95 x #105) and
  `APP/LLimitApp.swift` (#95 x #102) conflict, and `AppModel.swift`,
  `SettingsView.swift` and `llimit/main.swift` merge cleanly. Once #104 and #108
  both merge, #104's `makeDaemon` status warning is dead code; whichever lands
  second drops it and its README sentence (integration fix). #96's shared rules
  overlap R-UX-04 (dashboard order versus bars), which #96 deferred as a larger
  item.

## Product features, aesthetics and delight

Proposals, not regressions. Check the ledger first, then pick one bounded follow-up
with its acceptance condition; do not rebuild recorded features. Where TMP and MAIN
describe the same feature, they are merged into one cluster. MAIN-reported PRs
(#51, #53, #59, #87, #88, #97-#100) are source-document reports whose code, flags,
CI and merge state were not checked here; verify them before building on them.

### PRD-01 Depletion forecast at refresh time on every surface
- **Status / severity / effort / platform:** partial; medium (TMP); M; both platforms, estimator and Linux JSON Linux-testable, macOS row/widget display macOS-only.
- **Sources:** TMP R-FEAT-02 (PRODUCT-8); MAIN AM-PROD-9 ("Runway/burn-rate chip").
- **Problem and evidence:**
  - Done elsewhere: #109 (R-BUG-12) moved the trend warning into a QuotaCore `QuotaForecast`, still consumed only by the trend widget. Its final head also warns on a guarded recent pace (remaining at most 25%, a span of max(2 h, 3 refresh intervals), at least 4 raw samples), and its review decided that an early large burn that projects depletion keeps warning (no idle gate). #87 (MAIN-reported) adds `PaceEstimator`/`UsageMetric.paceEstimate` with a macOS dropdown burn-rate/ETA; its reset and gap correctness is unproven, and its existence is not forecast validation. The two engines overlap.
  - Baseline: the only forecast is the trend widget's `depletionWarnings` (`WX/LLimitQuotaWidget.swift:964`, `:975` 60% gate), shown as one line from `warnings.first` (`:99`), see also `:256`. The app loads only two days of history for sparklines (`APP/AppModel.swift:1759-1761`) and shows no forecast. Linux `metricObject` (`LD/StatusRenderer.swift:80-102`) emits none.
  - Unverified as new: this largely duplicates BACKLOG Product #3 and the "Trend chart" bullets (reset-segmented samples; more than one warning). The new parts were the QuotaCore placement (now #109) and the Linux JSON.
- **Proposal:**
  1. Converge #109's `QuotaForecast` and #87's `PaceEstimator` into one QuotaCore estimator before adding any surface. Correct the semantics first (W06 / R-BUG-12 gates), then move math into a chip; do not duplicate it.
  2. Compute at refresh time in `AppModel.publishSnapshot` (`APP/AppModel.swift:274`, before the history append) and `QuotaDaemon.refreshNow` (`LD/QuotaDaemon.swift:258-320`, before `snapshotStore.save` at `:312`), so StatusRenderer and widgets stay snapshot-only.
  3. Store an optional `projectedEmptyAt` on `UsageMetric` (`QC/Models.swift:257-280`; synthesized Codable decodes nil from older files).
  4. macOS: "At this rate: empty in 1d 4h, before reset" in `MetricQuotaRow` (`APP/LLimitApp.swift:1517`). MAIN's chip wording: "At this pace, about 3 hours left", on status, tray and widget.
  5. Linux: additive `projectedEmptyAt` and `exhaustsBeforeReset` keys in the metric JSON; tray reads them from `status --json`.
  6. Show the chip only with enough fresh, reset-segmented observations and stated confidence: gaps suppress it, a reset restarts it, stale, gapped or single-point data is not confident.
- **Tests / acceptance:** steady burn; a mid-window reset; flat usage; too few samples (TMP). W06 fixture: 10% before reset, 100% at reset, 20% now warns about the current depletion. A gap suppresses the chip; a carried (failed) reading never produces a forecast; an old snapshot without the field decodes. One estimator feeds the row, tray, widgets and JSON.
- **Relations:** overlap #109 vs #87 (ledger overlap list). Shares `windowSeconds` with PRD-02 (#103). Prerequisite for IDEA-13 (quota weather) and the rejected burn-down widget (REF-35). #58 weather header consumes headroom, not this forecast. Mostly a BACKLOG duplicate (Product #3).

### PRD-02 Pace against each window's own reset
- **Status / severity / effort / platform:** partial; proposal (no severity); M (remaining S); Linux-testable for JSON and client lengths, marker default macOS-only.
- **Sources:** TMP R-NOV-01 (PRODUCT-9; shortlist #14); MAIN AM-PROD-13 ("Pacing guide/ring").
- **Problem and evidence:**
  - Done in #103: optional `UsageMetric.windowSeconds`, `QuotaPace`, "N% over pace" / "on pace" / "N% under pace" text (the reset chip keeps its width), and neutral ticks on GlossBar and the tile ring.
  - Idea: "40% left" means very different things on day 2 and day 6 of a weekly window. Clients received the length but folded it into the label: OpenAI `limit_window_seconds` (`QC/Clients/OpenAIClient.swift:112`), Muse `window_duration_mins` (`QC/Clients/MetaMuseQuotaClient.swift:91`), Kimi `duration`/`timeUnit` (`QC/Clients/KimiQuotaClient.swift:163-174`), Codex `windowDurationMins` (`QC/CodexRateLimits.swift:39`). Anthropic `five_hour`/`seven_day` and Cline windows are fixed by id. Bar: `APP/LLimitApp.swift:369-401`.
  - Remaining gaps: Muse `weekly` carries only `used_percent` and `resets_at` (`MetaMuseQuotaClient.swift:98` onward); Devin `quota-daily`/`quota-weekly` (`QC/Clients/DevinQuotaClient.swift:113-114`) report only percent and reset epoch. Linux `metricObject` (`LD/StatusRenderer.swift:80-102`) has no pace key. #103 also left the GlossBar spring ignoring Reduce Motion (pre-existing).
  - Sources disagree on defaults: TMP wants the tick on every window with a known length and no setup; MAIN wants an opt-in, faint weekly/monthly comfortable-pace marker with an explicit target date (as BACKLOG Delight "Pacing rings" requires a user-chosen date). Check #103's default.
- **Proposal:**
  1. Emit an additive `paceDelta` in the Linux metric JSON: used% minus elapsed%, elapsed = 1 - (resetAt - now) / windowSeconds. Nil for rolling windows (OpenCode Go `rolling`) and for windows with no reported length (Copilot monthly, Venice).
  2. Muse weekly and Devin lengths: take them only from the API field identity (as with Anthropic ids) or a reported duration, never from the display label. Whether Devin's daily quota is a rolling 24 h or calendar-day window is unverified; leave it nil until a capture establishes it.
  3. Reconcile the marker with MAIN: faint, opt-in for weekly/monthly windows, plus an optional explicit target date. "Ahead of pace" versus "On track" uses elapsed and consumed within the known window (MAIN's earlier example: 20% elapsed, 70% consumed). No invented start dates or totals; the tick is neutral geometry, never identity recoloring.
  4. Later, let `classify` prefer reported durations (R-BUG-32, GAPB-9); BACKLOG "Appearance model cleanup (declare window data)".
- **Tests / acceptance:** pace at the start, middle and end of a window; missing data; per-client population (TMP). `paceDelta` is present only with `windowSeconds` and a future `resetAt`, absent for rolling and unknown-length windows; existing JSON keys unchanged. The 20%/70% example reads as ahead of pace. Marker default matches the agreed opt-in policy.
- **Relations:** #87's pace model partly overlaps (ledger overlap list). Weekday envelopes were rejected in favor of this (REF-25). Feeds PRD-01. StatusRenderer edits conflict with #95 and #105. Reduce Motion: M06.

### PRD-03 Use it or lose it: expiring headroom
- **Status / severity / effort / platform:** partial; proposal; S; Linux JSON Linux-testable, chip and notifications macOS-only.
- **Sources:** TMP R-NOV-02 (PRODUCT-12; shortlist #15); MAIN AM-PROD-8 ("Expiring headroom").
- **Problem and evidence:**
  - Done in #110: the QuotaCore `QuotaEvents` detector emits `expiringUnused` on Linux through `--notify`/`--on-event`. Deferred: the `expiringUnused` flag in `status --json`, the macOS "use it" chip and macOS notifications reusing `QuotaEvents`.
  - Every surface warns only about scarcity: `ResetChip` (`APP/LLimitApp.swift:511-512`), `MetricQuotaRow.valueColor` (`:1601`), the Linux class (`LD/StatusRenderer.swift:167`), the trend warning (`WX/LLimitQuotaWidget.swift:964`). Unused weekly or monthly quota on a flat-rate plan is simply lost.
- **Proposal:**
  - Rule (as in #110): fire once per window when a weekly or monthly metric has 24 h or less until reset and 50% or more remaining; both configurable. Copy: "Claude weekly: 62% unused, resets in 9h."
  - Linux: additive `expiringUnused: true` on the metric in `status --json`.
  - macOS: a text chip "use it" next to `ResetChip`, no new hue; notifications from the same `QuotaEvents` once PRD-04 converges the engines.
  - MAIN: only fresh, comparable allowances; actionable account links (needs W13's app route); disclose uncertainty. Never rank dollars against percentages.
  - Later: an optional, non-secret per-account plan price to phrase the nudge as an approximate dollar amount, labeled as an estimate.
- **Tests / acceptance:** kind filter, thresholds, once-per-reset dedupe (TMP). Stale or carried data never fires; balance-only and unknown-length metrics never fire; the JSON key and chip agree on the same fixture.
- **Relations:** PRD-04 (one evaluator), PRD-07 (account links, reset list), W13 deep links.

### PRD-04 Reliable notices across platforms
- **Status / severity / effort / platform:** partial; proposal; M; shared evaluator Linux-testable, Focus and notification delivery macOS-only.
- **Sources:** MAIN AM-PROD-6 ("Reliable notices").
- **Problem and evidence:**
  - Done: #100 (MAIN-reported) `QuotaAlertEvaluator`, `QuotaAlertSettings`, persisted dedup keys, warning/critical band crossings and per-kind failure notifications via `UNUserNotificationCenter`, rearming on recovery, thresholds in Settings > General. #97 (MAIN-reported) `llimit check [--below pct] [--stale-hours h]`, exit 1 with reasons, for `llimit check || notify-send` hooks. #110 (this pass) `QuotaEvents.detect`: 20% and 5% crossings, resets, auth/decoding failures appearing or clearing, `expiringUnused`; dedupe in a credential-free 0600 `alerts-state.json`; `--notify`, `--on-event` (exec without shell, env-only payload), `LLIMIT_NOTIFY`; notify-send and ntfy hook examples.
  - Two engines with two threshold sets (#100's user bands, MAIN's earlier 30%/15%; #110's 20%/5%). Display thresholds already disagree at baseline: macOS orange at 25% or less and red at 10% or less per metric (`APP/LLimitApp.swift:1601-1607`), Linux warning below 40 and critical below 15 on the aggregate minimum (`LD/StatusRenderer.swift:167-175`).
  - Still missing: quiet hours, Focus awareness (BACKLOG Product #1: Focus-aware suppression or post-Focus summaries where APIs permit), reset and reconnect notices on macOS, alerts from `llimit refresh` and timer units, the alerts path in `llimit paths` (#110 deferrals).
- **Proposal:** build on #97/#100/#110, not a new engine. Converge #100 and #110 on one QuotaCore evaluator with shared thresholds (WID-04): warning and critical remaining thresholds with valid ordering and one status policy. Opt-in low-quota, reset and reconnect notices; crossing dedupe and rearming; quiet hours; Focus awareness; stale suppression; Linux desktop and headless hooks. Reset notices only after an observed reset from a fresh fetch, never from the clock. Thresholds drive only the reserved warning accents and status class, never identity ring or trace recoloring.
- **Tests / acceptance:** warning <= critical is rejected; one notice per crossing and none until recovery; dedupe survives restarts; unknown or stale data never crosses a band; an offline failure notifies at most once per kind; quiet hours suppress and later summarize; the same fixtures give the same events on both platforms.
- **Relations:** overlap #100 vs #110, and #97 vs #108 (`llimit check` exit-code contracts are incompatible). WID-04 shared thresholds. PRD-03 builds on it; IDEA-02 and IDEA-05 build on this.

### PRD-05 Guided first account
- **Status / severity / effort / platform:** open; proposal; L (estimate); macOS-only (Linux has `llimit accounts add/import`).
- **Sources:** MAIN AM-PROD-1.
- **Problem and evidence:** Add Account saves an enabled account and only then launches Claude/Codex sign-in (`APP/Views/SettingsView.swift:228-235`); discovery is a separate Scan button with "Nothing detected yet... tap Scan" copy (`:274`, `:287`); there is no Test Connection anywhere. The dropdown empty state (`APP/LLimitApp.swift:621-622`, `:733-843`) promotes Refresh (M01). A first-time user has to know which path fits each provider.
- **Proposal:** one guided flow: explicit choice of import or managed sign-in; a source and account chooser for detected logins; provider help per credential field; Test Connection (one client fetch before committing); verified completion; in-place reimport of an existing account. Setup works without the README and without a surprise scan. Complete credentials are not called verified until a fetch succeeds.
- **Tests / acceptance:** from an empty install a user reaches a verified first account for a manual-key, an import and a managed provider without the README; canceling sign-in leaves no account; Test Connection reports the failure kind and saves nothing; no scan runs until requested; reimport keeps id, style and history.
- **Relations:** MAC-02, PRV-25, PRV-26, BLD-10. R-UX-08 (canceled connects leave empty accounts). Linux in-place reimport is #104 (R-LNX-03).

### PRD-06 Best account to use now
- **Status / severity / effort / platform:** partial; proposal; S-M (estimate); ranking Linux-testable, quick pick macOS-only.
- **Sources:** MAIN AM-PROD-18 ("Availability/recommendation map"), AM-PROD-23 ("Quota roulette/quick pick").
- **Problem and evidence:** #108 ships `llimit pick` on `HeadroomRanking` in QuotaCore (minimum remaining across bounded metrics or a chosen kind; ties go to the sooner reset; stale and failing accounts excluded). #59 (MAIN-reported) tags the overview account with the highest bounded remaining headroom with a trophy. Two rankings now exist. BACKLOG Delight "Best model to burn" and "Quota roulette" (weighted by headroom).
- **Proposal:**
  - Make #59 use `HeadroomRanking` (the app links only QuotaCore).
  - Rank fresh, usable, comparable headroom, weighing reset proximity and spending blocks, and disclose uncertainty; percentages of different windows are not equal capacities.
  - macOS: an optional quick-pick button among fresh usable accounts above a configurable headroom floor (MAIN earlier proposed 60%), showing why others are ineligible; extend the menu tooltip. MAIN's optional `llimit recommend` is covered by `llimit pick`.
  - Never pick a stale, blocked or unknown account, and never switch a tool's login.
- **Tests / acceptance:** stale, failing, spend-blocked and unknown accounts are never chosen; the floor excludes; ties resolve to the sooner reset; unlike windows are flagged; one fixture yields the same choice for #59 and `llimit pick`.
- **Relations:** overlap #59 vs #108. Feeds IDEA-04 and IDEA-09. `status --worst` shares the ranking. A Spotlight widget for this was rejected (REF-05).

### PRD-07 Reset radar on macOS and in the tray
- **Status / severity / effort / platform:** partial; proposal; M (estimate); ordering Linux-testable (QuotaCore), dropdown macOS-only, tray via tray unit tests.
- **Sources:** MAIN AM-PROD-12 ("Reset radar/navigator").
- **Problem and evidence:** #51 (MAIN-reported) adds `llimit resets [--json] [--days N]` with pure `QuotaSnapshot.upcomingResets(now:within:)`, total ordering, 1-90-day validation, `snapshot`/`generatedAt` metadata, missing data distinct from an empty schedule, and a stale-schedule indication (older than one day). #88 also reports a reset listing. macOS shows resets only per row (`ResetChip`, `APP/LLimitApp.swift:512-529`); the tray formats per metric (`Packages/LLimitd/tray/llimit_tray.py:71-112`). BACKLOG Product #4.
- **Proposal:** add "Next resets" to the dropdown/dashboard and the tray, reusing `upcomingResets`: absolute server reset times in chronological order, labeled reported or estimated, with account links. Missing data differs from an empty schedule; a stale radar is not a fresh all-clear. Passed dates stay "reset due" until a replenishment is observed (BND-08). Compare underlying reset times, not a sentinel string; whitespace-only `resetIn` must not vanish silently.
- **Tests / acceptance:** total ordering with ties; a passed reset reads "reset due" until a fresh fetch shows replenishment; no snapshot reads "no data", not "no resets"; stale input is labeled.
- **Relations:** tray part is LNX-17 (needs `resetAt` in the JSON: #50 vs #105 key names). The bell and `llimit wait` are IDEA-02. A Reset Clock widget was rejected (REF-34). #82's near-reset glow is anticipation, not observed replenishment.

### PRD-08 In-app history and export
- **Status / severity / effort / platform:** partial; proposal; L (estimate); export rows Linux-testable, history view macOS-only.
- **Sources:** MAIN AM-PROD-5 ("In-app history/export").
- **Problem and evidence:** #88 (`llimit export`, JSON/CSV) and #98 (`llimit trend [--days N]`, per-account normalized forward-filled sparklines), both MAIN-reported, cover Linux. macOS keeps 45 days or 3,000 entries (`QC/QuotaHistoryStore.swift:31`, `:55-74`, about 31 days at 15 min) but reads two days for row sparklines (`APP/AppModel.swift:1759-1761`; `APP/LLimitApp.swift:408-455`) and has no history view or export. BACKLOG Product #2 and #5.
- **Proposal:** an in-app history view with reset and gap markers, selection and comparison, keyboard inspection and retention controls; Settings > General "Export History" producing credential-free CSV/JSON with source timestamps (`fetchedAt`, per #75) behind an explicit privacy preview. Keep `llimit export --format json|csv [--days 30]` as the original proposal and verify #88's actual flags. Large archives must not block the UI (PRF-03). Quota deltas are not token consumption or cost without reported units.
- **Tests / acceptance:** exports hold no credentials, subtitles or emails; carried values are not repeated; reset and gap markers appear; a maximum-size archive loads off the main actor; CSV escaping.
- **Relations:** #98's forward fill is not an observation. The 3,000 cap can truncate the 30-day trend (R-BUG-33, deferred in #94). The rejected burn-down and calendar widgets fold in here later (REF-35, REF-36).

### PRD-09 Honesty mode: labeled data provenance
- **Status / severity / effort / platform:** open (partly done); proposal; M (estimate); provenance model Linux-testable, labels per platform.
- **Sources:** MAIN AM-PROD-20; evidence from TMP R-BKL-05.
- **Problem and evidence:** already present: "≈" on rings, ESTIMATED badge on tiles, LAST KNOWN on cards, `stale`/`estimated` in the Linux JSON (BKL-06), and AUTO/ESTIMATED badge labels (MAIN-reported). Missing: labels for private endpoints and inferred window classification, LAST KNOWN on tiles and the dashboard, and last attempt/success/failure. Linux `stale` is a fixed 2 h constant (`LD/StatusRenderer.swift:130`). An old failure-free snapshot can say "All accounts reporting" after adding unqueried accounts (M01).
- **Proposal:** one shared provenance state per metric (verified, inferred, estimated, stale, unknown) derived from existing data (estimate flags, carried usage, current failure, per-account `fetchedAt`, classify rule), rendered as readable text or badges across the app, widgets and status output, not as more hues. Show last attempt, success and failure per account. Health claims count only fresh, covered accounts.
- **Tests / acceptance:** a fixture per state on each surface; the health line excludes stale, uncovered and unqueried accounts; no new identity hues; existing JSON keys unchanged.
- **Relations:** IDEA-10 is a detail view over the same data. W14 and L02 per-account age; #80 stale badge; #105 `fetchedAt`/`ageSeconds`.

### PRD-10 Automation companions
- **Status / severity / effort / platform:** partial; proposal; M (estimate); macOS-only for intents.
- **Sources:** MAIN AM-PROD-21.
- **Problem and evidence:** done on Linux: #108 `status --format` templates with tmux/starship/agent-wrapper examples, `--account`, `--worst`, `--kind`, `--watch` (deferred: presets `short`/`tmux`/`i3blocks`, `--worst N`); #88 `llimit compact` and #99 `llimit status --watch [seconds]` (MAIN-reported). The host app has no App Intents at baseline. BACKLOG Product #6 and #10.
- **Proposal:** Shortcuts read and refresh intents first (quota read from the credential-free snapshot; refresh through the app's refresh service); entities and Focus filters only after (REF-32). Raycast and Stream Deck hooks consume credential-free snapshots (`status --json`, or a macOS CLI per IDEA-03). Keep `llimit prompt`/`llimit status --compact` and optional ANSI `[Claude: 84% | GPT: 62%]` as original proposals, not mandatory aliases. Widget configuration intents stay out of scope (AGENTS.md). New providers need explicit auth and API maintenance scope, not guessed endpoints.
- **Tests / acceptance:** intent output contains no credentials, subtitles or failure messages; the refresh intent triggers one normal refresh; template presets render the documented strings.
- **Relations:** overlaps #108 vs #88 (compact output) and #108 vs #99 (`--watch`). Coding-agent integrations are IDEA-04, IDEA-05 and IDEA-09.

### PRD-11 Remove all LLimit data
- **Status / severity / effort / platform:** open; low (TMP); M; Linux-testable (daemon reset), macOS action manual.
- **Sources:** TMP R-FEAT-03 (GAPB-2).
- **Problem and evidence:** no way to wipe all stored credentials and data. Locations: `APP/AppModel.swift:86-100`, `QC/SettingsStore.swift:24-33`, `APP/Services/ClaudeProfileService.swift:35-38`, `:94-99`, `QC/CodexAccountService.swift:110-113`, `LD/LinuxPaths.swift:56-59`, `CLI/main.swift:22-43`. Overstated (unverified): leaving Application Support data after trashing an app is normal macOS behavior, the READMEs and `llimit paths` document the locations, and managed profiles are deliberately kept when cleanup is uncertain. The backup half duplicates BACKLOG "Credential security > Optional Keychain-backed storage" (backup and recovery policy).
- **Proposal:** "Remove All LLimit Data..." behind a confirmation and `llimit reset --all [--yes]`, both routed through per-account removal so pending namespaces are kept and reported (AGENTS.md). Delete the snapshot, history, App Group copies, settings, the lock sidecar and empty profile roots, then list anything retained. Document manual uninstall paths in the README.
- **Tests / acceptance:** on Linux a reset removes the files and reports injected failures; a pending namespace is retained and named; nothing is reported removed that was not.
- **Relations:** SEC-03, BND-04; overlaps COR-07's reset action.

### PRD-12 Explain failures with provider status pages
- **Status / severity / effort / platform:** open; proposal; M; Linux-testable.
- **Sources:** TMP R-NOV-05 (PRODUCT-16).
- **Problem and evidence:** failure cards (`APP/LLimitApp.swift:1624`) and Linux output (`LD/StatusRenderer.swift:55`) show only the error kind (`QC/Models.swift:247`), with no hint whether the provider has an incident. Unverified: the Statuspage endpoints and schemas were not checked, and providers often fail usage endpoints with no status-page incident.
- **Proposal:** an opt-in `ProviderStatusClient` (it reveals the user's providers to third parties) querying verified Statuspage `/api/v2/status.json` hosts, starting with status.anthropic.com and githubstatus.com. Query only after an account failed this cycle with `network`, `api` or `rateLimit`, at most every 15 min. Store a credential-free `QuotaSnapshot.providerStatus`; show "Anthropic reports a partial outage" on failure cards and in Linux output.
- **Tests / acceptance:** decoding fixtures; no request without a qualifying failure; the 15-minute limit holds; off by default.
- **Relations:** failure display C01 and #64/#105 failure keys; #77 `retryAt`.

### PRD-13 Help, About and updates
- **Status / severity / effort / platform:** open; proposal; L (estimate, update path depends on BLD-02); macOS-only.
- **Sources:** MAIN AM-PROD-7.
- **Problem and evidence:** the app has no About panel. `setLaunchAtLogin` (`APP/AppModel.swift:1218-1229`) treats every status other than `.enabled` as off, so a login item awaiting approval shows as disabled with no guidance (from source; not run natively). No localization infrastructure (M12). Release builds are ad-hoc signed (BLD-02). BACKLOG Product #7 (Sparkle).
- **Proposal:** About with build and version; launch-at-login approval state with guidance; provider help; localization; a redacted diagnostics preview and export; a signed, Sparkle-style update path after signing and notarization (BLD-02). Explain that widgets refresh only while the host app runs.
- **Tests / acceptance:** the diagnostics export holds no credentials, emails or raw failure bodies (fixture with secrets); the approval state shows guidance; the displayed version matches the bundle.
- **Relations:** BLD-02, M12; Linux `llimit version` (#83) and R-LNX-23 `doctor`. IDEA-10's shortcut is documented in Help.

### PRD-14 Live theme preview
- **Status / severity / effort / platform:** open; proposal; M (estimate); macOS-only.
- **Sources:** MAIN AM-PROD-3.
- **Problem and evidence:** the style preset picker is a text-only menu with no swatch or preview (`APP/Views/SettingsView.swift:560-578`), with the caption "Adjust any color below and the style becomes Custom" (`:572`). Users must place a widget to see a change.
- **Proposal:** a tile, dashboard row and trend preview beside the controls; explicit system, solid, pattern and transparent backgrounds; one-action reset to global; primary-override and window-color authority preserved; accessible neutral chrome. Begin with surface treatments. Proposed themes: Catppuccin Mocha (rosewater, mauve, sapphire, dark slate), Nord (frost, snow, polar night), Tokyo Night (indigo, neon), Monokai Pro (amber, magenta, cyan, charcoal), coordinated with #53's palettes (Standard, Ocean, Sunset, Forest, Vivid). Any palette or formula change needs contrast and CVD validation on graphite `#1D1F27` and widget blue `#5994F2`, not visual guesswork (WID-09).
- **Tests / acceptance:** the preview uses the same views as the widgets; changing a control updates it immediately; presets, custom and reset-to-global round-trip.
- **Relations:** builds on MAC-09 and MAC-11; WID-09; #53. Validated limit-color packs are blocked until the pale variant passes (R-THM-03).

### PRD-15 Type scale, spacing and a quiet hierarchy
- **Status / severity / effort / platform:** partial; low (TMP); M; macOS-only.
- **Sources:** TMP R-THM-07 (THEME-20); MAIN AM-PROD-4 ("Quiet hierarchy"), AM-WID-VC-2.
- **Problem and evidence:** done: badge legibility (MAIN-reported AUTO/ESTIMATED at 8 pt, 0.85 opacity, VoiceOver labels) and #109's trend axis and warning-chip work. Remaining: the dropdown uses 13 literal font sizes (8 to 26 pt) with near-duplicates such as 10 and 10.5, and corner radii of 7, 8 and 12 (`APP/LLimitApp.swift:291-303`, `:1308-1328`). Widget badges were 7 pt white at 0.6 on black at 0.25, 3.56:1 on the Anthropic tile (`WX/ProviderQuotaWidget.swift:457-475`; `WX/LLimitQuotaWidget.swift:186-199`).
- **Proposal:** `DashboardType` tokens (9, 10, 11, 13, 18) and `DashboardSpace` tokens (4, 8, 12, 16); an 8 pt floor for widget badges and axis labels; badges at white 0.85 on black 0.35; consistent baselines and tabular numbers; name and value first, reset and age second; restrained stripes, gloss and shadows, reserved warnings only (MAC-29).
- **Tests / acceptance:** screenshot comparison; controlled size, state and long-name captures show no clipping and respect accessibility text sizes; inspect 6.5-7 pt text at real desktop scaling.
- **Relations:** MAC-29; M05 contrast.

### PRD-16 App icon and brand mark
- **Status / severity / effort / platform:** open; medium (subjective polish, TMP); M; macOS-only.
- **Sources:** TMP R-THM-04 (THEME-10).
- **Problem and evidence:** the icon (`APP/Assets.xcassets/AppIcon.appiconset/`) is a full-bleed purple square with red, orange, yellow and green discs: no rounded body, no grid margin, no shadow, and traffic-light colors that contradict the color semantics. It shows in the Dock while Settings is open. The marks disagree: a gauge glyph in the header (`APP/LLimitApp.swift:692-709`, `:703`), `chart.bar.fill` as the fallback (`:228-233`), see also `:78`, and "LLM Quota" as the widget title (`WX/LLimitQuotaWidget.swift:347`, `:429`).
- **Proposal:** one mark: a graphite rounded rectangle with two concentric arcs in the session cyan and weekly amber. Author it in Icon Composer with default, dark and tinted variants, plus a grid-conformant PNG set for macOS 14 and 15. Reuse it as a template glyph for the fallback and header. Rename the widget header to "LLimit". Do not change widget kind strings.
- **Tests / acceptance:** manual review at all icon sizes and appearances; install-gate greps still find every kind literal.
- **Relations:** #55 provider glyphs.

### PRD-17 24-hour sparkline in the menu bar and tray
- **Status / severity / effort / platform:** open; proposal; M (estimate); macOS-only for the status item, tray via tray unit tests.
- **Sources:** MAIN AM-PROD-19.
- **Problem and evidence:** the dropdown already has per-metric 24 h sparklines (`APP/LLimitApp.swift:1536-1545`; BKL-06), so BACKLOG "Menu sparkline" is exceeded there. The status item draws only bars (`MenuBarIcon.iconImage`, `APP/LLimitApp.swift:163-218`), and the tray shows one icon per status class (`Packages/LLimitd/tray/llimit_tray.py:33`, `:170`).
- **Proposal:** an optional, bounded-width 24 h series for the most constrained account in the status item and tray. Coordinate with #98; preserve corrected observations, source gaps and normalization context. CLI forward fill is not evidence and must not feed forecasts.
- **Tests / acceptance:** a gap breaks the line; a reset shows as a riser; width stays bounded; the account choice matches the shared minimum rule.
- **Relations:** #98. The tray gauge idea is IDEA-17.

### PRD-18 What changed since the last observation
- **Status / severity / effort / platform:** open; proposal; S-M (estimate); comparison Linux-testable.
- **Sources:** MAIN AM-PROD-24.
- **Problem and evidence:** rows (`MetricQuotaRow`, `APP/LLimitApp.swift:1517`) and tray lines (`llimit_tray.py:71`) show only the current value.
- **Proposal:** a subtle up/down change on macOS and in the tray, measured from the previous real observation (source `fetchedAt`), with caveats for resets, estimates and key changes. Carried stale values show no change. Comparing the current snapshot alone must not invent measured consumption.
- **Tests / acceptance:** a carried value shows no delta; a reset reads as a reset, not "+80"; a key change suppresses the delta; an estimate is labeled.
- **Relations:** IDEA-07 (since-you-were-away brief).

### PRD-19 Coverage rail
- **Status / severity / effort / platform:** open; proposal; M (estimate); data model Linux-testable, rendering macOS-only.
- **Sources:** MAIN AM-PROD-15.
- **Proposal:** a neutral strip of observed and missing periods under the trend or history, with honest gaps and an accessible explanation, without repainting the identity traces.
- **Tests / acceptance:** a fixture with gaps renders missing segments; the AX text states the covered span; trace colors are unchanged.
- **Relations:** pairs with WID-11; PRD-08.

### PRD-20 Focus-session receipt
- **Status / severity / effort / platform:** open; proposal; M (estimate); delta logic Linux-testable.
- **Sources:** MAIN AM-PROD-10; BACKLOG Delight "Focus-session budget".
- **Proposal:** an explicit Start/Stop reports per-account quota deltas from fresh observations, with reset and estimate caveats. No extra inference calls (a forced refresh would also run the Muse probe, which costs tokens) and no activity surveillance.
- **Tests / acceptance:** a session spanning a reset; an estimated metric; start and stop trigger no extra provider request.
- **Relations:** a per-project ledger was rejected (REF-33).

### PRD-21 Quota passport
- **Status / severity / effort / platform:** open; proposal; S (estimate); text builder Linux-testable.
- **Sources:** MAIN AM-PROD-11.
- **Proposal:** one accessible plain-text summary of quota, resets and source ages to paste into a handoff or chat. No credentials or emails (exclude `ProviderUsage.subtitle`, which holds an Antigravity email), and unknown stays unknown.
- **Tests / acceptance:** output excludes subtitles, failure messages and credentials; unknown and unlimited are named; ages are explicit.
- **Relations:** overlaps IDEA-10's Copy Details; share one builder.

## New ideas (ideation pass)

TMP's ideation pass (2026-10-07): three ideators (delight, power-user and visual lenses) proposed 34 ideas. Each was checked against the code at `2d6ac1e`, against BACKLOG.md and against the review findings. Near-duplicates were merged, and ideas already covered by an R-NOV, R-LNX or BACKLOG entry were dropped or kept only as extensions. The entries below are ranked with the most useful first, then delightful or novel, and merged with the matching MAIN product proposals (AM-PROD-14, -16, -17, -22). Line numbers refer to `2d6ac1e`. Path prefixes: QC/, LD/, CLI/, APP/, WX/ as elsewhere, plus TRAY/ = `Packages/LLimitd/tray/`. Claims about commit `4768e74` (the `feat/reset-celebration` branch) are unverified: that branch was not in the review checkout. Ideas this pass rejected are listed in the refuted section, not here.

IDEA-04 and IDEA-05 rely on Claude Code behavior that was checked against the official status line and hooks docs on 2026-10-07:

- The status line command receives `session_id`, `workspace.project_dir`, `cost.total_cost_usd` and, for Pro and Max subscribers after the first response, `rate_limits.five_hour` and `rate_limits.seven_day`, each with `used_percentage` (0 to 100, fractional) and `resets_at` (epoch seconds). Each window can be absent and is dropped once it resets. Updates are debounced at 300 ms, and the next update cancels a script that is still running.
- `SessionStart` and `UserPromptSubmit` hooks accept `hookSpecificOutput.additionalContext`. Exit code 2 blocks a `UserPromptSubmit` prompt. `StopFailure` fires when a turn ends on an API error and matches on `error_type` (`rate_limit`, `authentication_failed`, and others). Its output and exit code are ignored.

### Shared building blocks

Several ideas need the same pieces. Build each one once:

- **Observed reset.** A pure `QuotaEvents.observedReset(previous:current:)` in QuotaCore, built with #110's `QuotaEvents` (this is R-LNX-21's reset event; build it there if #110 has not landed). It returns true when all of these hold:
  - the current `ProviderUsage` is fresh (its `fetchedAt` is later than the previous one);
  - its `fetchedAt` is later than the previous metric's `resetAt`;
  - `resetAt` moved forward, or remaining rose by more than 4 points (the trend chart's refill rule).

  Never declare a reset from the clock alone (R-BUG-08, R-BUG-21). Note for integration: #110's unmerged `QuotaEvents` already has a `reset` event with reset-time jitter tolerance, but it only fires for windows that reached the highest alert threshold; the celebration, receipts and wait verbs need every reset, so share the rule without that gate.
- **Snapshot enrichment.** One pure QuotaCore stage, `SnapshotEnrichment.apply(previous:current:ledger:now:)`. It runs before the save on both platforms: in `AppModel.publishSnapshot` (`APP/AppModel.swift:274`, before the history append) and in `QuotaDaemon.refreshNow` (`LD/QuotaDaemon.swift:283-316`, before `snapshotStore.save`). It stamps optional, credential-free fields that the display surfaces read, so StatusRenderer and the widgets stay snapshot-only. `UsageMetric` uses synthesized Codable, so new optionals decode as nil from older files. `ProviderUsage` has custom coding (`QC/Models.swift:357-381`) and needs explicit `decodeIfPresent`.
- **Usage ledger.** A small credential-free `usage-ledger.json` next to the history file (the App Group on macOS, `$XDG_DATA_HOME/LLimit/` on Linux, mode 600). Per (account id, metric id, window kind) it holds the open window's fresh samples from the last 24 h, its minimum remaining and its first time at 0, plus closed-window rows capped at about 500. It is kept outside the 3,000-entry history cap (R-BUG-33, deferred by #94) and spares the main actor a history decode (R-PERF-01). Account removal purges it together with `purgeHistory`.
- **macOS command line.** IDEA-03 brings the read-only CLI to macOS. Until it ships, the CLI-based ideas (IDEA-02, 04, 05, 09, 14 and the Linux halves of others) are Linux-only.

### IDEA-01 Blocked state: "back 16:05" on every surface
- **Status / severity / effort / platform:** open; idea, rank 1; M; macOS (tile, dropdown, menu bar) and Linux (JSON, bars, tray); Linux-testable.
- **Sources:** TMP R-IDEA-01 (ideators: visual "Back in 2h 14m"; the status-item countdown from delight "Wake me when it's back"). Extends BACKLOG "Fresh, stale, failed, and unknown state" and "Menu-bar icon and quick actions".
- **Problem and evidence:** When a window is exhausted, the user's question changes from "how much is left" to "when can I work again". Today the tile shows the account name over an empty ring (layout `WX/ProviderQuotaWidget.swift:422-477`, rings `:705-790`) and Linux prints "0%". TMP states that OpenCode Go's `rate-limited` status already forces 100% used (`QC/Clients/OpenCodeGoQuotaClient.swift:89-104`). Checked for this section: at baseline the guard at `:90-91` accepts `rate-limited` only when `percent == 100` and otherwise throws `invalidResponse`, failing the fetch. MAIN-reported #81 renders `rate-limited` windows as exhausted at any percent, so with #81 OpenCode Go rate limits count as blocked. Devin and Muse cannot report exhaustion today (R-BUG-02, R-BUG-23).
- **Proposal:**
  - Rule: an account is blocked when any bounded metric is at 0% remaining, until the latest `resetAt` among its exhausted metrics.
  - `QC/BlockState.swift`: pure `BlockState.of(_ usage: ProviderUsage, now:)` returning `.available`, `.blocked(until: Date?, metricIDs: [String])` or `.resetDue`. A carried metric of a failing account counts only while its `resetAt` is in the future (R-BUG-08).
  - Tile: the exhausted ring keeps its empty track and gains a thin outline in the reserved red; the center shows a live countdown (`Text(timerInterval:countsDown:)`) over a "back in" caption; the account name moves to the footer; the other ring keeps its identity hue. Add a timeline entry at the blocked-until time (the provider already precomputes entries at `WX/ProviderQuotaWidget.swift:176-211`).
  - Dropdown card: header chip "Blocked · back 16:05 (in 2h 14m)" with a `pause.circle` glyph so the state does not depend on color. Files: `ProviderQuotaCard` (`APP/LLimitApp.swift:1332`), `ResetChip` (`:512`).
  - Menu bar (opt-in, Settings > General > "Show return time when blocked", a new `@AppStorage` flag): when every enabled account of a provider is blocked, the soonest return time ("16:05") follows the bars. An absolute time needs no per-minute redraw. File: `MenuBarIcon.iconImage` (`APP/LLimitApp.swift:174-218`).
  - No reset time: "Blocked, reset time unknown". After blocked-until passes and before a fresh fetch, show R-BUG-21's "reset due" state, never the old 0%.
  - Linux (`LD/StatusRenderer.swift:104-200`, `TRAY/llimit_tray.py`, reusing R-LNX-02's live countdown): additive per-account `blocked: true` and `blockedUntil` (ISO 8601); the `text` segment reads "Claude 0% (back 16:05)"; the tray account header reads "blocked, back 16:05"; `class` values are unchanged.
  - Constraints: clients round to whole percents, so a 0 can hide a fraction of a percent; word it as "limit reached" and never disable anything. Reserved red only for the outline and the chip, never a ring fill.
- **Tests / acceptance:** QCT and LDT cases for one exhausted window; two exhausted windows (the latest reset wins); a missing `resetAt`; a carried 0% past its reset is `.resetDue`; the JSON keys appear only when blocked.
- **Relations:** Depends on WID-02 (R-BUG-21's reset-pending entry: a widget countdown runs on the system clock and can pass blocked-until before the next refresh) and on #105's expiry of carried metrics (R-BUG-08, LED-17) and live countdowns (R-LNX-02). Menu-bar part must land with #96 (R-VIS-07, R-UX-05), which edits the same drawing. Devin reaches this state once #89 (R-BUG-02) merges; Muse needs R-BUG-23. R-UX-09's severity model can share the helper. StatusRenderer edits overlap #95, #105 and MAIN-reported #64/#50 key sets. IDEA-15 reuses the blocked outline; IDEA-02 offers the bell from the same chip.

### IDEA-02 Reset bell, `llimit wait` and `llimit at-reset`
- **Status / severity / effort / platform:** open; idea, rank 2; M; macOS (bell, notification) and Linux (`wait`, `at-reset`); the CLI verbs reach macOS through IDEA-03; Linux-testable.
- **Sources:** TMP R-IDEA-02 (ideators: delight "Wake me when it's back"; power "Reset-aware scheduling"). Extends BACKLOG Product #1 (reset alerts) and #4 (reset radar).
- **Problem and evidence:** When a limit is hit, nothing tells the user when that window is back as confirmed by a fresh fetch rather than the clock, and scripted agent runs fail halfway instead of waiting for headroom. At baseline the app does not use `UNUserNotificationCenter` (no match under `LLimitApp/` at `2d6ac1e`); MAIN-reported #100 adds it for threshold notifications.
- **Proposal:**
  - macOS bell: on a metric row at 5% or less, `ResetChip` gains a bell button, "Notify me when it's back". The first click requests notification permission, and only then; clicking again disarms; nothing happens until the user arms it. At `resetAt` + 90 s LLimit fetches that one account. If `observedReset` confirms, post "Claude Work is back: 5-hour window reset, 100% left." (sound is a Settings > General choice: None or Default). If not confirmed, retry once at +5 min, then post "Claude Work has not reported a reset yet. LLimit keeps checking on its normal schedule." and disarm.
  - macOS build: armed records (account id, metric id, `resetAt`) in UserDefaults, no credentials; a `ResetBellService` owned by AppModel schedules one task per record and fetches through the existing single-account path (`refreshService.fetch(configurations:)` plus `replacingResults`, as at `APP/AppModel.swift:336-340`); notifications through `UNUserNotificationCenter`.
  - `llimit wait <account|provider> [--metric <id|kind>] [--min 1] [--timeout 6h] [--refresh] [-- <cmd…>]`: exits 0 at once when the account already has the headroom; otherwise prints "Waiting for Claude Work 5-hour: resets 14:05 (in 1h 12m)" to stderr and watches the snapshot file's mtime, making no provider calls; succeeds only on a fresh snapshot fetched after the old `resetAt` that shows remaining >= `--min`; `--refresh` sends one coalesced refresh request (R-LNX-04) at `resetAt` + 2 min; `-- <cmd…>` execs the command on success without a shell; exit codes 0 ready, 1 timed out, 2 account failing, 3 no data or unknown account; without a `resetAt` it keeps watching and says "reset time unknown".
  - `llimit at-reset <account> [--metric <id|kind>] -- <cmd…>`: schedules `llimit wait <account> --timeout 1h -- <cmd…>` as a transient user timer, `systemd-run --user --on-calendar=<resetAt + 2 min> --unit=llimit-at-<id>`; `--list` and `--cancel <id>` wrap `systemctl --user list-timers` and `systemctl --user stop`.
  - QuotaCore: `observedReset` plus a pure `WaitCondition.evaluate(snapshot:target:min:previousResetAt:now:)` returning `.ready`, `.waiting(until:)`, `.failing` or `.noData`. Linux: dispatch in `CLI/main.swift:403-416`, account matching through `QuotaDaemon.resolveAccountID` (`LD/QuotaDaemon.swift:219`), a pure `systemd-run` argv builder.
  - Constraints: Anthropic hard-rate-limits fast pollers, so allow at least 3 min since that account's last fetch. Managed Codex fetches respect `codexBusyAccounts` and operation records. Notification text carries only the display name and metric label, never the subtitle (Antigravity puts an email there) or failure messages. Ad-hoc signed builds may not get notification authorization (unverified; see "Signed, widget-capable distribution"): show a visible error when authorization fails. Transient timers are lost on reboot, and on logout unless lingering is enabled; say so in `--help`. The command persists in the unit, so warn against secrets in argv (R-SEC-04). Unattended runs happen only on explicit user command. Rolling windows (OpenCode Go `rolling`, Claude 5-hour) move; the fresh-fetch confirmation covers that.
- **Tests / acceptance:** the condition for ready, waiting, failing, and carried values past the reset; exit codes; argv building; the bell's retry timing.
- **Relations:** Needs #110's `QuotaEvents` (observedReset); complements PRD-07. Fix R-BUG-27 first (single-account refreshes mark the whole snapshot fresh and copy other accounts into history). Exit codes follow #108's `check` (0/1/2/3), which conflicts with MAIN-reported #97 (exit 1 with reasons): settle one contract before adding `wait`. Reuse #100's notification plumbing rather than a second stack. R-LNX-04 (coalesced refresh) is still open. MAIN-reported #51 (`llimit resets`) covers the reset radar listing. IDEA-14 shares the snapshot-mtime watcher.

### IDEA-03 macOS command-line helper over a snapshot mirror
- **Status / severity / effort / platform:** open; idea, rank 3; M (L if release signing is not fixed first); macOS; partly Linux-testable (path resolution, read-only guard).
- **Sources:** TMP R-IDEA-03 (ideator: power). Extends BACKLOG Product #10 (redacted CLI/status-line companion).
- **Problem and evidence:** Terminal and agent integrations need `llimit`, and the Mac, the primary platform, has none. SwiftBar, SketchyBar, Raycast script commands, starship, tmux, and IDEA-02, 04, 05, 09 and 14 cannot work on macOS. Nothing builds LLimitd on macOS today (R-BLD-10, BLD-08), although AGENTS.md says its tests run in macOS CI.
- **Proposal:**
  - Snapshot mirror: on each publish, `APP/AppModel.swift:274` (`publishSnapshot`) also writes the credential-free snapshot to `~/Library/Application Support/LLimit/quota-snapshot.json` (mode 600, next to the settings) with the same encoder as `SnapshotStore`.
  - Helper: `LLimit.app/Contents/Helpers/llimit`, the LLimitd CLI built for macOS. Read-only verbs only: `status` (all formats), `check`, `pick`, `wait`, `mcp`, `statusline`, `hook` and `paths` work; `accounts`, `refresh` and `daemon` print "Manage accounts and refreshes in LLimit." and exit 2. `CLI/main.swift` gets an `#if os(macOS)` guard that rejects mutating verbs before any settings access.
  - Paths: `LD/LinuxPaths.swift` gains a macOS resolver (or a small `StatusPaths` protocol) returning the mirror path; the XDG resolver stays unchanged.
  - Install: Settings > General > "Install Command-Line Tool" creates a symlink in `~/.local/bin` (no admin needed) and shows the PATH line to add; for `/usr/local/bin` it shows the `sudo ln -s` command instead of asking for authorization.
  - Release: `.github/workflows/release.yml` and `project.yml` build `Packages/LLimitd` in release mode for arm64 and x86_64, combine with `lipo`, and copy into `Contents/Helpers` before signing.
  - Examples: a SwiftBar plugin, a SketchyBar item, a Raycast script command and a starship module, all reading `status --json`.
  - Constraints: a Terminal-launched process reading another app's Group Container probably triggers macOS 15's "access data from other apps" prompt (unverified); the Application Support mirror avoids it. The nested helper must be signed with the hardened runtime and notarized with the bundle. The helper never races AppModel's settings writes; asking the app to refresh would need an app URL scheme ("Actionable account state"), so v1 leaves it out. Keys are only added, never renamed.
- **Tests / acceptance:** macOS path resolution; mutating verbs never open the settings file; golden `status --json` output identical to Linux for the same snapshot (one renderer, golden tests on both platforms).
- **Relations:** Closes BLD-08's LLimitd-on-macOS gap. Needs signing work (BLD-02). Exposes #108's `check`/`pick`/`status --format` and MAIN-reported #83 `--version` on macOS; #108 also makes `status` snapshot-only, which the mirror relies on. The mirror's mode-600 write can reuse MAIN-reported #74's `writeOwnerOnlyAtomically`. Prerequisite for the macOS halves of IDEA-02, 04, 05, 09 and 14.

### IDEA-04 Claude Code status line with the next-best account
- **Status / severity / effort / platform:** open; idea, rank 4; M; Linux, macOS through IDEA-03; Linux-testable.
- **Sources:** TMP R-IDEA-04 (ideator: power). New; extends BACKLOG Delight "Best model to burn".
- **Problem and evidence:** After every response Claude Code already passes its status line the session's own 5-hour and 7-day usage (facts at the top of this section), but nothing shows it next to the user's other subscriptions, and LLimit's own reading is 15 to 30 minutes old. Linux imports carry no verified identity: `scanClaudeCode` stores only the access token (`QC/CredentialDiscovery.swift:94-122`).
- **Proposal:**
  - Phase 1, display only: `llimit statusline claude-code [--account <prefix>] [--format …]` as Claude Code's `statusLine.command`. It reads the stdin JSON and prints one line, for example `5h 62% · wk 18% left, resets Thu 09:00 | next: Codex Work 81% wk`. The right half comes from the snapshot through `HeadroomRanking` and excludes the pinned account; without a pin it shows the best non-Anthropic account. The right half is omitted when nothing qualifies or the snapshot is older than 2 refresh intervals. `--format` reuses R-LNX-20's placeholders.
  - Phase 2, opt-in `--observe` sensor: writes a credential-free observation to `$XDG_DATA_HOME/LLimit/observations/claude-<sha8 of config dir>.json` with `observedAt`, the two windows, and the account and organization UUIDs from `oauthAccount` in `$CLAUDE_CONFIG_DIR/.claude.json` (or `~/.claude.json`); atomic, mode 600, only on change, at most every 30 s. The daemon does a stat-only check each minute (no network). Daemon and app merge an observation into an account's `five_hour` and `seven_day` metrics only when the account's stored verified identity equals the observation's account and organization UUIDs and `observedAt` is later than the account's `fetchedAt`. Merged metrics read "via Claude Code, 2 min ago"; `seven_day_opus` and other windows keep polled values.
  - Build: QuotaCore `ClaudeStatusLineInput` decoder (every field optional) and `ClaudeObservation` with `validate()`, reusing `ClaudeCodeProfile.parseIdentity` (`QC/ClaudeCodeProfile.swift:116`) and `identity(from:)` (`:134`); the `statusline` verb in `CLI/main.swift` and a pure renderer in a new `LD/StatusLine.swift`; phase 2 adds `mergingObservations(_:accounts:)` to `QC/SnapshotMerge.swift` and optional `UsageMetric.source` (`polled` or `claudeCode`) and `observedAt`.
  - Constraints: the command runs on every update and is cancelled when slow, so it reads only the snapshot, never the settings file, Claude's credential files, or the network. The UUIDs are personal, not secret: keep them in the mode-600 observation files, out of the snapshot, history, widgets and status JSON. `rate_limits` appears only for Pro and Max subscribers after the first response; treat every field as optional and validate ranges (0 to 100, `resets_at` within 8 days). A `--account` pin may steer phase 1's display text, never phase 2's merge.
- **Tests / acceptance:** input fixtures with and without `rate_limits`; a missing window stays unknown; identity mismatch and missing identity never merge; an older observation never overwrites a newer fetch.
- **Relations:** Never binds an observation to "the only Claude account" (BND-03, AGENTS.md hard constraints). Phase 2 helps only accounts with verified identity: managed macOS profiles, or Linux accounts once R-LNX-18 lands. Ranking from #108's `HeadroomRanking` (PRD-06; share one ranking with MAIN-reported #59's overview trophy); placeholders from #108's `status --format`. The per-project quota ledger built on this sensor was rejected (refuted section).

### IDEA-05 Claude Code hooks
- **Status / severity / effort / platform:** open; idea, rank 5; M; Linux, macOS through IDEA-03; Linux-testable.
- **Sources:** TMP R-IDEA-05 (ideator: power). Extends BACKLOG Product #1.
- **Problem and evidence:** Claude Code does not know it is on its last 10% of the weekly limit before it plans a 40-file refactor, and when a turn dies on a rate limit nobody tells the user when the limit resets or which account still has headroom. Hook capabilities are listed at the top of this section.
- **Proposal:**
  - Command: `llimit hook claude-code <session-start|prompt|stop-failure> [--account <prefix>] [--below 25]`.
  - SessionStart: silent while every bounded window of the bound account is above the threshold; below it, emit `hookSpecificOutput.additionalContext`, for example "Quota note from LLimit (data 4 min old): this Claude account has 12% of its weekly limit left; it resets Thu 09:00. Prefer focused changes and avoid large parallel fan-out."
  - UserPromptSubmit: adds the same note once per threshold crossing per session. Opt-in `--block-below N` exits 2 with a reason; sending the same prompt again passes once.
  - StopFailure (matcher `rate_limit`): output is ignored, so act only through side effects: a `notify-send` notification ("Claude Max hit its limit. Resets 14:05. Codex Work has 81% weekly left.") and, once R-LNX-04 exists, one coalesced refresh request.
  - Binding, in order: the account whose verified identity matches `.claude.json`; the `--account` pin; otherwise say "your Claude account" and give no numbers.
  - Install: `llimit hook install claude-code` only prints the `settings.json` snippet; it never edits the user's settings in v1.
  - Build: new `LD/AgentHooks.swift` with pure builders (snapshot, binding, policy, dedupe state, now) to hook output JSON; dedupe state in `$XDG_DATA_HOME/LLimit/hook-state.json` (credential-free, mode 600, entries pruned after 24 h); crossings reuse `QuotaEvents.detect`.
  - Constraints: hooks run on every prompt, so read only the snapshot, aim for tens of milliseconds, and send refresh requests fire-and-forget. Injected context costs tokens and steers the model: one or two factual sentences, nothing while healthy. Prompt blocking is opt-in only. Always state the data's age so an agent does not trust a 6-hour-old value. Never output credentials, subtitles or provider failure messages.
- **Tests / acceptance:** silent while healthy; one note per crossing; block, then override; stale-snapshot wording; no failure messages in the output.
- **Relations:** Builds on PRD-04 and on #110's `QuotaEvents.detect` (20%/5% crossings) and dedupe pattern; #110's `--on-event` hook examples are daemon-side and complementary. Gap: `notify-send` is Linux-only, and TMP names no macOS notification path for StopFailure; #100's (MAIN-reported) notification service would be the candidate. R-LNX-04 is still open. Shares binding rules with IDEA-04.

### IDEA-06 Observed reset moment on macOS and Linux
- **Status / severity / effort / platform:** open; idea, rank 6; S; macOS (tile, dropdown) and Linux (JSON, CSS, tray); Linux-testable.
- **Sources:** TMP R-IDEA-06 (ideator: delight; extends BACKLOG Delight "Reset celebration"); MAIN AM-PROD-14 ("Observed reset receipt").
- **Problem and evidence:** A reset should be celebrated only after the data shows it happened, and waybar, eww and the tray have no equivalent moment. MAIN reports #82 as a near-reset pulsing ring glow within five minutes (reported in the reset-radar work): anticipation, not verified replenishment. TMP's ideator reports two problems in commit `4768e74` on this branch (likely the same glow work; unverified, branch not in the checkout): it glows whenever `abs(resetAt - entry.date) < 300 s`, which also lights stale data that never reset, and it adds a `repeatForever` animation that a widget never runs. Check both before that branch merges.
- **Proposal:**
  - Stamp: the enrichment stage stamps an optional `UsageMetric.lastResetObservedAt` (`QC/Models.swift:257`) when `observedReset` fires; later cycles carry it forward.
  - macOS: the Reset Celebration tile treatment shows for 30 minutes after the stamp instead of keying on `resetAt` alone; the dropdown ring gets the same one-time treatment with "Refilled 09:12" text, shown only after verified replenishment (MAIN). The treatment is static (widgets do not run continuous animations); MAIN allows an optional restrained tick or ring bloom that respects Reduce Motion, with no looping widget animation. `WX/ProviderQuotaWidget.swift`: the ring, plus a timeline entry at stamp + 30 min that ends the glow.
  - Linux: per-metric `justReset: true` and per-account `fresh: true` during the 30 minutes (`LD/StatusRenderer.swift:80-100` `metricObject` and `:104-200`); opt-in `llimit status --json --class-array` emits `class` as an array (for example `["ok","fresh"]`) so waybar CSS can style `.fresh` (flag in `CLI/main.swift`); `Packages/LLimitd/examples/waybar/llimit.css` ships a commented-out two-pulse GTK animation; the tray (`TRAY/llimit_tray.py`) adds "reset 4 min ago" to the account header, text only.
  - Constraints: `class` as an array would break eww and polybar readers, so it stays behind the flag; confirm that the minimum supported waybar accepts an array. GTK animations follow `gtk-enable-animations`; confirm in waybar before documenting the example. A dedicated tray icon would need light and dark variants.
- **Tests / acceptance:** a fresh fetch past `resetAt` with a forward `resetAt` stamps; a carried value never stamps; the stamp survives one cycle and then expires; the default `class` stays a string.
- **Relations:** Distinct from #82's countdown glow; reconcile with `4768e74` rather than adding a second ring effect. Respect Reduce Motion (MAC-07). The tray uses text only until LNX-09 (light and dark tray icons) lands. Needs #110's `QuotaEvents` for `observedReset`. StatusRenderer edits overlap #95 and #105. Same reset event feeds IDEA-02 and IDEA-11; IDEA-12, #103's ring ticks and R-VIS-09 touch the same ring drawing.

### IDEA-07 Since you were away
- **Status / severity / effort / platform:** open; idea, rank 7; S; macOS and Linux; Linux-testable.
- **Sources:** TMP R-IDEA-07 (ideator: delight). New.
- **Problem and evidence:** After a long gap the user has to compare up to twelve rings to see what changed.
- **Proposal:**
  - macOS: when the dropdown opens 6 h or more after the last open, a one-sentence brief replaces the "Updated 4m ago" header line for that open only, in `dashboardHeader(now:)` (`APP/LLimitApp.swift:692`). Examples: "Since last night: Claude 5-hour and Codex weekly reset. Tightest now: Kimi weekly 18%, resets Fri 09:00." and "Since yesterday: no resets. Venice started failing (auth)." When the data is stale, the age stays visible next to the brief (R-UX-03). When nothing changed, no brief appears. Save `SeenState` and the open time in UserDefaults when the dropdown closes; no history decode.
  - Linux: `llimit brief [--once-per 8h]` for `.bashrc`, `fish_greeting` or the MOTD; prints the same sentence at most once per period, nothing when nothing changed; never touches the network; always exits 0. State in `$XDG_STATE_HOME/LLimit/brief-seen.json` (add `stateHome` to `LD/LinuxPaths.swift`); a `brief` verb in `CLI/main.swift`.
  - QuotaCore: a compact `SeenState` (per account and metric: remaining, `resetAt`, failure kind; no names or messages) and a pure `Brief.make(seen:current:now:) -> String?` using `observedReset`, failure-kind transitions, and the minimum rule from `MenuBarQuotaStyling` moved into QuotaCore.
  - Constraints: shell startup must stay fast, so read only the snapshot and the seen file and never wait on `SettingsLock`. Names come only from the snapshot title; failures appear as kinds, never messages.
- **Tests / acceptance:** resets; a failure appearing and clearing; nothing changed; the once-per period; a missing or corrupt seen file.
- **Relations:** Related to PRD-18. #95 implements R-UX-03's header age; the brief must keep that age visible. #96 deferred sharing level and failure-matching rules out of `MenuBarQuotaStyling`; move the minimum rule once for both.

### IDEA-08 Account badges
- **Status / severity / effort / platform:** open; idea, rank 8; M; macOS, Linux gets a JSON key; partly Linux-testable.
- **Sources:** TMP R-IDEA-08 (ideator: delight). Extends R-UX-01 (second identity channel) and R-A11Y-01.
- **Problem and evidence:** Accounts of the same provider are told apart only by the base, deep and pale color variants. Users want to mark "Work" with a briefcase and "Personal" with a house.
- **Proposal:**
  - Choosing: on an account's Settings page, pick one of about 24 curated SF Symbols present on macOS 14 (briefcase, house, flask, graduationcap, building.2, person, star, leaf, and so on). Default none keeps today's look.
  - Model: `ProviderStyleSettings.badgeSymbol: String?` (`QC/Models.swift:1110`), decoded with `decodeIfPresent` and validated against a curated list in QuotaCore. The field already travels in the redacted settings the widget reads.
  - Surfaces: corner of `ProviderMark` (`APP/LLimitApp.swift:1465-1500`); beside the name under each Overview gauge (`OverviewCard`, `:1175`); the tile's top-left corner where "#3 AUTO" sits today (`WX/ProviderQuotaWidget.swift:459`); the trend chart's endpoint marker (`WX/LLimitQuotaWidget.swift:228`).
  - Linux: additive per-account `badge` key (the symbol name); the daemon stamps the badge into the snapshot because StatusRenderer must not read settings.
  - Constraints: monochrome glyphs only, never a second color channel; curate only macOS 14 symbols so a widget never renders a missing symbol; choose for legibility at 8 pt, not variety.
- **Tests / acceptance:** curated names are unique and decode; unknown names become nil; a macOS script test in `scripts/tests/` asserts every curated name resolves with `NSImage(systemSymbolName:)` on macOS 14.
- **Relations:** The user-facing form of WID-06's non-color marker channel; without a badge, R-UX-01's automatic marker (circle, square, diamond, triangle) is the fallback for 4 or more accounts. MAIN-reported #55 changes `ProviderMark` symbols (R-THM-05). IDEA-15 marks pool segments with badges. Daemon stamping shares the enrichment step with IDEA-15 and IDEA-17.

### IDEA-09 Read-only `llimit mcp` server
- **Status / severity / effort / platform:** open; idea, rank 9; M; Linux, macOS through IDEA-03; Linux-testable.
- **Sources:** TMP R-IDEA-09 (ideator: power). Extends BACKLOG Delight "Best model to burn" and R-NOV-03.
- **Problem and evidence:** Before a long unattended run or a large subagent fan-out, an agent or orchestrator cannot ask how much quota is left or which subscription should take the job; today it finds out from a rate-limit error.
- **Proposal:**
  - `llimit mcp`, a stdio MCP server, in a new `LD/MCPServer.swift`: newline-delimited JSON-RPC 2.0 on JSONSerialization (LLimitd has no third-party dependencies), handling `initialize` (with version negotiation), `tools/list`, `tools/call` and `ping`.
  - Tools: `quota_status(provider?, account?)` returns per account id, name or alias, provider, `ageSeconds`, `stale` and `failureKind` (kind only), and per window the kind, `remainingPercent`, ISO `resetAt` and `estimated`. `recommend_account(providers?, window_kind?, min_remaining?)` returns a ranked list with one-line reasons ("weekly 72% left, resets in 2d; 5-hour 90%"); ties go to the sooner reset; stale and failing accounts are excluded. `time_until_headroom(account, min_remaining)` returns an ETA from `resetAt`, or "unknown". No refresh tool in v1, so agents cannot hammer Anthropic's rate-limited endpoint.
  - Disclosure is set on the command line in the MCP client config, so the server never reads settings: `--accounts <prefix,…>` limits visible accounts; `--names alias` replaces names with the provider plus an ordinal ("Claude #2").
  - Docs: `claude mcp add llimit -- llimit mcp --names alias`; a Codex `[mcp_servers.llimit]` block; an OpenCode `mcp` entry; an AGENTS.md snippet "Before more than 3 parallel subagents or an unattended run, call recommend_account."
  - Constraints: tool results go to the agent's model provider, including which subscriptions the user holds, and some free models train on prompts, so documented snippets default to aliases and minimal fields. Every result states its staleness.
- **Tests / acceptance:** protocol handshake fixtures; tool results for a mixed snapshot; aliasing; a file-access spy proves the settings file is never opened.
- **Relations:** Never returns failure messages, which can echo response bodies (BND-01, R-DEBT-02). Uses PRD-06's ranking (#108's `HeadroomRanking`, shared with MAIN-reported #59). Per-metric `resetAt` and data age need R-LNX-02 (#105; MAIN-reported #50 overlaps).

### IDEA-10 Option-click details and `status --explain`
- **Status / severity / effort / platform:** open; idea, rank 10; S; macOS and Linux; Linux-testable (explanation lines).
- **Sources:** TMP R-IDEA-10 (ideator: delight). Extends BACKLOG Delight "Honesty mode" and "Actionable account state" (sanitized copyable diagnostics).
- **Problem and evidence:** Users cannot see what LLimit knows versus what it inferred about each limit (for example the window kind, which `QuotaWindowKind.classify` at `QC/Models.swift:804` parses from ids and labels), nor copy it into a bug report.
- **Proposal:**
  - Trigger: holding Option while the dropdown opens, or pressing it while open, swaps each metric row's secondary line for: the metric id; the inferred window kind and why ("weekly, from label 'Weekly limit'"); `resetAt` in local time and UTC; the exact `fetchedAt`; reported or estimated ("≈, total 1,240 DIEM observed"); carried or fresh ("carried from 14:02; latest fetch failed: network"). Releasing Option restores the normal view.
  - Copy Details: each card gains a button that copies those lines as plain text.
  - Without a modifier: a "Show Details" menu item toggles the same view for VoiceOver and Switch Control users, who cannot hold a key.
  - Linux: `llimit status --explain` prints the same lines.
  - Build: a pure QuotaCore `MetricExplanation.lines(usage:metric:failure:now:)` shared by both platforms, plus a `classify` variant that reports which rule matched; a `flagsChanged` local monitor in `MenuBarContent` (`APP/LLimitApp.swift:533`) and the row in `MetricQuotaRow` (`:1517`).
  - Constraints: exclude `ProviderUsage.subtitle` (Antigravity stores an email there) and `ProviderFailure.message` until BACKLOG's redaction boundary lands; never read settings or credentials. Mention the shortcut in Help or About, as macOS documents Option-clicking the Wi-Fi menu. Keep it a detail view, not a second dashboard.
- **Tests / acceptance:** the reason string for each `classify` rule; estimated and carried wording; output never contains subtitles or failure messages.
- **Relations:** Supports PRD-09 and PRD-21. The redaction boundary is MAIN C01's structured display boundary. The "carried" wording depends on #105's carried-metric expiry (R-BUG-08).

### IDEA-11 Window receipts
- **Status / severity / effort / platform:** open; idea, rank 11; M; macOS and Linux; Linux-testable.
- **Sources:** TMP R-IDEA-11 (ideator: delight). Extends BACKLOG Product #2 (in-app history).
- **Problem and evidence:** A reset is when people think about how the week went, but the ring silently jumps back to 100%.
- **Proposal:**
  - Card line: when `observedReset` fires for a weekly or monthly window, LLimit closes a ledger row. For 24 h a muted line appears at the bottom of that account's card (`ProviderQuotaCard` footer). Examples: "Last week: used 88%, never hit the limit, closed at 12% left."; "Last week: hit the limit by Thu 14:10, 1d 19h before reset."; "Last month: used 31%; 69% went unused."
  - History popover: clicking the line shows the last 8 receipts for that metric as plain rows with a small bar, no chart.
  - Scope: no receipts for session and daily windows; one Settings > General toggle hides the line; receipts never send notifications.
  - Linux: `llimit receipts [--account <prefix>] [--json]` (a `receipts` verb in `CLI/main.swift`) and an additive per-metric `lastWindow: {usedPercent, closedAt, hitLimitBy?}` in the status JSON for 24 h after a close (`LD/StatusRenderer.swift:80-100`).
  - QuotaCore: the usage ledger with `UsageLedger.record(fresh:now:)`, a close on reset, and a receipt text builder, run from the enrichment stage in `AppModel.publishSnapshot` and `QuotaDaemon.refreshNow`. Both `purgeHistory` functions (`APP/AppModel.swift:1731`, `LD/QuotaDaemon.swift:540`) also purge the ledger.
  - Constraints: metric ids can swap windows (R-BUG-13), so key rows by (account id, metric id, kind) and drop a row on a kind mismatch. Sleep or a 180-minute interval make "hit the limit" times approximate: phrase them with "by" and mark receipts with too few samples. Venice estimates keep their "≈". The ledger holds no subtitles, names or failure messages.
- **Tests / acceptance:** a window closes on reset; sampling gaps produce "by" times and a low-confidence mark; a kind mismatch drops the row; account removal purges its rows; the 500-row cap.
- **Relations:** Needs the usage ledger and the observed reset. Replaces the rejected streaks idea (REF-24). #109 rekeys trend series away from positional ids (R-BUG-13); reuse its key if it fits. MAIN's in-app history/export proposal and MAIN-reported #88 `llimit export` are the history surfaces; MAIN's "Focus-session receipt" (explicit Start/Stop deltas) is a different feature.

### IDEA-12 Recent-bite marks on rings
- **Status / severity / effort / platform:** open; idea, rank 12; M; macOS (tiles and dropdown; menu bar in phase 2) and Linux (JSON, text); Linux-testable.
- **Sources:** TMP R-IDEA-12 (ideators: visual "Recent-bite arc"; the ghost segment from delight "Living menu-bar bars"; extends BACKLOG Product #3, burn rate); MAIN AM-PROD-16 ("Recovered-capacity marker").
- **Problem and evidence:** A ring says 46% left but not whether that is calm or a spike.
- **Proposal:**
  - Scope: weekly and monthly windows only.
  - Value: points used in the last 24 h, clipped at the last reset. QuotaCore `UsageLedger.consumed(last: 24h)` from the ledger's fresh samples, deduplicated by `fetchedAt` and segmented at resets with the trend chart's refill rule (`WX/LLimitQuotaWidget.swift:245-267`). The enrichment stage stamps it as an optional `UsageMetric.consumedLast24h`, so tiles never load raw history (a BACKLOG requirement; MAIN: "from compact published statistics").
  - Ring design, which the sources disagree on:
    - TMP: the remaining arc is unchanged; the bite is drawn from the end of the remaining arc onward, in the same identity hue at about 35% opacity with fine diagonal hatching, so it reads as texture rather than a new color. Under Reduce Transparency it becomes an outline-only segment. Must not ship as a plain tint, since a translucent same-hue segment sits close to the "color encodes one thing" rule.
    - MAIN: a neutral recent-minimum ring tick, which avoids touching the identity hue.
  - Files: `ProviderTileRing` (`WX/ProviderQuotaWidget.swift:750-790`), `GlossRing` (`APP/LLimitApp.swift:306-366`), `MetricQuotaRow` (`:1517`).
  - Row and VoiceOver: the row adds "20 used in 24 h" in secondary text; the accessibility summary says "20 points used in the last 24 hours".
  - Phase 2 (opt-in, after R-VIS-07's track): the menu-bar bar shows the same bite as an outlined segment above the bar top.
  - Linux: additive per-metric `consumed24h` (`LD/StatusRenderer.swift:80-100`); the human-readable line adds "(20 used in 24 h)".
  - Constraints: while the app or daemon was not running, the bite is unknown, not zero.
- **Tests / acceptance:** a steady burn; a reset inside the 24 h; sparse samples give nil, not 0; carried values do not count.
- **Relations:** Decide hatched segment versus neutral tick before building. Coordinate the ring drawing with the Reset Celebration branch (`4768e74`/#82), R-VIS-09 and #103's pace ticks on the tile ring. Phase 2 needs #96's track (R-VIS-07). The menu-bar ghost segment is what survives of the rejected "refresh shimmer" idea. Forecast engines (#87, #109) are separate from this observed measure.

### IDEA-13 Quota weather that admits fog
- **Status / severity / effort / platform:** partial: MAIN-reported #58 adds a calm/cloudy/stormy dashboard header from headroom, failures and estimates. Remaining: per-account outlook, Fog, Linux keys and a configurable policy. Idea, rank 13; M (after PRD-01 and PRD-02); macOS and Linux; Linux-testable.
- **Sources:** TMP R-IDEA-13 (ideator: delight; extends BACKLOG Delight "Quota weather" and Product #3); MAIN AM-PROD-22 ("Quota weather").
- **Problem and evidence:** #58's header (unverified report) summarizes the dashboard but does not forecast each window to its own reset, and nothing says "unknown" when the data cannot support a forecast. MAIN: stale or unknown must be explicit, and playful copy is not an untested forecast.
- **Proposal:**
  - Outlook per account, the worst of its bounded windows: Clear (projected to reach the reset with 15% or more to spare), Cloudy (projected within 15%), Storm (projected to run out before the reset, with an ETA), Fog (data older than 2 refresh intervals, fewer than 4 fresh samples in the window, an estimated percentage, or a failing account).
  - Policy is configurable. MAIN's earlier example used four states keyed on levels rather than forecasts: clear (all > 50%), cloudy (one < 30%), showers (several constrained), storm (verified exhaustion or rate limit). TMP's three forecast states plus Fog differ from that and from #58's calm/cloudy/stormy; pick one vocabulary.
  - Dropdown: a monochrome glyph (`sun.max`, `cloud`, `cloud.bolt`, `cloud.fog`) beside the card title in `ProviderQuotaCard` (`APP/LLimitApp.swift:1332`), with a sentence such as "Storm: at this pace Claude weekly runs out Thu 14:00, a day before reset." Numbers stay; weather never replaces them.
  - Linux: additive per-account `outlook` and a top-level `alt` (the worst outlook) for waybar's `format-icons` (`LD/StatusRenderer.swift:104-200`), plus a waybar example keyed by outlook.
  - QuotaCore: `Outlook.of(metric:forecast:samples:now:)` built on the forecast and `windowSeconds`, fed by the ledger's samples, stamped as an optional `ProviderUsage.outlook` with an explicit `decodeIfPresent`.
  - Constraints: forecasts are weak at 15 to 180 minute sampling, so tune toward Fog rather than a wrong Storm. The glyph is monochrome; only Storm text may use the reserved warning accent. Confirm that adding `alt` does not change `{icon}` selection for users whose `format-icons` is an array selected by percentage (unverified).
- **Tests / acceptance:** each outlook; Fog for each of its causes; thresholds at their boundaries; #58's header and the per-account outlook agree for the same snapshot.
- **Relations:** Needs PRD-01 (pace and `windowSeconds`, #103) and PRD-02 (forecast; #109's `QuotaForecast` vs MAIN-reported #87's `PaceEstimator`, which must be reconciled first). Extend or replace #58's header logic rather than adding a second classifier.

### IDEA-14 Quota guard for unattended agent runs
- **Status / severity / effort / platform:** open; idea, rank 14; M; Linux, macOS through IDEA-03; Linux-testable.
- **Sources:** TMP R-IDEA-14 (ideator: power). Extends BACKLOG Delight "Focus-session budget".
- **Problem and evidence:** An overnight agent cannot be limited to, say, 20% of this week's quota, or stopped before the account drops below a floor.
- **Proposal:**
  - Command: `llimit guard --account <prefix> [--max-use 20] [--floor 15] [--kind weekly] [--grace 60] [--warn-only] -- <cmd…>`.
  - Start: run the command in its own process group (`posix_spawn` with `POSIX_SPAWN_SETPGROUP`, behind `canImport(Glibc)`/`canImport(Musl)` guards) and record the baseline used percentage of the chosen windows.
  - Checks: re-check on every new snapshot by watching the file's mtime. Use is summed across resets: a reset starts a new segment and never subtracts.
  - On breach: SIGINT to the group, then SIGTERM after the grace period; exit 75 with, for example, "Stopped after using 20.6% of Claude weekly since 22:10 (limit 20%). Resets Thu 09:00." `--warn-only` sends a notification instead. Without a breach, exit with the child's status. Progress to stderr on each change ("guard: 7.2% of 20% used, data 6 min old").
  - Build: new `LD/QuotaGuard.swift` with a pure `GuardAccounting` (baseline, segments across resets, breach decision); the `guard` verb in `CLI/main.swift`.
  - Constraints: with 15 to 30 minute polls the guard can overshoot by up to one refresh interval of use; say so in `--help` and the stop message. Account-wide numbers include other sessions, so `--floor` is exact and `--max-use` approximate. Stopping mid-edit can leave a dirty tree: SIGINT first, never SIGKILL by default. Estimated percentages (Venice) are refused unless `--allow-estimated` is given.
- **Tests / acceptance:** accounting across a reset; `--floor` versus `--max-use`; a stale snapshot never triggers a stop; the signal sequence with an injected killer.
- **Relations:** The import guards follow R-BLD-02 (#92 fixes the unconditional `Glibc` import). Shares the snapshot-mtime watcher with IDEA-02's `wait`. MAIN's "Focus-session receipt" (explicit Start/Stop deltas) is the passive counterpart.

### IDEA-15 Provider pools
- **Status / severity / effort / platform:** open; idea, rank 15; M; macOS (dropdown; a widget later) and Linux (JSON); Linux-testable.
- **Sources:** TMP R-IDEA-15 (ideator: visual). New.
- **Problem and evidence:** Users with three Claude or two ChatGPT subscriptions care about the pool: how many accounts are still usable and how much is left across them. No surface shows that.
- **Proposal:**
  - Pools row: when two or more enabled accounts share a provider, the dropdown Overview (`OverviewCard`, `APP/LLimitApp.swift:1175`) gains one segmented ring per provider: N equal segments with small gaps in `stableAccountOrder` (reordering never moves them), each filled by that account's remaining percent in the provider's longest classified window, in the account's variant of that window's hue.
  - Center: "2 of 3 available" and the mean remaining, labeled "accounts weighted equally".
  - Segment marks: blocked segments use IDEA-01's outline; badges (IDEA-08) mark segments when set.
  - Linux: additive top-level `pools: [{provider, kind, accountIDs, availableCount, meanRemainingPercent}]` (`LD/StatusRenderer.swift:104-200`); the daemon stamps the order into the snapshot because the renderer cannot read settings.
  - QuotaCore: pure `ProviderPool.pools(snapshot:accounts:)` using `QuotaWindowKind.classify`, `stableAccountOrder` and `accountColorStep` (`QC/ProviderMetricSelection.swift:168-209`).
  - Later phase: a small widget kind, only if the dropdown row proves useful.
  - Constraints: plan sizes differ, so the equal-weight label must be explicit and no plan sizes are invented. With 4 or more accounts the variants wrap and pale falls below the chroma floor (R-UX-01, R-THM-03), so position, gaps and markers must carry identity too. Only classified kinds count; Antigravity's per-model `.other` metrics are not a pool.
- **Tests / acceptance:** grouping; the available count with blocked and failing accounts; order stability on reorder.
- **Relations:** Uses IDEA-01 and IDEA-08. MAIN-reported #59 also edits the overview (trophy recommendation). Order stamping shares the daemon enrichment with IDEA-08 and IDEA-17.

### IDEA-16 Scrubbable sparklines with audio graphs
- **Status / severity / effort / platform:** open; idea, rank 16; M; macOS (dropdown, floating dashboard); not Linux-testable.
- **Sources:** TMP R-IDEA-16 (ideator: visual). New; extends R-VIS-10.
- **Problem and evidence:** The dropdown draws a 24-hour sparkline per metric (`Sparkline` and `SparkSeriesBuilder`, `APP/LLimitApp.swift:412-510`), but VoiceOver cannot reach it (`accessibilityHidden(true)`) and nobody can inspect a point.
- **Proposal:**
  - Hover: a neutral hairline and a small label ("Tue 14:05 · 63% left") follow the pointer. While scrubbing, the card's ring (`GlossRing`, `:306-366`) shows that historical value with a dashed track and a "then" caption, and returns to the live value on exit, instantly under Reduce Motion. Reset points are small neutral ticks.
  - Keyboard: focus the sparkline, then Left and Right step through samples.
  - VoiceOver: replace `accessibilityHidden(true)` with `accessibilityChartDescriptor` (time on X, remaining percent on Y) for Audio Graphs, and add an adjustable action that reads one sample at a time.
  - Scrub state lives in `ProviderQuotaCard` (`:1332`) so hovering does not recompute other cards (R-PERF-06); hover redraws stay local to the row and card.
  - Data: only fresh observations, deduplicated by `fetchedAt`; exclude values carried for failing accounts, which would look like real data. Dropdown only, because widgets cannot scrub.
- **Tests / acceptance:** a `scripts/tests` unit for the nearest-sample lookup and the descriptor series; a manual VoiceOver check.
- **Relations:** Fix MAC-28 first (R-VIS-10: sparklines misalign, clip their end dot, and extend stale values to now). MAIN's history-dedup reports (#52, #75, #76) change which samples exist; publication-time folding and forward fill cannot create samples. MAIN's in-app history proposal asks for the same keyboard inspection.

### IDEA-17 Identity-colored Linux bar graph and tray gauge
- **Status / severity / effort / platform:** open; idea, rank 17; M; Linux (waybar, polybar, eww, tmux, tray); Linux-testable.
- **Sources:** TMP R-IDEA-17 (ideator: visual). Extends R-LNX-17 and R-LNX-16.
- **Problem and evidence:** The macOS menu bar shows one identity-colored bar per account. Linux bar examples color the whole module by the worst account, and the tray shows a fixed arc per class. The color math lives in `Shared/LimitKindColorScheme.swift`, which is SwiftUI-only today.
- **Proposal:**
  - Snapshot colors: at save time the daemon (`LD/QuotaDaemon.swift`, before the save) stamps per account the primary identity hex (kind hue, account variant, primary override) and per metric the `kind` and its hex, as optional fields on `ProviderUsage` and `UsageMetric`. Move the color math into QuotaCore (R-THM-02 proposes `LimitKindColors.steppedHex`).
  - JSON: StatusRenderer adds per-account `color` and per-metric `kind` and `color`; keys only added; `class` semantics unchanged.
  - Graph: `llimit status --graph [--markup pango|polybar|tmux]` emits one eighth-block glyph per account in Settings order, U+2581 to U+2588 with height equal to remaining, in the account's color; names only in the tooltip, escaped.
  - Examples: waybar with the Pango graph (`ok` renders in the bar's foreground; only `critical` and `error` add a red underline); eww with one `circular-progress` per account; polybar with `%{F#hex}`.
  - Tray: an SVG of the same graph (up to 8 accounts) rendered into `$XDG_RUNTIME_DIR/llimit/` with content-hashed names and a light-panel track.
  - Files: `LD/StatusRenderer.swift:80-200`, `TRAY/llimit_tray.py:254-301`, `Packages/LLimitd/examples/`.
  - Constraints: waybar parses `text` as Pango markup (R-LNX-07), so emit only fixed glyphs and validated colors and escape everything else. The hues were validated on dark graphite, so light bars need a track.
- **Tests / acceptance:** color resolution matches macOS fixtures; Pango output contains only fixed glyphs and validated `#RRGGBB` values; tray SVG naming.
- **Relations:** The tray gauge's light-panel track is LNX-09 (R-LNX-16, deferred by #105). #105 implements R-LNX-07's safe markup. MAIN-reported #53 adds selectable `LimitKindPalette`s, so the stamped colors must follow the chosen palette. Stamping shares the enrichment step with IDEA-08 and IDEA-15. StatusRenderer and `main.swift` edits overlap #95, #105 and #108.

### IDEA-18 Menu-bar display modes
- **Status / severity / effort / platform:** open; idea, rank 18; S for split bars, more for the full mode set; macOS; not Linux-testable except the pure column model.
- **Sources:** TMP R-IDEA-18 (ideator: visual; extends BACKLOG "Menu-bar icon and quick actions" display modes); MAIN AM-PROD-17 ("Calm/menu mode").
- **Problem and evidence:** Each status-item bar is as tall as the account's most constrained window but colored by its longest window (`APP/LLimitApp.swift:189-201`), so a short gold bar can mean "the 5-hour window is low". The icon width grows with accounts: MAIN computes `count * 3 + (count - 1) * 1.5`, about 52.5 points for twelve accounts (not a native measurement), and notes that non-template pale bars may wash out on light menu bars.
- **Proposal:**
  - Calm mode (MAIN): quieter texture and typography, collected notices, bounded menu width with a useful tooltip and accessibility label.
  - Menu bar style, a persisted enum in Settings > General: the current multi-bar (default); a single bar for the most constrained account; a fixed-width gauge or battery (18 pt candidate); a monochrome template or badge; and TMP's opt-in Split by window. Hidden percentages must keep their health semantics.
  - Split by window: each account draws two 2 pt columns, 0.5 pt apart, with 2.5 pt between accounts. Left is the tile's outer ring metric, right the inner ring metric (the tile's pair, from `defaultRingMetrics`, `QC/ProviderMetricSelection.swift:3-51`). Each column wears its window's identity hue in the account's variant (`LimitKindColorScheme.colors`); the primary override applies only to the primary slot; height is that window's remaining percent. Single-window and balance-only accounts keep one column. Above 6 accounts the icon falls back to Single to cap its width. Tooltip and accessibility label list both windows per account ("Claude: 5-hour 12%, weekly 64%").
  - Drawing: `MenuBarIcon.iconImage` (`APP/LLimitApp.swift:174-218`). Update AGENTS.md's menu-bar description.
  - Constraints: 2 pt columns are near the legibility floor on non-Retina displays, so Single stays the default. The non-template image needs R-VIS-07's track on light menu bars. Danger shows as a cap or outline per column, never by repainting a column.
- **Tests / acceptance:** a pure QuotaCore column-model function covering pairs, single-window accounts and the fallback; validation with the notch, in light and dark, and with Increase Contrast and Reduce Transparency (MAC-35).
- **Relations:** Builds on #96 (R-VIS-07 tracks, R-UX-05 failure caps), which edits the same drawing; #96 deferred R-UX-04 (dashboard order versus bars). IDEA-01's opt-in return time and IDEA-12 phase 2 draw in the same icon. MAIN's menu/tray sparkline (MAIN-reported #98) is a separate surface.

## Stale BACKLOG.md entries

These BACKLOG.md entries were already stale at baseline `2d6ac1e`. Each entry says what to delete or reword, and which cluster now owns any remaining work. Line numbers refer to BACKLOG.md at `2d6ac1e` (623 lines). TMP counts about fifteen stale entries. All edits are documentation-only and need no build. The code claims behind them can be checked on Linux by reading source. Merging the ledger PRs (#89 to #110) and MAIN's reported PRs will make more entries stale (BKL-01), so do the sweep after those merges, or re-check each line before deleting it.

### BKL-01 BACKLOG.md is historical input
- **Status / severity / effort / platform:** open / low / S (one docs PR plus a re-check after each feature merge) / docs only.
- **Sources:** MAIN AM-LESSON-1 (first "Retained review lessons" bullet). Related: MAIN "Build, release, and documentation" item 2 ("Retire resolved backlog entries without deleting remaining evidence"); MAIN lesson on timelines (second bullet); TMP summary item 15 (R-BKL-01 to R-BKL-10).
- **Problem and evidence:**
  - BACKLOG:3-5 calls itself "the maintained list of unresolved work only", reconciled against `main` at `bac7666` on 2026-07-17. That claim no longer holds at `2d6ac1e`.
  - MAIN lists five outdated task families. Do not resurrect them:
    - the CI outage (BACKLOG:16-17, :516-520; see BKL-02);
    - global Claude-token replacement (:147-163; BKL-03);
    - the automatic Settings scan (:330-339; BKL-04);
    - provider-unaware dashboard metric pairing (:483-484; BKL-08);
    - cloned dashboard timelines (:477-478). `QuotaTimelineProvider` already publishes one lightweight dashboard entry with `.after(nextRefreshDate)`. The remaining timeline work is tile and trend only: tiles generate up to 37 entries for static states, and trend entries carry the raw history (MAIN F07). TMP R-PERF-02 (WIDGET-11) partly argues against BACKLOG's `.after(nextRefreshDate)` guidance, because each widget's own reload fires just before the app's push.
  - Entries the open PRs will make stale once they merge (merge status unverified):
    - **Ledger PRs:** "Best model to burn" (:600) and "Quota roulette" (:606) via #108's `llimit pick` (R-NOV-03, Linux). "Pacing rings" (:602) is partly covered by #103's over/under-pace ticks (R-NOV-01); "until a chosen date" is not covered. Product #1 alerts (:581-583) are partly covered by #110 (Linux) and MAIN's #100 (macOS). The CI items are covered by #92 (BKL-02). The trend chart bullets (:495-505), including depletion warnings, are covered by #109 (R-BUG-12 and others).
    - **MAIN's reported PRs:** #59 (overview trophy) covers "Best model to burn" on macOS. #58 covers "Quota weather" (:601). #87 (dropdown burn rate and ETA) covers Product #3. #51 (`llimit resets`) covers Product #4. #88 (`compact`, `export`) covers Product #5 and #10. #97, #98 and #99 cover more of #10.
    - **Unverified:** "Reset celebration" (:603). Commit `4768e74` on `feat/reset-celebration` adds a ring glow, and MAIN reports #82 as a near-reset pulsing glow. TMP could not check that branch. MAIN notes that #82 shows anticipation of a reset, not an observed refill.
- **Proposal:** Treat BACKLOG.md as historical input, not a task source. Replace the header claim with a dated reconciliation note that points to ANALYSIS.md for open work. Apply BKL-02 to BKL-11 in one docs PR. After each ledger or MAIN feature PR merges, delete or narrow the matching lines. Keep the evidence that still applies; do not delete it.
- **Tests / acceptance:** No BACKLOG line describes behavior that the current main already ships, or a design that main has removed. Each remaining line maps to an ANALYSIS.md cluster. A grep for `bac7666`, "v2 provider widget picker", "failed before checkout" and "Add reorder" finds nothing.
- **Relations:** BKL-02 to BKL-11. The ledger section covers the PR overlaps: #108 vs #59 for the headroom ranking, #110 vs #100 for alerts, #103 vs #87 for pace.

### BKL-02 "Current validation state" and the build and CI items
- **Status / severity / effort / platform:** open / low (the replacement item BLD-01 is high and has a deadline) / XS / docs only.
- **Sources:** TMP R-BKL-01 (BUILD-14, PRODUCT-21, corrections from MENU-21 and MENU-22); TMP refuted MENU-21; MAIN "Evidence and validation limits"; MAIN build item 5.
- **Problem and evidence:**
  - BACKLOG:3 header: "main at bac7666 on 2026-07-17".
  - :13: "65 tests on Swift 6.0.3/Linux". Baseline has 416 QuotaCore test methods, and CI uses Swift 6.2.3. MAIN records 416 QuotaCore, 49 LLimitd and 23 tray tests at baseline. Pass D reports 426 and 52 on Swift 6.2.3. The combined six MAIN PR heads passed 496 QuotaCore and 57 LLimitd on Swift 6.3.3.
  - :14-15 cite Xcode 17F113 and the macOS 26.5 SDK for local widget testing.
  - :16-17 say macOS jobs "failed before checkout with no runner assigned". In fact, run 37509656521 on `2d6ac1e` ran the macOS Build & Test job, including the panel-geometry step, and passed. Run 37363625985 failed only because no hosted runner was acquired, for both the macOS and Ubuntu jobs.
  - :516-520 "Restore runnable CI" is obsolete.
  - Already done:
    - Ubuntu Swift CI (:536; `78fb526`).
    - The changelog (:572; `8c6b2bd`).
    - Dependabot (`1eced2a`), which covers the "automate controlled updates" half of :547 and "action-update configuration" in :572. MAIN agrees: "Changelog/dependency updates already exist."
  - :530-531 say repository guidance is Xcode 15+. README and AGENTS now say Xcode 16+, CI pins Xcode 16.2, and local validation uses 26.x.
- **Proposal:**
  - Refresh the header and validation numbers with a dated run: commit, run id, QuotaCore, LLimitd and tray counts, and the Swift version.
  - Replace "Restore runnable CI" with "Migrate off macos-14 before Nov 2, 2026" (BLD-01, implemented in open #92 along with the `ubuntu-24.04` pin). Delete the item once #92 merges. R-BLD-01's own fix list includes updating BACKLOG:16-17; the ledger does not say whether #92 did that, so check before editing.
  - Narrow :547 to SHA pinning.
  - Remove "Add Ubuntu Swift CI", and remove the changelog and action-update configuration from :572.
  - Reword :530-531 to "Xcode 16+ guidance, 16.2 in CI, 26.x locally".
  - Keep the CI items MAIN still lists as open (MAIN build item 3): duplicate Core test pass, toolchain selection before tests, XcodeGen drift, pinning, lifecycle and concurrency gates.
- **Tests / acceptance:** BACKLOG cites a real, dated run whose counts match. No line claims the macOS jobs cannot run. `bac7666`, "65 tests" and "Xcode 15+" are gone.
- **Relations:** BLD-01 / #92. #92 deferred running `scripts/test-panel-geometry.sh` in the Linux job, the toolchain checksum/PGP verification (rest of R-SEC-03) and CI toolchain caching. BKL-07 covers the "Restore macOS Actions" half of Recommended order #1.

### BKL-03 "Claude account provenance and recovery"
- **Status / severity / effort / platform:** open / low / XS (docs); the remaining work is S each, macOS-only (Keychain).
- **Sources:** TMP R-BKL-02 (AUTH-16); MAIN AM-LESSON-1 ("global Claude-token replacement"); related MAIN A06.
- **Problem and evidence:**
  - BACKLOG:147-163 (intro :149-151) describes things that no longer exist:
    - A workaround that applies one local Claude token to every enabled OAuth-like Claude account. No code does this now.
    - Provenance inferred from the `sk-ant-oat` prefix. That string appears only in test fixtures (`Packages/LLimitd/Tests/LLimitdCoreTests/QuotaDaemonTests.swift`).
  - Two more items are already done:
    - Background Keychain reads use `kSecUseAuthenticationUIFail` (`APP/Services/ClaudeProfileService.swift:119`), which satisfies "never trigger a surprise Keychain prompt during background refresh" (:163).
    - No Keychain export command remains, so the README/diagnostic-redirect bullet (:161-162) is done.
  - Still open:
    1. Choose the freshest of the file, OpenCode and Keychain tokens by expiry. `APP/AppModel.swift:505-507` consults the Keychain only when no file-based Anthropic credential was found.
    2. Record the source stable ID and source account identity on linked imports.
- **Proposal:**
  - Rewrite the section around the two open items and add R-UX-13 (PRV-07). R-UX-13: Claude Code creates the Keychain item without LLimit on its ACL. After a one-time "Allow" (instead of "Always Allow"), or after a cdhash change in an ad-hoc-signed build, background renewal fails, and recovery forces a new profile and a full sign-in.
  - Design constraints from AGENTS.md:
    - Never replace every Claude account with the global CLI token.
    - Imports without verified identity stay unchanged until explicit reimport.
    - Claude Code alone owns refresh-token rotation. This makes the "own Anthropic refresh grant" bullet (:159-160) a path the current architecture rules out. That point comes from AGENTS.md, not from the sources.
  - The sources do not assess :158 (re-read only the linked source and retry once on an Anthropic authentication failure). Decide it together with linked-source identity.
- **Tests / acceptance:** The section mentions neither global-token application nor prefix provenance, and lists only the freshest-token choice, linked-source identity and PRV-07.
- **Relations:**
  - MAIN A06: any OpenCode Anthropic candidate suppresses the Keychain read (`AppModel.swift:501-519`; `QC/CredentialDiscovery.swift:364-367`), which is the same freshest-token gap.
  - BKL-11 / PRV-16 (expiry).
  - #104 deferred storing the import source on Linux.
  - PRF-08 (interactive Keychain reads off the main actor) is a prerequisite for PRV-07's "Allow Keychain Access" action.

### BKL-04 "Async, explicit scanning" is mostly done
- **Status / severity / effort / platform:** open / low / XS (docs) / macOS-only for the remaining work.
- **Sources:** TMP R-BKL-03 (AUTH-17, SETTINGS-16, PRODUCT-21); MAIN AM-LESSON-1 ("automatic Settings scan").
- **Problem and evidence:**
  - BACKLOG:330-339 (intro :332-333) says opening Settings scans on the main actor and can prompt.
  - PR #45 (`8baedc5`) removed the `onAppear` scan. Scans now run only from the Scan button (`APP/Views/SettingsView.swift:274`) and from Auto-fill.
  - The Keychain query uses the exact "Claude Code-credentials" service with `kSecMatchLimitOne` (`APP/AppModel.swift:598-600`). With no broad enumeration left, "ask before enumerating broader services" has nothing to act on today.
  - Still open:
    - Discovery runs on the main actor with no progress indicator.
    - `claudeToken` accepts any spaceless string longer than 20 characters (`APP/AppModel.swift:623-626`).
- **Proposal:** Delete the done bullets and keep "run discovery off the main actor with progress" and "tighten raw-token validation". Add two items:
  - PRF-07 (R-PERF-03): every refresh runs a full multi-provider `CredentialDiscovery().discover()` just to sync OpenAI tokens, up to about 1 + 3N scans per cycle (`APP/AppModel.swift:640-693`, `:700-720`, `:730-757`; `QC/CredentialDiscovery.swift:71-91`; `LD/QuotaDaemon.swift:411`).
  - PRF-08 (R-PERF-04): interactive Keychain reads block the main actor (`APP/AppModel.swift:501-527`, `:592-611`, `:993-1005`; `APP/Services/ClaudeProfileService.swift:112-124`; `APP/Views/SettingsView.swift:273-277`).
- **Tests / acceptance:** The section no longer mentions an appearance scan or service enumeration. It lists the main-actor and progress gap, the token validation, PRF-07 and PRF-08.
- **Relations:** PRF-07, PRF-08, BKL-03 (PRV-07 depends on PRF-08).

### BKL-05 "Onboarding and account operations" still lists reorder
- **Status / severity / effort / platform:** open / low / XS / docs only.
- **Sources:** TMP R-BKL-04 (CORE-13).
- **Problem and evidence:**
  - BACKLOG:366 lists "reorder, search, groups, duplicate, snooze, and explicit widget-visibility controls".
  - Reorder already ships: `QC/AccountDisplayOrder.swift`, `APP/AppModel.swift:460-465` (`moveProviderAccounts`) and `APP/Views/SettingsView.swift:82` (`.onMove`).
  - Per-account trend visibility (Settings → Trend Widget) and tile pinning (Settings → Widgets, `providerTileSlots`) also exist.
- **Proposal:** Reword :366 to "Add search, groups, duplicate, snooze, per-metric trend selection, and per-account dashboard visibility." AGENTS.md constraint: reordering must not change `stableAccountOrder`, automatic tile assignments or color variants.
- **Tests / acceptance:** :366 no longer mentions reorder or per-account trend visibility.
- **Relations:** MAIN "Fast management" (search, filter and groups when needed; targeted refresh; snooze; reversible removal). The Trend chart bullet at :496-498 already mentions per-metric selection, so keep one copy.

### BKL-06 The menu-bar, Product and Delight sections overstate what remains
- **Status / severity / effort / platform:** open / low / XS / docs only.
- **Sources:** TMP R-BKL-05 (MENU-22, THEME-22, PRODUCT-20); related MAIN product proposals and reported PRs.
- **Problem and evidence:**
  - BACKLOG:370-371 says "fixed-width scrollable window". #48 (`2d6ac1e`) made the dropdown resizable.
  - "Menu sparkline" (:605) is already exceeded: every dropdown metric row has a 24 h sparkline (`APP/LLimitApp.swift:1536-1545`, 88×15 pt, "Last 24 hours").
  - "Honesty mode" (:608) is partly done:
    - "≈" on rings;
    - an ESTIMATED badge on tiles (MAIN reports AUTO/ESTIMATED badges at 8 pt and 0.85 opacity, with VoiceOver labels);
    - LAST KNOWN on dropdown cards;
    - `stale`/`estimated` in the Linux JSON.
  - Product #3 (:586-587) already has a widget-only forecast, the trend widget's depletion warnings (MAIN W06).
  - Product #10 (:596) is half built on Linux: `llimit status`, the `status --json` bar contract, and the waybar, polybar and eww examples.
- **Proposal:**
  - Reword :370-371 to: "The dropdown is now resizable and scrollable, but the status-item icon still grows with account count and has only a generic accessibility label."
  - Narrow the sparkline item to a sparkline in the status item or the Overview.
  - Narrow Product #2 (:584-585) to reset markers, account comparison and retention controls.
  - Narrow Honesty mode to labeling private endpoints and inferred classification, plus LAST KNOWN on tiles and the dashboard. PRD-09 owns this.
  - Annotate Product #3 and #10 with pointers to the existing code.
- **Tests / acceptance:** No line claims a fixed-width dropdown or an absent menu sparkline. Honesty mode and #2, #3 and #10 list only unbuilt parts.
- **Relations:**
  - PRD-09.
  - MAIN W06: correct the forecast before reusing it.
  - MAIN-reported #87 (Product #3), #88, #97, #99 and #83 (Product #10), and #98 (`llimit trend`, relevant to MAIN's "Menu/tray sparkline" proposal).
  - Ledger #103 (pace), #108 (status templates and `--watch`) and #109 (trend widget).
  - Ledger #96 changes the status-item graph (failures and stale data, track and floor), so re-check the :370-371 wording after it merges.

### BKL-07 "Validate the provider slot tiles" and the Recommended order
- **Status / severity / effort / platform:** open / low / XS (docs); the validation itself is macOS-only.
- **Sources:** TMP R-BKL-06 (THEME-22, BUILD-14, PRODUCT-21); related MAIN "Widget visual/runtime checks" and reported #53.
- **Problem and evidence:**
  - BACKLOG:456-458 lists "provider-themed diagonal stripes in one `Canvas`" as a reference-fidelity check. `ProviderTileBackground` (`WX/ProviderQuotaWidget.swift:802`) does not implement stripes.
  - The palette list (:459-461) matches the tile background gradients. Its wording can be misread as provider-colored rings, which the AGENTS.md color semantics forbid: rings wear `LimitKindColors` window colors with account variants.
  - Recommended order #1 (:612) still says "Restore macOS Actions and runtime-validate the v2 provider widget picker". CI runs (BKL-02), and static slot tiles (build 14+) replaced the picker.
- **Proposal:**
  - State that rings use `LimitKindColors` and that provider palettes apply to tile backgrounds only (MAC-11).
  - Drop the stripes item or re-scope it to an optional background treatment.
  - Change Recommended order #1 to "validate the static provider slot tiles". Replace its CI half with the macos-14 migration until #92 merges.
- **Tests / acceptance:** No BACKLOG line implies provider-colored rings or mentions the v2 picker. The stripes line is gone or explicitly optional.
- **Relations:**
  - MAC-11.
  - MAIN's slot-tile check list (auto-mapping, pinned assignments, `#N AUTO`, palettes, source-account identity, light/dark/tinted desktops, accessibility settings, maximum archives) is the re-scoped #1.
  - MAIN-reported #53 adds selectable `LimitKindPalette` ring palettes (Standard, Ocean, Sunset, Forest, Vivid). These are still window colors, not provider colors.
  - :477-478 (timeline cloning) is covered in BKL-01.

### BKL-08 Provider-aware dual-limit bars are done
- **Status / severity / effort / platform:** open / low / XS (docs) / docs only.
- **Sources:** TMP R-BKL-07 (WIDGET-18, PRODUCT-21); MAIN AM-LESSON-1 ("provider-unaware dashboard metric pairing").
- **Problem and evidence:** BACKLOG:483-484 asks to make the static dashboard's dual-limit bars provider-aware. That has been done since `add49bc`: `dashboardBarMetrics` (`WX/LLimitQuotaWidget.swift:658-661`) returns `defaultRingMetrics(for:)`. The accessibility path already speaks the labels. Only the visible dual text is still unlabeled.
- **Proposal:** Reword :483-484 to "Label or order the dual-limit text by window (short first, matching ring order)" (WID-12). Note the follow-on gap WID-01 (R-BUG-07): the fixed provider pair can hide the exhausted window. Examples: OpenCode Go rolling + monthly, Cline five_hour + weekly, Anthropic five_hour + seven_day (`QC/ProviderMetricSelection.swift:29-51`; `WX/ProviderQuotaWidget.swift:424-437`; `WX/LLimitQuotaWidget.swift:397-418`, `:495-528`, `:658-693`).
- **Tests / acceptance:** :483-484 no longer asks for provider-aware pairing, and points to WID-12 and WID-01.
- **Relations:** WID-12, WID-01. MAIN-reported #80 replaces the fixed systemSmall columns that collapsed dual-mode progress bars.

### BKL-09 Two Settings items are already fixed
- **Status / severity / effort / platform:** open / low / XS (docs); the leftovers are macOS-only.
- **Sources:** TMP R-BKL-08 (SETTINGS-17); MAIN lesson (`accountDataStatus`); MAIN "Native layout/lifecycle hypotheses".
- **Problem and evidence:**
  - BACKLOG:95 ("check current failure before reporting that carried usage is loaded") was done in `53166bd`. MAIN agrees: `SettingsView.accountDataStatus` already checks current failure before carried usage.
  - The deminiaturize part of :388-389 was done in `d08e460` (`APP/LLimitApp.swift:79-81`, `restoreOpenWindow`).
  - Still open, all verified at `2d6ac1e`:
    - `show()` calls `center()` right after `setFrameAutosaveName` (`APP/LLimitApp.swift:64-65`), so a restored position can be overridden.
    - The `WindowAccessor` comment (`APP/Views/SettingsView.swift:38-43`) still refers to the removed SwiftUI `Settings` scene, and its configure closure reruns on every `updateNSView` (`:1311-1331`).
    - The window title is "LLimit" (`APP/LLimitApp.swift:58`; `.navigationTitle("LLimit")` at `APP/Views/SettingsView.swift:44`), not "LLimit Settings" (:390).
  - The sources disagree on the centering. TMP lists it as open. MAIN lists "Settings autosaves then centers (`LLimitApp.swift:62-65`)" as an unreproduced hypothesis: verify restore, hide, minimize, reopen and display removal before changing the lifecycle.
- **Proposal:** Delete :95. Narrow :388-390 to the three leftovers, owned by MAC-34.
- **Tests / acceptance:** :95 is gone and :388-390 name only the centering, the stale `WindowAccessor` comment and loop, and the title.
- **Relations:** MAC-34. MAIN's lifecycle hypothesis list.

### BKL-10 "Return an unsaved result from RefreshService" is done
- **Status / severity / effort / platform:** open / low / XS (docs) / docs only.
- **Sources:** TMP R-BKL-09 (GAPA-6); related MAIN C04, TMP R-LNX-10.
- **Problem and evidence:**
  - BACKLOG:126 is done. `RefreshService.refresh` (`APP/Services/RefreshService.swift:8`) only fetches and merges. `AppModel` saves after `removingChangedVeniceResults` (`APP/AppModel.swift:211-212`, `:250`, helper at `:258`).
  - The revalidation bullet (:129, "Revalidate enabled account IDs immediately before every persistence boundary") overstates what exists. Only Venice key changes are revalidated today, so an in-flight cycle can still persist accounts of other providers that were disabled or removed meanwhile.
  - MAIN C04 gives the same evidence: `AppModel.swift:199-212`, `:248-271` validate Venice only, and `LD/QuotaDaemon.swift:271-285`, `:311-320` publish captured results without a final settings read.
- **Proposal:** Delete :126. Reword :129 to say that only Venice key changes are revalidated before persistence, and that disabled or removed accounts of other providers can still be persisted by an in-flight cycle. COR-01 owns this.
- **Tests / acceptance:** :126 is gone, and :129 states the Venice-only scope and points to COR-01.
- **Relations:**
  - COR-01, MAIN C04, MAIN C10 (cancellation).
  - Linux: R-LNX-10, deferred from #104 (an account removed or disabled during a daemon refresh is re-persisted into history; the ledger also notes an in-flight refresh can re-save an old Venice estimate).
  - Ledger #101 and MAIN #68 change the same Venice key path.

### BKL-11 "Preserve and validate Claude expiry metadata" is only partly open
- **Status / severity / effort / platform:** open / low / XS (docs); the remaining code is S and Linux-testable (OpenCode path), with the Keychain path macOS-only.
- **Sources:** TMP R-BKL-10 (GAPA-4); TMP R-BUG-38; related MAIN A06.
- **Problem and evidence:**
  - BACKLOG:326 asks to preserve and validate Claude expiry and to report "found but expired" separately.
  - The file-based `~/.claude` import already does this: it skips expired tokens with "Claude Code: token expired (path)" (`QC/CredentialDiscovery.swift:105-112`).
  - Still open:
    - The OpenCode branch (`QC/CredentialDiscovery.swift:364-368`) ignores `expires`.
    - The Keychain parse (`APP/AppModel.swift:615-630`) ignores `expiresAt`.
    - A stale OpenCode entry suppresses the Keychain read (`APP/AppModel.swift:505-507`).
    - No import stores `anthropic.expires_at` (`CredentialField.anthropicExpiresAt`, `QC/CredentialField.swift:7`), even though managed profiles already use it (`QC/ClaudeCodeProfile.swift:71`, `:145`, `:162`).
  - Impact: a one-click import can create an account that is already dead.
- **Proposal:** Narrow :326 to the OpenCode and Keychain paths and to storing `anthropic.expires_at` (PRV-16; Linux side LNX-02, where #104 deferred carrying the Claude `expiresAt`). The fix:
  - Parse both expiry fields with `parseDateValue`.
  - Skip expired tokens with a "token expired" diagnostic.
  - Store the expiry so the UI can warn before it passes.
- **Tests / acceptance:** :326 names only the OpenCode and Keychain paths and expiry storage. For PRV-16:
  - an expired OpenCode token is skipped;
  - a valid one carries its expiry;
  - a 0 or missing expiry is kept.
- **Relations:** PRV-16, LNX-02, BKL-03 (choosing the freshest token by expiry), MAIN A06.

## Retained lessons, refuted claims and rejected ideas

First, lessons that still apply (LES; status "open" means the lesson is still in
force). Each one constrains future work rather than describing a single fix. Then
refuted findings, rejected sub-claims and rejected ideas (REF). Do not re-propose a
REF item without new evidence. Locations refer to baseline 2d6ac1e.

MAIN also rejected these review suggestions on its own PRs. Keep them rejected:

- Accepting a terminally failed Muse stream as a fresh success. #69 requires a
  recognizable completion, and its terminal-error/last-good coverage keeps the last
  good snapshot instead.
- Treating present but malformed or null windows as absent. #69 makes a recognized
  Cline window with missing or null `percentUsed` fail decoding (explicit zero, bare
  objects and `data: null` stay valid), and Muse separates absent from malformed
  subscription windows.
- Exempting short configured secrets from redaction (#70's configured-secret
  redaction covers them).
- Inventing history endpoints observed "now". #75 records only source-fetch-time
  observations.
- Related: the synthetic-token "blockers" raised on those PRs were inert test
  fixtures, not secrets. Minor inherited copy, diagnostic and metadata suggestions
  were deferred, not rejected, and cancellation/publication remains MAIN C10.

### LES-01 A missing snapshot is not an empty schedule
- **Status / severity / effort / platform:** open (lesson in force) / n/a / none
  of its own / both platforms. The Linux renderer and tray parts are
  Linux-testable.
- **Sources:** MAIN retained lessons (AM-LESSON-4); context from MAIN L04, L12, the
  reset radar idea and MAIN-reported #50 and #51.
- **Problem and evidence:**
  - A reset view (radar, `llimit resets`, "Next resets") that finds no snapshot, or
    an unreadable one, must say so. It must not render an empty list that reads as
    "nothing resets soon". MAIN-reported #51 (`llimit resets [--json] [--days N]`,
    `QuotaSnapshot.upcomingResets(now:within:)`) separates missing data from an empty
    schedule, emits `snapshot`/`generatedAt` metadata and flags a stale schedule
    (reported policy: older than one day).
  - A radar built from an old snapshot is not a fresh all-clear. Passed reset dates
    stay "reset due" until replenishment is actually observed (MAIN reset radar
    idea).
  - Whitespace-only `resetIn`: `resetIn` is a string fixed at fetch time
    (`QC/Models.swift:268`), so legacy snapshots can carry blank values.
    `QC/Utilities.swift:39-41` (`resetCountdown(at:)`) trims and returns nil. The
    Linux paths read the raw string instead: human output at
    `LD/StatusRenderer.swift:38-39`, JSON at `:92-93`, and the tray at
    `TRAY/llimit_tray.py:86-88`, where Python treats a blank string as truthy and
    appends "resets in" to it. This was observed in source, not run.
- **Proposal:** treat "no snapshot", "unreadable snapshot", "stale snapshot" and
  "empty schedule" as distinct states in every reset view, and show the age of
  stale ones. Every reset text goes through one QuotaCore helper that drops blank
  strings, or is computed live from `resetAt` as #50 reports. Never pass the raw
  `resetIn` string through.
- **Tests / acceptance:** fixtures with a missing snapshot, an empty provider list,
  a stale snapshot with passed resets, and a whitespace-only `resetIn`. Human,
  `--json` and tray output each show a distinct message, a stale label, "reset due"
  for passed dates, and no "resets in" fragment for blank strings.
- **Relations:** applies to LED-33, PRD-07 and LNX-17. Live countdowns and
  `resetAt` come from #105 and MAIN-reported #50 (overlapping); the radar is
  MAIN-reported #51. REF-34 rejects a Reset Clock widget in favor of PRD-07.

### LES-02 History archive semantics
- **Status / severity / effort / platform:** open (lesson in force) / n/a / none
  of its own / both platforms; Linux-testable (`QuotaHistoryStore` is in
  QuotaCore).
- **Sources:** MAIN retained lessons (AM-LESSON-5); context from MAIN C02 (#75),
  F01 and MAIN-reported #52, #76 and #98.
- **Problem and evidence:**
  - `QC/QuotaHistoryStore.swift:55-74`: `append` loads the archive, appends, drops
    entries older than `keepDays` (45) measured from the new snapshot's
    `generatedAt`, sorts, and caps at `maxEntries` (3,000). Retention runs only
    inside `append`. A change that skips unchanged appends (MAIN-reported #52 skips
    repeated accounts and failures "while still advancing retention"; #76 skips
    content-equivalent points when the newest is fresh, under 1 h) must still prune.
    Otherwise expired entries stay in the archive indefinitely.
  - After #75, entries hold only accounts with a fresh source observation, stamped
    at source fetch time. Failed, carried and sibling observations are excluded. An
    entry is therefore a set of source observations, not the complete state at
    publication. A missing account in an entry does not mean it had no quota or was
    removed.
  - #76 reports folding a newer timestamp into stale points to keep flat stretches
    recent. MAIN warns that publication time must not become source observation
    time, and that genuinely fresh equal readings must not disappear. #98
    (`llimit trend`) forward-fills sparklines. That fill is decoration, not a new
    observed sample or forecast evidence, and cross-series normalization must not
    imply that capacities are comparable.
- **Proposal:** compare #52, #75 and #76 before changing the archive. Keep
  retention on no-op paths. Treat timestamp folding (#76) and forward fill (#98) as
  display-only: they never create samples.
- **Tests / acceptance:** a no-op append past the 45-day cutoff still drops old
  entries. Sparse-archive preservation tests (MAIN #76 note) pass. A fresh equal
  reading is retained. Forward-filled points never reach the archive or the
  forecast inputs.
- **Relations:** PRF-03 (the 3,000 cap; R-BUG-33 was deferred by #94 pending a
  retention decision); #94 (one decode and encode per publish; no-op
  `QuotaHistoryStore.remove`); MAIN F01 ("#52/#75/#76 semantics must survive" any
  storage redesign); forecast inputs for #109 `QuotaForecast` and MAIN-reported #87
  `PaceEstimator`; REF-13.

### LES-03 One enum owns state rendered by color and AX
- **Status / severity / effort / platform:** open (lesson in force) / n/a / none
  of its own / the surfaces are macOS-only, but the enum belongs in QuotaCore and is
  Linux-testable.
- **Sources:** MAIN retained lessons (AM-LESSON-6); context from MAIN #67
  (bottleneck caption) and M11.
- **Problem and evidence:**
  - Baseline passes a sentinel string between modules. `QC/Utilities.swift:44`
    returns the literal `"reset"` from `resetCountdown(at:)`.
    `APP/LLimitApp.swift:515` (`ResetChip.isDue`) compares `countdown == "reset"` to
    choose both the orange color and the "reset due" text.
    `WX/LLimitQuotaWidget.swift:1046` (`resetSummaries`) maps the same literal to
    "<1m". MAIN-reported #80 removes `resetSummaries` as dead code. Renaming or
    localizing the string silently breaks every consumer.
  - The tile's stale check compares the underlying time instead
    (`resetAt <= entry.date`, `WX/ProviderQuotaWidget.swift:610-617`). That is the
    pattern to follow.
  - When color and VoiceOver text come from separate conditions, they can disagree.
    For example, the color says "due" while the label still reads a countdown.
- **Proposal:** add one state enum (for example due, counting down, unknown),
  computed in QuotaCore from `resetAt` and `now`. Derive color, text and the
  accessibility label from that enum. Compare reset times, not strings. MAIN M11
  applies the same rule to status dots: extend #56's pattern with one state enum.
- **Tests / acceptance:** unit tests for the enum before, at and after `resetAt`;
  each view's color and AX label come from the same case.
- **Relations:** MAC-08, WID-04; MAIN #67 (gauge and caption identify the same
  limiting metric and reset); MAIN M11 and #56; LES-01 (blank `resetIn` strings).

### LES-04 Formatter synchronization and total ordering
- **Status / severity / effort / platform:** open (lesson in force) / n/a / none
  of its own / both platforms; Linux-testable (the formatter hazard is specific to
  swift-corelibs-foundation).
- **Sources:** MAIN retained lessons (AM-LESSON-7); context from MAIN F11.
- **Problem and evidence:**
  - On corelibs, a shared `ISO8601DateFormatter` needs synchronization, and
    `QuotaCoordinator` runs clients in parallel. Baseline is safe because
    `QC/Utilities.swift:153` and `:168` create formatters inside each
    `parseISO8601` call. That costs two allocations per parse (MAIN F11). A
    performance change that hoists them into a `static let` would introduce the
    race.
  - Ordering: `LD/StatusRenderer.swift:222-227` (`titleOrder`) sorts by provider
    rawValue and then title, so two same-provider accounts with the same title tie.
    `:55` sorts failures by account id only, and history append sorts by
    `generatedAt` only (`QC/QuotaHistoryStore.swift:66`). Swift's `sorted` does not
    guarantee stable ties, so tied items can change order between runs or
    toolchains.
- **Proposal:** use the value-type `ISO8601FormatStyle` or operation-local
  formatters, never an unsynchronized static formatter. Every user-visible sort ends
  with a unique tiebreaker such as the account id. MAIN F11 also asks to hoist the
  repeated all-account sort in `accountColorStep`. Reuse per-client decoders only
  with proven synchronization; otherwise keep codecs operation-local.
- **Tests / acceptance:** a Linux test that parses concurrently with parallel
  same-provider clients; equal-title accounts render in a fixed order; timestamp
  and number parsing produce the same results after the switch to `FormatStyle`;
  color identity is unchanged after reordering or disabling an account.
- **Relations:** PRF-12; LNX-01 (ordering); MAIN-reported #51 (total ordering of
  resets) and #64 (per-account ranking).

### LES-05 Constraints, and partial improvements are not proof
- **Status / severity / effort / platform:** open (lesson in force) / n/a / none
  of its own / both platforms.
- **Sources:** MAIN retained lessons (AM-LESSON-8); context from MAIN C10, W14 and
  follow-up order item 2; AGENTS.md (color semantics, widget registration,
  verification).
- **Problem and evidence:**
  - Several things are constraints, not opportunities for speculative redesign:
    - the validated `LimitKindColors` palette and the `steppedColor` deep-variant
      formula. Changing a hex value or the formula means rerunning the palette
      validator against graphite `#1D1F27` and widget blue `#5994F2`;
    - full-metric slot selection (`primaryLimitSlot` picks from the full metric
      list);
    - account provenance (managed-profile identity and import source);
    - frozen widget `kind` strings (changing one orphans placed tiles).
  - MAIN-reported #80 adds an aggregate header stale badge at 2x the refresh
    interval. It appears even with the clock setting off. It does not show
    per-account age: a fresh aggregate attempt can still carry an old
    `ProviderUsage.fetchedAt` (MAIN W14).
  - MAIN-reported #65 makes transport rethrow `CancellationError` and
    `URLError.cancelled`. Rethrowing does not prove that cancellation propagates
    through clients and the coordinator, or that it is checked before a snapshot or
    history commit (MAIN C10).
  - Unrelated green CI does not prove an invariant.
- **Proposal:** before claiming per-account freshness or cancellation safety, add
  the specific tests below. Change colors, slots, provenance rules or kinds only
  with new evidence and rerun the validators.
- **Tests / acceptance:**
  - C10: cancelling a suspended fetch writes no new snapshot or history. Linux
    shutdown signals do not replace good usage with shutdown-induced failures.
    Pending auth children and durable operation records keep their owner until the
    child's exit is confirmed.
  - W14 fixtures: mixed fresh and stale accounts, a targeted sibling refresh, a
    cached failure, and hidden clock or percentages. No aggregate timestamp may
    imply that every account succeeded.
- **Relations:** COR-08 and WID-05 (per-account age; see REF-06); WID-06 and
  MAC-25 (color identity; see REF-16); BND-07 (cost of a new widget kind).

### REF-01 Claims that account status and the dashboard timeline were wrong
- **Status / platform:** refuted / macOS-only.
- **Sources:** MAIN retained lessons (AM-LESSON-2); MAIN F07.
- **Claim:** Settings reports carried usage as healthy for a failing account, and
  the dashboard timeline publishes cloned entries.
- **Why rejected:** `APP/Views/SettingsView.swift:1198-1215`
  (`accountDataStatus`) checks the current failure (`:1207`) before carried usage
  (`:1212`) and adds "Showing cached data.". `WX/QuotaTimelineProvider.swift:42-53`
  publishes one lightweight entry with `.after(nextRefreshDate)` (`:52`).
- **What remains real:** the static tile entries (up to 37 per timeline,
  `WX/ProviderQuotaWidget.swift:183-209`) and the raw trend payload (PRF-06; MAIN
  F07).

### REF-02 A missing Antigravity remainingFraction is an omitted proto3 zero
- **Status / platform:** refuted / both (QuotaCore, Linux-testable).
- **Sources:** TMP refuted CLIENT-7.
- **Claim:** a missing `remainingFraction` is an omitted proto3 zero, so the backlog
  fix "missing means unknown" would hide exhausted models.
- **Why rejected:** the Antigravity IDE reads `remaining` as a oneof case. Oneof
  members have explicit presence, so a real 0 is serialized. CodexBar's docs mark
  such entries `usageKnown: false`. Baseline still maps a missing value to 0
  (`QC/Clients/GoogleAntigravityClient.swift:59`, `?? 0`). MAIN-reported #65 treats
  missing or unparseable as unknown, with nil `maxUsagePercent` when no bounded data
  exists. That is consistent with this verdict.
- **Revisit when:** a fixture from an exhausted model has been captured (PRV-10).

### REF-03 Claims about macOS CI evidence
- **Status / platform:** refuted / CI.
- **Sources:** TMP refuted MENU-21; TMP sub-claim BUILD-1; context from TMP
  R-BLD-01 and R-BKL-01.
- **Claim 1 (MENU-21):** panel-geometry checks never run because the macOS job
  fails before checkout. **Why rejected:** run 37509656521 on 2d6ac1e ran the macOS
  job and passed the geometry step. Three coverage gaps survived and were folded
  into R-BLD-01:
  1. the leading grip cannot widen at `visibleFrame.minX + screenMargin`;
  2. a frame 10 pt wider than the remembered size keeps that offset while
     shrinking;
  3. a 300x300 visible area returns the minimum size.

  R-BLD-01 also runs `scripts/test-panel-geometry.sh` in the Linux job, where it
  already passes 16 checks. #92 implements R-BLD-01 but deferred that Linux-job
  step.
- **Claim 2 (BUILD-1):** run 37363625985 is evidence of a brownout. **Why
  rejected:** it was a runner-acquisition failure that also hit the Ubuntu job. The
  retirement date alone justifies BLD-01: macOS 14 is unsupported from Nov 2, 2026
  (actions/runner-images#13518). BACKLOG's "macOS jobs failed before checkout" is
  outdated for the same reason (R-BKL-01).

### REF-04 The committed .claude/settings.json enables bypassPermissions
- **Status / platform:** refuted / repository tooling.
- **Sources:** TMP refuted BUILD-8.
- **Claim:** the committed file (`"defaultMode": "bypassPermissions"`, allow rule
  `mcp__claude-code-remote__*`) puts every contributor's Claude Code session in
  bypassPermissions mode.
- **Why rejected:** since Claude Code v2.1.257, `bypassPermissions` has no effect
  from project or local settings. Committed allow rules apply only after the user
  trusts the workspace. Moving the file to `settings.local.json` is optional
  cleanup.

### REF-05 A Spotlight widget is needed for the most constrained account
- **Status / platform:** refuted / macOS widgets.
- **Sources:** TMP refuted PRODUCT-15.
- **Why rejected:** the small dashboard already sorts lowest remaining first. Its
  "Accounts shown in small dashboard" limit (range 1 to 4,
  `APP/Views/SettingsView.swift:413-418`) can be set to 1, which shows exactly that
  account. A ring-style variant would be cosmetic and cost a new frozen widget
  kind.
- **What survives:** the shared ranking helper (R-NOV-03) in #108 (`llimit pick`,
  `HeadroomRanking`; PRD-06). MAIN-reported #59 (overview trophy for the highest
  bounded headroom) should use the same ranking.

### REF-06 Freshness display claims
- **Status / platform:** refuted / macOS widgets and Linux status.
- **Sources:** TMP refuted GAPB-7; TMP sub-claim CORE-1.
- **Claim 1 (GAPB-7):** the dashboard timestamp shows only the time, so a day-old
  snapshot looks current. **Why rejected:** it duplicates BACKLOG "Show stale age in
  ... static dashboard" and "show data age prominently". The only new detail is that
  `.time` drops the date (`WX/LLimitQuotaWidget.swift:351`, `:433`,
  `Text(snapshot.generatedAt, style: .time)`). The tile's stale threshold is
  max(1 h, 2x interval), with the interval clamped to 15 to 180 minutes
  (`WX/ProviderQuotaWidget.swift:619-621`).
- **Claim 2 (CORE-1):** the bar says "Updated just now" for hours. **Why
  rejected:** `relativeAge` (`LD/StatusRenderer.swift:206-220`) says "just now"
  only within 60 s. The real issue is that the header age comes from `generatedAt`,
  the time of the current cycle, which hides the age of carried data (COR-08,
  WID-05; TMP R-LNX-01 and R-BUG-08).

### REF-07 Ctrl-C at a secret prompt leaves echo off
- **Status / platform:** refuted / Linux.
- **Sources:** TMP refuted GAPB-10; context from TMP R-SEC-01.
- **Why rejected:** not reproduced in bash, which restores the tty after a
  signal-killed foreground job. zsh and fish echo input themselves. Only dash
  reproduces it, and EOF is already handled.
- **What was real:** the musl build never hid input. The guard
  `#if canImport(Glibc) || canImport(Darwin)` (`CLI/main.swift:380`) is false under
  the musl static SDK, and the static binary has no `tcgetattr`/`tcsetattr`
  symbols (SEC-07; fixed in #92). Restoring termios on SIGINT, SIGTERM and SIGHUP
  remains optional hardening that #92 deferred.

### REF-08 Z.ai sub-claims
- **Status / platform:** refuted / both (QuotaCore).
- **Sources:** TMP sub-claims SUB-CLIENT-1-a and SUB-CLIENT-1-b; context from TMP
  R-BUG-01.
- **Claim a:** Z.ai shows the weekly value as the session window. **Why rejected:**
  the 5-hour entry appears first, and the client keeps the first `TOKENS_LIMIT`
  (`QC/Clients/ZhipuQuotaClient.swift:65`). The real defect is that the weekly cap
  is dropped. A mislabel would need the server to reorder the array, and no source
  shows that (fixed in #90).
- **Claim b:** `TOKENS_LIMIT` unit 5 means months. **Why rejected:** no source
  supports it. The sourced units are 3 for the 5-hour window and 6 for the weekly
  window (steeman.be write-up, `netspeedy/zquota`). Unknown (unit, number) pairs
  get the neutral id `tokens-u<unit>-n<number>` and a neutral label (#90).

### REF-09 Anthropic sub-claims
- **Status / platform:** refuted / both.
- **Sources:** TMP sub-claims SUB-CLIENT-3 and SUB-CLIENT-4; context from TMP
  R-BUG-05 and R-BUG-06.
- **Claim a:** the extra-usage subtitle is wrong on every surface. **Why
  rejected:** only the dropdown card renders it (`APP/LLimitApp.swift:1446`), so
  the cents-as-dollars bug is display-only on one surface. Widgets and Linux did
  not render it at all (R-FEAT-01; #93 adds an amount-only `extra_usage` metric).
- **Claim b:** an exhausted `seven_day_sonnet` cap blocks the user entirely. **Why
  rejected:** it blocks only Sonnet work, which made the severity medium to
  medium-high (implemented in #93).

### REF-10 copilot_plan is optional
- **Status / platform:** refuted / both (QuotaCore).
- **Sources:** TMP sub-claim SUB-CLIENT-9; context from TMP R-BUG-19.
- **Why rejected:** GitHub's own types declare `copilot_plan` required, so keeping
  it required is defensible.
- **What remains real:** `quota_reset_date` and `quota_snapshots` are decoded as
  required (`QC/Clients/CopilotClient.swift:389-399`), although VS Code's
  `IEntitlementsData` types them as optional. Copilot Free uses
  `limited_user_quotas` instead, so its accounts never show usage (PRV-11).

### REF-11 LimitKindTests claims to list every emitted pair
- **Status / platform:** refuted / test code.
- **Sources:** TMP sub-claim SUB-CLIENT-14; context from TMP R-THM-06.
- **Why rejected:** `QCT/LimitKindTests.swift` contains no such comment. The parent
  finding stands: Copilot's "chat" and "completions" labels carry no cadence word,
  so they classify as `.other` (`QC/Clients/CopilotClient.swift:175-181`,
  `QC/Models.swift:807`).

### REF-12 LLimitd shares the sleep-paused timer
- **Status / platform:** refuted / Linux daemon.
- **Sources:** TMP sub-claim SUB-APPMODEL-1; context from TMP R-BUG-22.
- **Why rejected:** the shipped daemon is built with the Swift 6.2.3 static SDK,
  whose `Task.sleep` uses the continuous clock. On macOS, the pause applies only on
  the Swift 6.1-or-older runtime (macOS 14 and 15). On macOS 26 (Swift 6.2) the
  timer fires right on wake, possibly before the network is back. TMP marks the
  macOS pause itself unverified.
- **What remains real:** the other scheduling gaps in R-BUG-22 (bootstrap skip, no
  wake or network observers, no retry after a network failure). #102 deferred them.

### REF-13 24 extra appends truncate the 30-day chart
- **Status / platform:** refuted / both (QuotaCore).
- **Sources:** TMP sub-claim SUB-CORE-7; context from TMP R-BUG-33.
- **Why rejected:** only the minimum 15-minute interval is affected. A 30-day
  window needs 2,880 entries, which leaves about 120 extra appends (manual or
  post-login) before the 3,000 cap truncates the visible chart. The figure of 24
  only trims the one-day buffer. The default 30-minute interval uses about 1,490
  entries.
- **What remains real:** a low-severity truncation risk (PRF-03; #94 deferred it
  pending a retention decision).

### REF-14 chmod 444 on the snapshot reproduces the save failure
- **Status / platform:** refuted / macOS.
- **Sources:** TMP sub-claim SUB-APPMODEL-7; context from TMP R-BUG-28.
- **Why rejected:** the atomic rename still succeeds on a read-only file.
- **Correct reproduction:** a non-writable directory (`chmod 555` on the LLimit
  directory), a full disk, or `chflags uchg` (COR-09).

### REF-15 A pushed tag triggers a malicious release
- **Status / platform:** refuted / CI.
- **Sources:** TMP sub-claim SUB-BUILD-7; context from TMP R-SEC-02.
- **Why rejected:** events created with `GITHUB_TOKEN` do not trigger workflows,
  so a tag pushed with that token does not run release.yml.
- **What remains real:** ci.yml has no `permissions:` block (run 37509656521 shows
  write access to Actions, Contents, Issues, Deployments and PullRequests), and the
  token persists in `.git/config`. Compromised code could use the Releases API or
  push branches directly (BLD-03, SEC-04).

### REF-16 Overstated color-identity claims
- **Status / platform:** refuted / macOS (identity logic in QuotaCore).
- **Sources:** TMP sub-claims SUB-SETTINGS-3 and SUB-THEME-15; context from TMP
  R-UX-01 and R-UX-26.
- **Claim a (SETTINGS-3):** renaming an account breaks the AGENTS.md stability
  promise. **Why rejected:** AGENTS.md promises stability only under reorders and
  toggles. `stableAccountOrder` sorts by provider, name and id
  (`QC/ProviderMetricSelection.swift:168-209`), so recoloring on rename or add calls
  for a design improvement (WID-06), not a fix to a broken invariant. Caveat: the
  three-variant wrap does conflict with "two accounts must never share an exact
  color scheme" once four or more accounts share a window kind.
- **Claim b (THEME-15):** tiles are the only legend. **Why rejected:** dropdown rows
  and each account's Primary color picker also show identity colors (MAC-25). What
  remains: sidebar dots, slot pickers and trend toggles show status colors or
  nothing.

### REF-17 CodexRateLimitsTests:26 shows a slot switching windows
- **Status / platform:** refuted / test evidence.
- **Sources:** TMP sub-claim SUB-WIDGET-2; context from TMP R-BUG-13.
- **Why rejected:** `testMultiBucketResponseIsAuthoritativeAndStable`
  (`QCT/CodexRateLimitsTests.swift:25-30`) asserts ids from different buckets
  (`primary`, `bucket.daily.primary`, `bucket.spark.primary`,
  `bucket.spark.secondary`), not one slot changing windows.
- **Still unverified:** R-BUG-13's trigger, OpenAI moving a window between
  `primary` and `secondary`. The repo's `screenshot-widgets.png` matches the
  pattern. #109 guards against it anyway.

### REF-18 96 + 96 widget reloads per day
- **Status / platform:** refuted / macOS widgets.
- **Sources:** TMP sub-claim SUB-WIDGET-11; context from TMP R-PERF-02.
- **Why rejected:** at the default 30-minute interval it is about 48 app reloads
  plus 48 policy reloads per day. The tiles' 5-minute entries are timeline entries,
  not reloads.
- **What remains real:** credential-only saves reload all 14 widget kinds even
  though the payload is byte-identical (PRF-06). Whether this exhausts the macOS
  budget is unverified, because Apple's 40 to 70 per day figure is iOS guidance.

### REF-19 All tile previews are identical
- **Status / platform:** refuted / macOS widgets.
- **Sources:** TMP sub-claim SUB-WIDGET-14; context from TMP R-UX-11.
- **Why rejected:** `sampleEntry` cycles the color variants, so neighboring slots
  differ.
- **What remains real:** every preview shows the same Z.ai 82%/64% sample, and none
  shows the account its slot maps to (WID-17).

### REF-20 Claude npm installs fail with "env: node"
- **Status / platform:** refuted / macOS.
- **Sources:** TMP sub-claim SUB-AUTH-1; context from TMP R-BUG-03.
- **Why rejected:** current `@anthropic-ai/claude-code` ships a native binary. The
  `#!/usr/bin/env node` shim failure (exit 127, verified for Codex with `npm pack`
  of 0.160.1) does not apply to Claude. Severity is high for npm-installed Codex and
  medium for Claude.
- **What remains real for Claude:** missing candidate directories only. #107
  implements R-BUG-03 and also finds nvm, fnm and Volta installs; a CLI at another
  custom path still leads to `cliMissing` until PRV-05's Settings override lands.

### REF-21 Quitting during a Codex login strands the existing account
- **Status / platform:** refuted / macOS.
- **Sources:** TMP sub-claim SUB-AUTH-4; context from TMP R-BUG-14.
- **Why rejected:** quitting during a login strands only the fresh, unreferenced
  profile.
- **What remains real:** quitting or logging out during a managed fetch. The
  `Operations/<id>.pending` record (acquired at `QC/CodexAccountService.swift:128`,
  released at `:161`) is left behind, so every poll fails until the user reconnects
  (PRV-02).

### REF-22 Sub-claims about Linux status wiping the snapshot
- **Status / platform:** refuted / Linux.
- **Sources:** TMP sub-claims SUB-LINUX-1 and SUB-LINUX-14; context from TMP
  R-BUG-04 and R-LNX-08.
- **Claim a (LINUX-1):** every poll rewrites the snapshot. **Why rejected:** the
  first bar poll after the settings file breaks wipes it once. Later polls see the
  already-empty snapshot and do not write. This was reproduced with the built
  binary: `status --json` returned `class: empty`, and the snapshot held
  `providers: []`.
- **Claim b (LINUX-14):** with mismatched XDG paths, a `status` call from the
  user's shell wipes the snapshot. **Why rejected:** it is the reverse. The daemon
  reads the empty config at its own path and reconciles the shared snapshot against
  it every cycle (`LD/QuotaDaemon.swift:359-364`).
- **Relations:** LED-14, LNX-04. The guard is in #104 and MAIN #66;
  snapshot-only status is in #108 and MAIN #66.

### REF-23 The subtitle text column is 266 pt
- **Status / platform:** refuted / macOS.
- **Sources:** TMP sub-claim SUB-MENU-6; context from TMP R-UX-06.
- **Why rejected:** the verifier's arithmetic gives about 256 pt at a 420 pt width
  (196 pt at 360 pt). The finding itself stands. "GitHub Copilot · @octocat
  (individual_pro) · fetched 11 minutes ago" needs about 360 pt, so the "fetched"
  age is cut first (#95 implements R-UX-06).

### REF-24 Well-paced streaks
- **Status / platform:** rejected idea (delight) / both.
- **Sources:** TMP rejected ideas (RJ-IDEA-STREAKS).
- **Why rejected:** it gamifies spending quota.
- **Instead:** window receipts (IDEA-11) show the outcome without a score.

### REF-25 Weekday envelopes
- **Status / platform:** rejected idea (delight) / both.
- **Sources:** TMP rejected ideas (RJ-IDEA-ENVELOPES).
- **Why rejected:** the pace delta (PRD-02; R-NOV-01, #103) already answers "how
  much can I use today".
- **Instead:** if users ask for a workday calendar, add it to the pace model rather
  than building a second budget model.

### REF-26 Refresh shimmer and a live header needle
- **Status / platform:** rejected idea (delight, from "Living menu-bar bars") /
  macOS.
- **Sources:** TMP rejected ideas (RJ-IDEA-SHIMMER).
- **Why rejected:** decoration that costs status-item redraws and adds nothing the
  gauges lack.
- **What survives:** the ghost segment, as IDEA-12's opt-in phase 2 (the menu-bar
  bar shows the last-24-hour bite as an outlined segment above the bar top, after
  R-VIS-07's track).

### REF-27 Snap detents with haptics for the dropdown grips
- **Status / platform:** rejected idea (delight) / macOS.
- **Sources:** TMP rejected ideas (RJ-IDEA-DETENTS).
- **Why rejected:** polish only. Keyboard sizing and a size reset (MAC-30) matter
  more.

### REF-28 Friendly voice
- **Status / platform:** rejected idea (delight) / both.
- **Sources:** TMP rejected ideas (RJ-IDEA-VOICE).
- **Why rejected:** it doubles the strings to localize before a String Catalog
  exists (DEBT-03).
- **Instead:** fix the copy BACKLOG already flags.

### REF-29 llimit exec and "Open Terminal as..."
- **Status / platform:** rejected idea (power) / both.
- **Sources:** TMP rejected ideas (RJ-IDEA-EXEC).
- **Why rejected:** three blockers, and all three must be solved before revisiting:
  1. a user session inside a managed profile races LLimit's renewal markers and
     lock handling (PRV-04, PRV-09; TMP R-BUG-16, R-BUG-43);
  2. it conflicts with Codex's exclusive operation records;
  3. it leaves user transcripts in directories that account removal deletes
     (BND-04).

### REF-30 Prometheus/OpenMetrics exporter
- **Status / platform:** rejected idea (power) / Linux.
- **Sources:** TMP rejected ideas (RJ-IDEA-PROMETHEUS).
- **Why rejected:** niche. A jq script over `status --json` covers it once
  `resetAt` is emitted (LED-15; #105 and MAIN-reported #50). Positional metric ids
  (TMP R-BUG-13) would make the series unstable.

### REF-31 Remote read-only sources over SSH
- **Status / platform:** rejected idea (power) / both.
- **Sources:** TMP rejected ideas (RJ-IDEA-SSH).
- **Why rejected:** too costly and risky for a niche case: L effort, SSH from a GUI
  app, untrusted remote JSON, and side effects on account color order.

### REF-32 Shortcuts entities, Best Account and Focus filters
- **Status / platform:** rejected for now (power) / macOS.
- **Sources:** TMP rejected ideas (RJ-IDEA-SHORTCUTS).
- **Why rejected:** the host app has no AppIntents yet.
- **Instead:** Product backlog #6's basic read and refresh intents come first
  (PRD-10).

### REF-33 Per-project quota ledger from status-line telemetry
- **Status / platform:** rejected idea (power) / both.
- **Sources:** TMP rejected ideas (RJ-IDEA-PROJECT-LEDGER).
- **Why rejected:** it waits on IDEA-04's sensor (the opt-in phase 2 `--observe`).
  It splits account-wide percentages by a cost proxy, and it stores sensitive
  repository paths.

### REF-34 Reset Clock widget
- **Status / platform:** rejected idea (visual) / macOS widgets.
- **Sources:** TMP rejected ideas (RJ-IDEA-RESET-CLOCK).
- **Why rejected:** it overlaps Product backlog #4 and the reset-radar work
  (`feat/reset-radar`; MAIN-reported #51 and #82). A new widget kind also costs a
  version bump and install-gate updates (BND-07).
- **Instead:** PRD-07.

### REF-35 Window burn-down widget
- **Status / platform:** rejected idea (visual) / macOS widgets.
- **Sources:** TMP rejected ideas (RJ-IDEA-BURNDOWN).
- **Why rejected:** it needs PRD-01 (depletion forecast, TMP R-FEAT-02) and PRD-02
  (pace, TMP R-NOV-01) first.
- **Instead:** build it as a view in the in-app history (Product backlog #2,
  PRD-08), not as a new widget kind.

### REF-36 Usage calendar dot strip
- **Status / platform:** rejected idea (visual) / macOS widgets.
- **Sources:** TMP rejected ideas (RJ-IDEA-CALENDAR).
- **Why rejected:** a 14-day rhythm view does not justify a new widget kind and
  another aggregate file.
- **Instead:** fold it into the in-app history later (PRD-08).

### REF-37 llimit top terminal dashboard
- **Status / platform:** rejected idea (visual) / Linux.
- **Sources:** TMP rejected ideas (RJ-IDEA-TOP).
- **Why rejected:** L effort for what `--watch` and trend sparklines mostly cover.
  `--watch` is LNX-10 (TMP R-LNX-20), offered by both #108 and MAIN-reported #99.
  Sparklines are TMP R-LNX-22, offered by MAIN-reported #98.

Also rejected in TMP, with no cluster id in this merge:
**validated limit-color packs** (visual). No pack can pass validation until the
pale variant is fixed (TMP R-THM-03). Port the palette validator to a
Linux-runnable test as part of R-THM-03 instead. Conflict: MAIN-reported #53
(`limit-color-palettes`) already ships Standard, Ocean, Sunset, Forest and Vivid
palettes. MAIN asks for contrast and CVD validation when extending it.

## Suggested follow-up order

A suggested sequence that combines MAIN's handoff order (AM-ORDER-1 to AM-ORDER-5) with TMP's implementation shortlist and next tier. TMP ranked its shortlist by user-visible value per unit of risk. MAIN orders by invariant risk: reconcile overlapping implementations, then auth, publication and durability boundaries, then measured performance, then focused fixes, then features. Each step below references the topical clusters that hold the evidence; this section adds the sequencing, the gates between steps and the conflicts.

The shortlist's sixteen items are now this pass's PRs #89-#110: 1 #92; 2 #104 (guard, R-LNX-05, R-LNX-06) and #108 (snapshot-only status); 3 #105; 4 #93; 5 #89; 6 #104; 7 #101; 8 #107; 9 #102; 10 #90; 11 #95; 12 #109; 13 #94; 14 #103; 15 #110; 16 #108. Three next-tier items are also done: R-BUG-08 (#105), R-UX-05 with R-VIS-07 (#96) and R-NOV-04 (#106). The rest of the next tier is placed below: R-BUG-10, R-BUG-14 and R-BUG-15 (PRV-01 to PRV-03) in ORD-03; R-BUG-07, R-BUG-17, R-UX-01, R-A11Y-01 and R-SEC-05 in ORD-04; R-BLD-04 (BLD-03) in ORD-02.

Every PR in both sets is open and unmerged. MAIN reached its requested review stop for its six slices (#66, #67, #69, #70, #72, #75); this pass's 17 PRs reached the review stopping rule with CI green on their final heads (ledger table 1); MAIN-reported PRs (#50-#100) were not checked by either document. Progress reported on a PR (green CI, completed review rounds, or "fixed", "landed" or "merged" in a source document) is not a merge instruction; the user decides merges. Native rendering, Instruments, VoiceOver, live authentication, installed widgets, systemd upgrades and packaged TLS were not exercised by either source, so every step that touches them keeps a manual verification item.

Order at a glance:

1. ORD-01: decide every overlapping implementation before writing new code in that area.
2. ORD-02: merge #92 before the macos-14 retirement on Nov 2 (in parallel with ORD-01; #92 is in no overlap pair), then close the remaining release blockers.
3. ORD-03: data-loss, credential and auth boundaries (COR-01 to COR-07, SEC-01, SEC-02, PRV-01 to PRV-04, PRV-09).
4. ORD-04: truthful display, TMP's next tier (WID-01, WID-02, LNX-01, WID-06, WID-07, SEC-03, PRV-08, PRF-01).
5. ORD-05: profile, then bound performance (PRF-02 to PRF-06, PRF-09 to PRF-12).
6. ORD-06: freshness, notices, accessibility and Linux operations.
7. ORD-07: visual modes, theming, product and ideas, gated on signing and provider captures.
8. ORD-08: documentation hygiene after the merges.

### ORD-01 Decide the overlapping implementations first
- **Status / severity / effort / platform:** open. Priority: first (MAIN step 1). Effort: S per decision (compare and choose), M to rebase the survivors. Platform: both. The CLI, status and QuotaCore pairs are Linux-testable; #101/#68, #101/#85, #94/#78 and #54/#80/#72 are macOS app or widget paths.
- **Sources:** MAIN AM-ORDER-1 and its ledger notes (#70 before #69; the overlap remarks under #50-#100); LEDGER final update (measured conflicts, integration check, landing order); TMP shortlist "Conflicts" bullets.
- **Problem and evidence:**
  - Cross-set pairs (detail in the ledger's overlap list):
    - #108 vs #66: snapshot-only `llimit status`. #104 vs #66: the Linux unreadable-settings guard. #104 also adds MAIN's open macOS C03 guard, which no MAIN PR covers.
    - #105 vs #50: live countdowns and `resetAt` (#105 adds `fetchedAt`/`ageSeconds` and "reset due"; #50 adds recomputed `resetSeconds`, ticking tray countdowns and the interval-aware stale threshold that #105 deferred). #105 vs #64: failure keys (#105 `failed`, `errorKind`, `error`, `fetchedAt`, `lastKnown`, a `failures` summary, failure-only accounts, class elevation, tray error rows; #64 `failing`, `error`, `errorKind`, a title fallback, green-to-warning escalation, tray error tooltips). The bar contract allows adding keys, never renaming them.
    - #108 vs #97: `llimit check` contracts are incompatible (#108 `--min`/`--max-age`, exit 0 ok, 1 below minimum, 2 stale or failing, 3 no data; #97 `--below`/`--stale-hours`, exit 1 with reasons). Scripts will depend on whichever ships. #108 vs #99 (`status --watch`); #108 vs #88 (`status --format` templates vs `llimit compact`, partial); #108 vs #59 (`HeadroomRanking` for `llimit pick` vs the overview trophy; different surfaces, one ranking).
    - #101 vs #68 (draft commits vs debounced invalidation with a termination flush and an estimate key fingerprint) and #101 vs #85 (`PendingEdits` vs a 400 ms save debounce with `willTerminate` and resign-active flushes). Same AppModel edit path.
    - #109 and #103 vs #87: three estimators in QuotaCore (`QuotaForecast`; `windowSeconds`/`QuotaPace`; `PaceEstimator`/`UsageMetric.paceEstimate`).
    - #110 vs #100: two alert engines with two threshold sets (#110 20%/5%; #100 configurable warning/critical bands; MAIN's earlier proposal 30%/15%).
    - #94 vs #78: #78's `.corrupt` quarantine likely covers #94's deferred corrupt-local-archive case.
    - #93 vs #84: same Anthropic parser; #84's all-unreadable `.decoding` failure covers #93's deferred nil `maxUsagePercent`.
    - #109 vs #54 and #80: trend empty-state reasons vs dashboard states; check whether #54 or #80 also change the trend widget.
  - MAIN's internal sets:
    - #63/#65/#70 failure text: #63 scrubs bounded excerpts (about 200 characters; Bearer, JWT and API-key shapes); #65's `.api` errors reportedly include response bodies; #70 allows only safe public messages. Excerpt scrubbing alone does not make unknown reflected secrets or old persisted errors safe.
    - #52/#76/#75 history: #52 skips repeats while advancing retention; #76 skips content-equivalent points when the newest is under 1 h old and folds a newer timestamp into stale points; #75 stores source fetch time. Publication time cannot become observation time, and genuinely fresh equal readings must not disappear.
    - #54/#80/#72 dashboard widget states: #72 owns attributable values and truthful dashboard states; #54 adds cause-specific failures and `+N more`; #80 adds all-failed/no-data/no-accounts states and an aggregate stale badge at 2x the interval.
    - #71/#74 with SEC-02 (MAIN C09): reuse their owner-only atomic writes; directory, owner, symlink and App Group mode checks remain.
    - #77 with COR-06 and PRF-05 (MAIN C01, F05): reuse `ProviderFailure.retryAt`; do not add a second retry field.
    - #87 with LED-22 (MAIN W06): correct the reset-segment semantics before converging estimators.
  - Integration order inside MAIN's set: #70 before #69 (Muse guard and parser overlap; #69 is stacked on #70).
  - Measured textual conflicts within this pass (pairwise `git merge-tree` of the 17 heads; replaces the expected list): only 8 pairs conflict. Code: `LD/StatusRenderer.swift` (#95 x #105) and `APP/LLimitApp.swift` (#95 x #102). Docs: `AGENTS.md` in all six pairs among #104, #105, #108 and #110, plus `Packages/LLimitd/README.md` (#108 x #110). `CLI/main.swift`, `APP/AppModel.swift` and TMP's expected `QC/CodexCLIProbe.swift` import lines (#92, #107) merge cleanly. MAIN's #67 against `APP/LLimitApp.swift` was not measured. TMP also asks to check any in-flight branch touching StatusRenderer (for example `feat/reset-radar`).
  - Integration check: `opus/integration-check` (head `7ed4c7b`) merges all 17 heads onto origin/main with every conflict resolved keeping both sides; CI green (macOS Build & Test, Linux SwiftPM, Linux static .deb, Linux tray); locally 665 QuotaCore, 134 LLimitd and 46 tray tests pass. The resolutions (combined `AGENTS.md` and `Packages/LLimitd/README.md` layout entries, #105's StatusRenderer rewrite with #95's `relativeAge` move, and the dropdown header subtitle combining #102's reason and age cases with #95's wording and formatter) are on that branch.
  - Integration-only fixes the second PR of each pair must carry: #95 + #108 (point #108's `StatusTemplate.swift` and `ScriptCommands.swift` from `StatusRenderer.relativeAge`, which #95 removes, to `QuotaDisplayText.relativeAge`; build break otherwise); #104 + #110 (add `try` to two `QuotaAlertsTests` calls to `QuotaDaemon.addAccount` once #104 makes it throw; test build break otherwise); #104 + #108 (drop #104's dead `makeDaemon` status warning and the README sentence about it).
  - Further contacts from the ledger: #105 and #77 both edit `mergingStaleUsage`; #94 and #52/#76 edit `QuotaHistoryStore`; #96/#109 and #53 share limit-color drawing; #91's version detection depends on #107's CLI discovery; #86's `env:` references must survive #104's in-place updates.
- **Proposal:**
  1. For each pair, choose one implementation, or one base plus the other's distinct parts, before writing new code in that area. Record the choice and the declined PR's reasons.
  2. Settle the external contracts first, because scripts and bars depend on them: `llimit check` flags and exit codes, the status JSON key names, and one alert threshold set.
  3. Landing order for this pass's PRs (LEDGER final update, from the measured conflicts): #92 first (ORD-02); then #104, #108, #105, #110 (#104 leads because its guard is the data-loss fix); #95 after #105 and #108; #95 and #102 in either order; the other ten (#93, #89, #90, #94, #101, #96, #103, #109, #107, #106) any time. The second PR of each pair carries the integration-only fixes above. TMP's constraint that #103 land after #105, #93 and #95 no longer applies: #103 merges cleanly with every other head.
  4. Keep both sources' invariants when merging a pair: snapshot-only status with clean JSON stdout, additive keys only, no publication-time samples, safe failure text at every display boundary.
- **Tests / acceptance:** every pair has one recorded decision. Before the first merge, a temporary integration branch of all chosen PRs passes QuotaCore and LLimitd `swift test`, the tray unit tests and the macOS build, as MAIN's coordinator did for its six heads (496 QuotaCore and 57 LLimitd tests on Linux Swift 6.3.3; that integration merge was not published). This pass's 17 heads already pass together (`opus/integration-check`, head `7ed4c7b`); repeat the check once the cross-set choices are made.
- **Relations:** LED-12, LED-14, LED-15, LED-21, LED-22, LED-27, LED-34, LED-36, LED-43, LED-48, LED-50, LED-54, LED-55, LED-57, LED-58, LED-60, LED-61. Downstream owners: LNX-01, LNX-03, LNX-10, PRD-01, PRD-02, PRD-04, PRD-06, COR-06, SEC-02, PRF-02, PRF-04, PRF-05, WID-03, WID-04.

### ORD-02 Release blockers before Nov 2
- **Status / severity / effort / platform:** open. Severity: high (TMP rates R-BLD-01 and R-BLD-02 high; R-SEC-01 medium after verifier correction). Deadline: macOS 14 runners are unsupported from Nov 2, 2026; scheduled brownouts fail jobs on Oct 12, 16, 19, 23, 26, 29 and 30, 14:00 to 24:00 UTC (Oct 5 has passed). Effort: XS to merge #92; S each for the BLD-01 remainder and BLD-04; M for BLD-03. Platform: CI and Linux packaging; the PTY test is Linux-testable; BLD-04 is macOS-only.
- **Sources:** TMP executive summary item 1, shortlist 1 and next tier (R-BLD-04); TMP R-BLD-01, R-BLD-02, R-BLD-03, R-BLD-04, R-SEC-01; LEDGER #92.
- **Problem and evidence:**
  - At baseline the next tag breaks: `QC/CodexCLIProbe.swift:2-6`, `QC/CodexProfileStore.swift:2-6` and `QC/CodexRPCSession.swift:2-6` import `Glibc` unconditionally, and the release builds the `.deb` with `--swift-sdk x86_64-swift-linux-musl` (`.github/workflows/release.yml:124`), which has no Glibc module (`CodexCLIProbe.swift:5:8: error: no such module 'Glibc'`). The files arrived in b47497b (Sep 27), after v1.0.1 (Aug 21). The macOS job publishes first, so the tag would produce a Release without the `.deb` the README promises.
  - The shipped `.deb` echoes secrets at the `llimit accounts add` prompt (`CLI/main.swift:373-394`, guard at `:380`), and `ci.yml:20` and `release.yml:22` run on `macos-14`.
  - #92 fixes all three: musl-safe imports, the Musl echo-off branch with a PTY secret-input test, a new "Linux (static .deb)" CI job, `macos-15` in both workflows and `ubuntu-24.04` pins. #92 is in no overlap pair and, measured, conflicts with no other PR of this pass (ledger table 1).
  - Remaining before the next release:
    - BLD-01: `scripts/test-panel-geometry.sh` runs only in the macOS job (`ci.yml:50-51`) although it passes on Linux (16 checks). TMP also asked for three geometry tests (the leading grip cannot widen at `visibleFrame.minX + screenMargin`; a frame 10 pt wider than the remembered size keeps that offset while shrinking; a 300x300 visible area returns the minimum size), an optional Xcode 16.2 and 26.x matrix, and an update to `BACKLOG.md:16-17`. #92 does not add the tests: LEDGER does not list them, and #92's final head is 53350b7, the `opus/release-unblock` head whose worktree check found `scripts/tests/MenuBarPanelGeometryTests.swift` and `BACKLOG.md` identical to baseline.
    - SEC-07: v1.0.1 has the same echo guard and the README quickstart prompts for the token, so typed secrets may sit in scrollback, tmux logs or screen shares. The first release that ships #92 needs a note telling v1.0.1 users to clear their scrollback. Restoring termios on SIGINT, SIGTERM and SIGHUP is hardening, not a blocker (only dash reproduced stuck echo).
    - BLD-04: `release.yml:44` stamps `CURRENT_PROJECT_VERSION` from `github.run_number`. LLimit-1.0.1.zip has CFBundleVersion 2 in the app and the extension while `project.yml` was at 20 at that tag (37 now). Installing a release over a dev build lowers the version that AGENTS.md requires to rise monotonically. The verifier notes limited practical impact while releases are ad-hoc signed without an App Group.
    - BLD-03: the macOS job creates a non-draft Latest release (`release.yml:74-89`) before `release-linux` (`:91`, `needs: release` at `:94`) builds the `.deb`. A macOS failure blocks the `.deb`; a Linux failure leaves a Latest release without it. No tests run before publishing, and `:11-12` grants `contents: write` to every job.
- **Proposal:**
  1. Merge #92 before Nov 2, preferably before the Oct 12 brownout, without waiting for ORD-01.
  2. A follow-up PR for the BLD-01 remainder: add the geometry script to the `linux-test` job (which already installs Swift) and keep it in the macOS job; add the three tests; reword `BACKLOG.md:16-17` from "Restore runnable CI" to "Migrate off macos-14 before Nov 2, 2026" (tracked with BKL-02).
  3. Put the SEC-07 scrollback note in the release notes of the first release containing #92.
  4. BLD-04: drop the override; add a release gate that fails when the tag differs from `MARKETING_VERSION` or when the app and appex CFBundleVersion differ (copy `scripts/build.sh:98-103`); set `RELEASE_POST_BUMP` in `scripts/release.sh` to bump `CURRENT_PROJECT_VERSION`.
  5. BLD-03: split into `build-macos` and `build-linux` jobs that only upload artifacts with `contents: read`, plus a `publish` job (`needs` both, `contents: write`) that creates the release, optionally as a draft published after every asset attaches. Run `swift test` and the harnesses before uploading.
- **Tests / acceptance:** a PR run on `macos-15` where all three harness steps pass; a Linux job log showing the geometry checks; the musl build and `build-deb.sh 0.0.0~ci` run in CI; the openpty test asserts ECHO cleared during the read and restored after. A tagged build's app and appex both carry `project.yml`'s `CURRENT_PROJECT_VERSION`, and a mismatched tag fails before anything is published. In a fork test-tag run, a forced failure in either build job leaves no public release; a successful run publishes the `.dmg`, `.zip` and `.deb` at once.
- **Relations:** LED-03; BLD-01, BLD-03, BLD-04, SEC-07. SEC-05 (#92's deferred checksum or PGP verification of the toolchain through a shared setup-swift composite action, plus CI caching, both declined in #92's review) edits the same workflows, but neither source ranks it as a blocker. BLD-07 documents the new release layout after BLD-03 and BLD-04. BLD-08 (LLimitd never builds on macOS CI). In the local #92 head, which is its final head `53350b7`, `zai-code-review.yml:26` still uses `ubuntu-latest`.

### ORD-03 Data-loss, credential and auth boundaries
- **Status / severity / effort / platform:** open. Severity: high (MAIN rates C04 to C10 high and C11 medium; TMP rates PRV-01 to PRV-04 medium and PRV-09 low). Effort: L overall, S to M per cluster. Platform: both; QuotaCore and daemon slices are Linux-testable, AppModel wiring is macOS-only.
- **Sources:** MAIN AM-ORDER-2; TMP next tier (R-BUG-10, R-BUG-14, R-BUG-15), TMP R-BUG-16, R-BUG-43, R-SEC-06, R-SEC-07, R-DEBT-03; LEDGER #104.
- **Problem and evidence:**
  - MAIN step 2 lists C03 to C10, C01 and C11. C03 (the macOS unreadable-settings guard) is now in #104 (LED-14). Check it against MAIN's acceptance: a failed bootstrap preserves cached snapshot bytes and performs no reconciliation writes, and intentionally empty settings still remove obsolete accounts.
  - COR-01 (MAIN C04, TMP R-LNX-10): publication can resurrect removed, disabled or renamed accounts. `APP/AppModel.swift:199-212,248-271` revalidates only Venice; `LD/QuotaDaemon.swift:271-285,311-320` publishes without a final settings read. #104 deferred the case where an in-flight refresh re-saves an old Venice estimate.
  - COR-02 (MAIN C05, TMP R-LNX-04): no cross-process refresh owner; the daemon, the one-shot CLI and tray or Waybar clicks run independently (`LD/QuotaDaemon.swift:359-374,435-448`), and the Claude pending marker is not an exclusive claim (`QC/ClaudeCodeRenewal.swift:65-94`). Duplicate launch windows are source-confirmed; actual server revocation was not observed.
  - COR-03 (MAIN C06, TMP R-UX-02): failed saves reported as success, outcomes shown only on Settings > Overview. #104 fixed the Linux CLI half (R-LNX-05); `APP/AppModel.swift:163-184,550-578,1603-1611` remain.
  - COR-04 (MAIN C10, TMP R-BUG-26, R-LNX-11): cancellation becomes ordinary failure (`QC/HTTPClient.swift:29-34`); #65 reports a transport rethrow only.
  - COR-05 (MAIN C08): Linux proactive renewal batches rotations until every account finishes (`LD/QuotaDaemon.swift:258-268,385-406`).
  - COR-06 (MAIN C01, TMP R-DEBT-02): historical failure strings and a structured display boundary; #70 covers new failures only.
  - COR-07 (MAIN C11): settings recovery, versioned envelopes, last-good backups.
  - SEC-01 (MAIN C07, TMP R-SEC-06): imported OpenAI sync matches only the workspace id (`QC/OpenAICredentialSync.swift:36-59`) and can adopt another user's login.
  - SEC-02 (MAIN C09, TMP R-SEC-07): directory modes and owner and symlink checks; world-readable Linux data files; systemd units without sandboxing or `UMask`. #71 and #74 are partial.
  - Managed-auth lifecycle:
    - PRV-01 (TMP R-BUG-10): 401 and 403 both map to `.auth` (`QC/Clients/OpenAIClient.swift:44-50`, `QC/Clients/AnthropicClient.swift:44-49`), and forced recovery has no memory (`APP/AppModel.swift:221-230`, `:730-763`; `LD/QuotaDaemon.swift:434-456`). Each cycle can rotate grants and log the user's Codex CLI out; a `claude setup-token` token gets a scope 403 that reconnecting cannot fix. Unverified: whether chatgpt.com returns 403 to a valid token.
    - PRV-02 (TMP R-BUG-14): quitting or logging out during a managed Codex fetch leaves `Operations/<id>.pending` (`QC/CodexAccountService.swift:119-174`), forcing a reconnect; there is no `applicationShouldTerminate` (`APP/LLimitApp.swift:5-13`, Quit at `:870-872`).
    - PRV-03 (TMP R-BUG-15): a launched renewal that exits non-zero leaves the marker, so a short offline window requires a full reconnect (`QC/ClaudeCodeRenewal.swift:74-76`, `:87-100`). Unverified: whether Claude Code exits non-zero offline without reaching the token endpoint.
    - PRV-04 (TMP R-BUG-16): an open reconnect terminal makes a working account fail with "still renewing" (`APP/AppModel.swift:199-202`, `:937-942`).
    - PRV-09 (TMP R-BUG-43): a leftover `.oauth_refresh.lock` or `<profile>.lock` blocks renewal and removal forever (`APP/Services/ClaudeProfileService.swift:133-137`); Claude Code's own stale rule is 60 s.
  - Keep bounded: DEBT-02 (MAIN C12, TMP R-DEBT-03: `Dictionary(uniqueKeysWithValues:)` in `QC/QuotaCoordinator.swift` traps on duplicate provider clients, and accounts without a client are dropped silently at `:42-44`); PRV-22 (MAIN A09: magnitude-only epoch scaling, 0/-1 reset sentinels and machine-timezone month helpers in `QC/Utilities.swift`). Define the invariant and fix at the provider boundary; no registry rewrite or global magnitude guess.
- **Proposal:**
  1. Work in the note's order: COR-01 to COR-07, then SEC-01 and SEC-02, then PRV-01 to PRV-04 and PRV-09. COR-01, COR-03 and COR-05 share the daemon's commit point; COR-04's cancellation guards sit at the same points.
  2. Hold the AGENTS.md constraints: never hold the settings lock across network work; acquire an exclusive durable operation record before launching a renewal or app-server, keep timed-out children and their records, never replay a possibly rotated grant, never remove a namespace with a pending operation; managed accounts never adopt global Codex or OpenCode tokens; managed Claude profiles match profile UUID plus verified account and organization UUIDs; renewal material reaches only the official CLI.
  3. Reuse reported pieces instead of rebuilding them: #65 transport rethrow, #70 safe messages, #71/#74 secure writes, #77 `retryAt`, #78 quarantine, #86 `env:` references (which every token rotation must preserve).
- **Tests / acceptance:** each cluster's own acceptance, notably: barrier-controlled remove, disable, rename and key-change during a fetch (COR-01); two-process barriers launch one exchange or renewal (COR-02); injected save failures leave durable state unchanged and exit nonzero (COR-03); cancelling a suspending fetch writes no snapshot or history (COR-04); B blocked after A rotates finds A already durable (COR-05); legacy fixtures with reflected tokens leak nothing (COR-06); truncated and newer files keep their originals (COR-07); a same-workspace, different-user JWT is rejected (SEC-01); permission, symlink, type and owner tests (SEC-02); a 403 triggers no token exchange and a second failure with the token just obtained does not force again (PRV-01); drain waits for release and keeps the record on timeout (PRV-02); preflight false means no persist, renewal or marker (PRV-03); a hidden reconnect sheet does not stop usage updates while the cached token is valid (PRV-04, manual); stale-lock helper tests (PRV-09). Unrelated green tests do not prove these invariants; use synthetic transport and storage, never real OAuth credentials.
- **Relations:** LED-14, LED-29, LED-44, LED-45, LED-47, LED-48, LED-56. ORD-04 holds SEC-03 (profile sweeper) and PRV-08 (Codex forced rotation). PRV-06 (MAIN A04, managed Codex error kinds) and PRV-07 (TMP R-UX-13) are the next managed-auth items in neither order. PRF-01 (an interval change cancels the in-flight refresh), PRF-04 (store mutation), PRF-05 (no replay of OAuth exchanges). PRV-01 edits `QC/Clients/AnthropicClient.swift`, which #93 and #84 also change (TMP shortlist 4). AppModel.swift conflicts with #94, #101, #102, #104, #106 and #107.

### ORD-04 Truthful display (TMP's next tier)
- **Status / severity / effort / platform:** open. Severity: LNX-01 high (TMP R-LNX-01); the others medium. Effort: S to M each (WID-01 S, PRV-08 S, the rest M). Platform: WID-01, LNX-01, PRV-08, the PRF-01 scheduler, the WID-02 helper and the Codex sweep in SEC-03 are Linux-testable; WID-07 and the widget rendering parts are macOS-only.
- **Sources:** TMP "Next tier (not shortlisted)": R-BUG-07, R-UX-01, R-A11Y-01, R-SEC-05, R-BUG-17; plus TMP R-BUG-21, R-BUG-22, R-LNX-01 and MAIN F06, W04, W09, L02, L03; LEDGER #102, #105.
- **Problem and evidence:**
  - WID-01 (TMP R-BUG-07): tiles and dashboard rows show the provider's fixed pair (`QC/ProviderMetricSelection.swift:29-51`: OpenCode Go rolling + monthly, Cline five_hour + weekly, Anthropic five_hour + seven_day) while sorting, "lowest X% left", the menu bar and Linux `status` use the minimum over all metrics. An OpenCode Go account whose weekly window is rate-limited sorts first and drives "lowest 0% left" but reads "55% / 70%" with no dashboard warning. #81's exhausted rendering does not change the pair.
  - WID-02 (TMP R-BUG-21, MAIN W09): after `resetAt` passes, the tile shows "now" and an orange "!" around the old ring (`WX/ProviderQuotaWidget.swift:189-195`, `:610-623`, `:778-781`) and the dashboard shows the stale percentage with no marker (`WX/LLimitQuotaWidget.swift:495-533`), for up to a full interval. A tile's last entry can precede the stale threshold, and a delayed reload freezes "Data is current" (W09; macOS delay frequency unmeasured).
  - LNX-01 remainder (TMP R-LNX-01, MAIN L02, L03): #105 adds the failure keys, failure-only accounts, class elevation, account-named ERROR lines and tray error rows. Left: the stale threshold is a 6 h constant in #105 instead of following the configured interval (#105 deferred recording `refreshIntervalMinutes` in the snapshot; #50 reports an interval-aware threshold), and #108's template `{stale}` and `check`/`pick` use 2 h (integration check); the key set must be reconciled with #64 (ORD-01); MAIN L03's tray spending warnings and partial failures when cached accounts exist (`Packages/LLimitd/tray/llimit_tray.py:138-159,301-304`; unverified whether #105 covers spending warnings); cross-account severity and recency ordering and all-failed health (MAIN's #64 note).
  - WID-06 (TMP R-UX-01, MAIN W04): color identity is positional (`QC/ProviderMetricSelection.swift:168-209`, `accountColorStep` is `index % 3`). Adding a Claude account recolors later accounts' history; renaming swaps variants and automatic Tile 1 as you type (`APP/AppModel.swift:1170-1179`); a fourth account repeats the first, and per-account dash patterns do not separate them on the legend-less trend chart. TMP: rename stability is not an AGENTS.md promise, so this is a design improvement, but it conflicts with "two accounts must never share an exact color scheme" at 4+ accounts. MAIN: increasing the modulus fails because higher steps all become pale.
  - WID-07 (TMP R-A11Y-01): nothing reads `widgetRenderingMode` or uses `.widgetAccentable()` (`WX/ProviderQuotaWidget.swift:705-782`, `WX/LLimitQuotaWidget.swift:205-237`). In vibrant and Monochrome rendering, session #3ED8F0 (luminance 0.564) and weekly #FFC145 (0.598) differ by 1.06:1 and become the same gray.
  - SEC-03 (TMP R-SEC-05): "cleanup is pending" never happens. Nothing reads `RetainedProfiles/` or lists `CodexProfiles/` (`APP/Services/ClaudeProfileService.swift:139-197`, `QC/CodexAccountService.swift:110-113`), so removed accounts keep live refresh grants on disk and in Keychain.
  - PRV-08 (TMP R-BUG-17): every managed Codex poll sends `account/read {refreshToken: true}` (`QC/CodexAccountService.swift:95`), rotating the refresh token every 15 to 30 minutes and widening PRV-02's loss window. Unverified: whether `account/rateLimits/read` refreshes on its own after a 401; a Codex capture is required first.
  - PRF-01 (TMP R-BUG-22, MAIN F06): a snapshot younger than one interval skips the bootstrap refresh and the loop waits a full interval more (`APP/AppModel.swift:1763-1786`, `:1797-1812`; `LD/QuotaDaemon.swift:336-375`), so data can reach about twice the interval in age. No wake or network observation, no backoff, and #102 deferred the auto ticks dropped during targeted refreshes.
- **Proposal:**
  1. WID-01: keep the first preferred metric; substitute the most constrained other bounded metric for the second slot when its `remainingPercent` is lower; ties keep the preference; never substitute unlimited or percentage-less metrics. Update the pinned test (`ProviderMetricSelectionTests.swift:74-85`). Identity colors are unaffected because `limitSeriesSlots` runs over the full list.
  2. WID-02: `UsageMetric.isResetPending(at:)` and a `.resetPending` display state (dashed tile track and "reset" footer; neutral dashboard bar), a timeline entry at the earliest `resetAt` and explicit stale boundaries. Never assume a refill: LED-17 already turns expired carried metrics unknown. The display helper can land first; waking the app at the earliest `resetAt` plus 60 s (bounded by each provider's minimum poll interval) needs PRF-01's scheduler. Coordinate with the Reset Celebration glow (`4768e74`, probably #82).
  3. LNX-01: carry the configured interval into the snapshot (or adopt #50's threshold) and base `stale` on 2x the interval, in `status` and in #108's template, `check` and `pick`; show remaining spending and partial failures in the tray regardless of cached accounts; additive keys only.
  4. WID-06: persist identity (`colorVariant` on `ProviderStyleSettings`, or an append-only `stableAccountRanks`) seeded from today's order; give 4+ accounts a second channel (`markerIndex = index / 3`: circle, square, diamond, triangle) on chart endpoints and tiles, with no in-chart legend; keep the three validated variants (a fourth needs the palette validator). Update the AGENTS.md wording.
  5. WID-07: when the mode is not `.fullColor`, add a stroke style per window kind, draw the primary window accentable at full opacity and the secondary at 0.5, drop shadows and casing; hues stay unchanged.
  6. SEC-03: a sweeper at bootstrap and after each refresh that removes unreferenced Claude profiles and Codex namespaces with no session, renewal, refresh lock or `.pending` marker; list the rest under a "Leftover sign-ins" section with a warned delete. That section is a policy decision to record in AGENTS.md.
  7. PRV-08, after the capture: default `refreshToken: false`, force only when `exp` is missing or within about 10 minutes, retry once after `serverRejected`, keep the identity re-checks.
  8. PRF-01: a pure `RefreshSchedule.nextDue(...)` in QuotaCore (bootstrap due = `generatedAt + interval`; 1, 2, 4 minute backoff capped at the interval; settings mtime makes a refresh due), loops that sleep `min(60 s, due - now)`, wake and `NWPathMonitor` observers and `beginActivity` on macOS.
- **Tests / acceptance:** OpenCode Go with weekly at 0% gives `[session-rolling, weekly]`, Cline with monthly at 0% gives `[five_hour, monthly]`, healthy accounts keep today's pairs (WID-01). The reset helper before, at and after `resetAt` (WID-02). StatusRenderer tests at 15- and 180-minute intervals mark staleness correctly (LNX-01). Adding or renaming accounts leaves variants and automatic tiles unchanged, legacy settings decode to today's steps, 12 accounts give 12 unique (step, marker) pairs (WID-06). Manual Monochrome and tinted checks on macOS 26 (WID-07). A sweep over referenced, unreferenced and marker-bearing namespaces (SEC-03). Far-from-expiry tokens send `false`, near-expiry `true`, a rejected read gets one forced retry (PRV-08). `nextDue` table tests across sleep gaps, interval changes, overdue launch, backoff and mtime change (PRF-01).
- **Relations:** LED-15, LED-17, LED-43, LED-51, LED-52. WID-08 (TMP R-THM-02 with MAIN W08: deep variants nearly vanish on widget surfaces) is paired with R-A11Y-01 in TMP's executive summary item 13 but is in neither order; schedule it with WID-07 or ORD-07's theming work and rerun the palette validator. IDEA-08 (account badges) extends WID-06's second channel; MAC-19 (MAIN M13) must not undo it. IDEA-18 reuses `defaultRingMetrics`, which WID-01 changes. #90 adds `tokens-weekly` to the preferred ids in `QC/ProviderMetricSelection.swift`, the file WID-01, WID-14 (TMP R-VIS-02) and MAC-18 (TMP R-BUG-35) also edit (TMP shortlist 10). WID-10 (the rest of R-VIS-05 that #109 deferred) shares `WX/LLimitQuotaWidget.swift` with #109. PRF-06 (timeline entries). SEC-03 complements PRV-02. COR-08 (single-account refreshes bump `generatedAt`, which PRF-01 would trust).

### ORD-05 Measure, then bound performance
- **Status / severity / effort / platform:** open. Severity: mostly unrated (MAIN); TMP rates PRF-03, PRF-06 and PRF-10 low. Effort: M to L overall. Platform: QuotaCore stores, transport and parsing are Linux-testable (verify URLSession timeout behavior on both Darwin and corelibs); persistence wiring, widgets and dashboard views are macOS-only.
- **Sources:** MAIN AM-ORDER-3 (F01 to F05, F08, F09, F11, F12; the scheduler F06); TMP R-BUG-33, R-PERF-02, R-PERF-06; LEDGER #94, #101.
- **Problem and evidence:**
  - Source inspection proves blocking work and full-archive decoding on the main actor, not measured stutter, multi-second hangs, OOM or a fixed WidgetKit memory limit; the older 30 MB widget budget is unverified. The only measurement is TMP's Linux swift-foundation benchmark: 3,000 snapshots x 4 accounts is about 8 MB, about 0.28 s per decode and 0.33 s per encode. macOS was not measured.
  - Already done: #94 cuts a publish to one decode and one encode; #101 (and #85 or #68, per ORD-01) reduce edit saves; #78 quarantines corrupt stores; #79 removes a force unwrap.
  - Open: PRF-02 (MAIN F02, synchronous encode, write and reload on `@MainActor`, `APP/AppModel.swift:163-175,274-289`); PRF-03 (MAIN F01, TMP R-BUG-33: full decode before filtering in `QC/QuotaHistoryStore.swift:19-41`, an entry cap of 3,000 rather than bytes; at the 15-minute interval a 30-day window needs 2,880 entries, so about 120 extra appends truncate the chart); PRF-04 (MAIN F03, shared codecs in `@unchecked Sendable` stores and unlocked read-modify-write); PRF-05 (MAIN F05, `URLSession.shared`, unbounded bodies, request-only 10 s timeout, URL codes lost); PRF-06 (MAIN F07, TMP R-PERF-02: byte-identical App Group writes still reload all 14 widget kinds; trend entries carry raw history; tiles emit up to 37 entries); PRF-10 (MAIN F04, F10, TMP R-PERF-06: spark series rebuilt in view bodies, `primaryColorsByAccountID` rebuilt per access, AppStorage writes on every grip event); PRF-11 (MAIN F12: up to four sequential Copilot round trips, three sequential Cline calls; the roughly 40 s Copilot figure is inferred); PRF-12 (MAIN F11: two `ISO8601DateFormatter` allocations per parse, a decoder per response in eight clients, re-sorting in `accountColorStep`).
  - PRF-09 (MAIN F08): App Group syncs try twice and give up (`APP/AppModel.swift:1907-1950`, `:1999-2018`); a missed history append is never replayed.
  - MAIN F09 (Venice key purges) is LED-12 (#101; verify #68 before any further debounce work). MAIN F06 (scheduler) moved to ORD-04 as PRF-01.
- **Proposal:**
  1. Profile first: Instruments, RSS and archive sizes, with benchmarks of 12 accounts with several metrics at 3,000 entries and with 45-day archives (append latency, UI stalls, widget RSS).
  2. Do the compact widget projection (PRF-06 with PRF-03's bounded `quota-trend.json`), serialized off-main persistence behind an application service (PRF-02 with PRF-04's operation-local codecs and per-file serialization) and cached series (PRF-10) before any storage redesign. Partitioned, indexed or append-only storage only with preservation tests and a measured need.
  3. Decide the retention policy that #94 deferred (TMP: every entry from the last 48 h, then hourly plus reset jumps, holding 45 days in about 1,100 entries) and add a byte bound.
  4. Transport bounds (PRF-05) before per-client budgets (PRF-11). Never replay OAuth or other ambiguous token exchanges; keep Cline's AGENTS.md rules when parallelizing its calls.
  5. PRF-12 only where profiling shows cost. Do not trade fewer allocations for shared-codec races: no unsynchronized shared `ISO8601DateFormatter` or decoder on corelibs; prefer `ISO8601FormatStyle` or operation-local instances; sorts need a total comparator because Swift `sorted` is not stable.
  6. Repair PRF-09: at bootstrap, reconcile the redacted settings and the latest local snapshot into the App Group, retry a bounded number of times, reload the affected timelines and expose the unavailable state (WID-03).
  7. Suggestion: PRF-07 (TMP R-PERF-03, a full credential scan per refresh) and PRF-08 (TMP R-PERF-04, interactive Keychain reads on the main actor) appear in neither order; they are main-actor work in the same AppModel code as PRF-02 and fit beside it.
- **Tests / acceptance:** the same benchmarks before and after each change. Slow-storage tests show responsive typing and resize with a durable final edit; Instruments shows no main-thread encode or write. Concurrent append and purge keep unrelated data. 3,200 entries at 15 minutes plus 50 extras still give `loadRecent(days: 31)` at least 30 days with the reset jumps. An identical redacted payload writes and reloads nothing. Slow, oversized, 429 and 5xx fixtures respect the bounds. An injected transient App Group failure recovers without another credential edit.
- **Relations:** LED-05, LED-12, LED-34, LED-48, LED-49, LED-55. LES-02 (#52/#75/#76 semantics survive any archive change). COR-02 (cross-process writers). The TMP usage ledger (ORD-07) sits outside the history cap. AppModel.swift and LLimitApp.swift are edited by several of this pass's PRs; rebase onto them (merge conflicts in ORD-01).

### ORD-06 Freshness, notices, accessibility and Linux operations
- **Status / severity / effort / platform:** open. Severity: medium to low. TMP rates R-UX-03, R-A11Y-03, R-A11Y-05, R-LNX-06, R-LNX-08, R-LNX-09 and R-SEC-04 medium, R-LNX-03 high (now mostly in #104) and the rest low; MAIN does not rate these. Effort: S to M per item. Platform: Linux account edits, packaging, docs and the notice evaluator are Linux-testable; accessibility, widget load states and deep links are macOS-only with manual VoiceOver and Accessibility Inspector checks.
- **Sources:** MAIN AM-ORDER-4; TMP R-UX-03, R-UX-19, R-UX-22, R-A11Y-03, R-A11Y-05, R-A11Y-06, R-A11Y-07, R-LNX-03, R-LNX-06, R-LNX-08, R-LNX-09, R-LNX-23, R-SEC-04, R-BLD-05, R-BLD-06; MAIN W03, W07, W13, W14, M02, M05, M06, M11, L05 to L11; LEDGER #95, #104, #109.
- **Problem and evidence:**
  - Freshness, WID-05: #95 aligned the dropdown ages (R-UX-03) and deferred the optional "Updated 2 min ago · oldest 35 min ago" header (`QuotaSnapshot.oldestFetchedAt`). MAIN W14: widget rows still lack per-account source age; #80's 2x-interval badge is aggregate, and a fresh aggregate attempt can carry an old `ProviderUsage.fetchedAt`.
  - Notices, PRD-04: build on #97, #100 and #110 after ORD-01 picks one evaluator and one threshold set (WID-04). Missing: quiet hours, Focus awareness, macOS reset and reconnect notices, alerts from `llimit refresh` and timer units, the alerts path in `llimit paths`.
  - Accessibility: MAC-04 (MAIN M02, W07, TMP R-A11Y-06: countdowns spoken as "4d 6h 56m", rings that do not name the limit, raw `rateLimit`/`notConfigured`, a trend label of only "Quota trend chart"; #56 covers some Settings labels); MAC-05 (TMP R-A11Y-05: no announcements anywhere, and Codex sign-in success silently dismisses the sheet); MAC-06 (TMP R-A11Y-03, MAIN M05: tertiary text at 3.77:1, 3.61:1 on hover, section titles 4.46:1, `colorSchemeContrast` never read, `APP/LLimitApp.swift:241-253`; Crazy Banana white text about 2.03:1); MAC-07 (TMP R-A11Y-07, MAIN M06: the GlossBar spring at `APP/LLimitApp.swift:398`, which #103 also left, and the jump scroll at `:644-647` ignore Reduce Motion, and jumping does not move VoiceOver focus); MAC-08 (MAIN M11, TMP R-UX-19: color-only state dots; a disabled account shows a green "Disabled", a red "Account disabled" and a gray sidebar dot, and two rows are titled "Credentials").
  - Linux account edits (remainders after #104): LNX-02 (TMP R-LNX-03: store a non-secret `importSource`; carry the Claude `expiresAt` into `anthropic.expires_at` and show "token expired: run llimit accounts update"; reconcile #104's `update`/`rename`/`reimport` with MAIN L09's `accounts set`). LNX-03 (TMP R-LNX-06: the local #104 head 17f970d, which is #104's final head, has `settingsLoadError` but no credential-free `daemon-state.json`, so once #108 makes `status` snapshot-only, an unreadable settings file never reaches the bar; #104's `makeDaemon` warning goes dead, and the integration check drops it). LNX-04 (TMP R-LNX-08, MAIN L06: shell-exported `XDG_*` never reach the systemd user manager, `LD/LinuxPaths.swift:20-41`; the installer ignores custom XDG roots, emits unquoted paths and mishandles `&` in sed, `Packages/LLimitd/systemd/install.sh:44-49,59-61`). LNX-05 (TMP R-LNX-09: #104 deferred the TTY confirmation with `--yes` and the 4-character minimum prefix). SEC-06 (TMP R-SEC-04, MAIN L09: secrets only via `--set key=value` on argv, `CLI/main.swift:117-122`, `:140-146`).
  - Packaging and install docs: BLD-05 (no maintainer scripts, so upgrades keep the old daemon running; `install.sh` `enable --now` does not restart active units, MAIN L05; `ca-certificates` only Recommended at `Packages/LLimitd/packaging/build-deb.sh:91`, MAIN L07; no `copyright` or changelog; amd64 only; no smoke test of the packaged binary, MAIN L10). BLD-06 (README builds debug at `README.md:214-215` while `install.sh:36` expects release; `install.sh -- --timer` at `Packages/LLimitd/README.md:89` exits 2, reproduced, MAIN L08; the contract table omits keys).
  - Widget load states, WID-03 (MAIN W03, TMP R-UX-22): tile and trend store failures collapse into no-account or empty states; #109 added the trend reasons but deferred "Store unavailable" in `WX/QuotaTimelineProvider.swift`; #79 only makes one initializer failable.
  - Deep links, WID-20 (MAIN W13): no `.widgetURL` anywhere, so tiles cannot open their account and dashboards cannot open a failing one.
  - CLI gaps, LNX-11 (TMP R-LNX-23, MAIN L11): #83 reports `llimit version`/`--version`/`-v` and `accounts list` data-state summaries from `StatusRenderer.accountQuotaSummary`. Still open per both sources: `accounts list --json`, rejecting unknown flags (`status --jsno` silently prints text), usage errors on stderr with exit 2, `--set` key validation and `accounts fields`, completions, `llimit doctor`, daemon `--quiet`, cross-account severity and recency order.
- **Proposal:** MAIN does not rank inside this step; choose focused items whose fixtures exist. Dependencies:
  1. Reconcile #83 before LNX-11; reuse its snapshot-only summary and verify release version embedding rather than rebuilding version flags.
  2. LNX-03's state file after #108 lands; LNX-02, LNX-05 and SEC-06 on top of #104 under the settings lock (one secret parser, `AccountAddArguments.parse`, shared with #104's update).
  3. PRD-04 after the #100/#110 decision; one QuotaCore evaluator, notices never recolor identity hues.
  4. BLD-06's contract table after the LNX-01 and LED-15 keys settle; LNX-04's `doctor` is the same command as LNX-11's.
  5. WID-20 needs a scoped app URL scheme and account route first, with credential-free URLs and frozen widget kinds.
  6. MAC-07's `DashboardMotion.spring(reduce:)` gate before further animated effects (#82 glow, Reset Celebration).
- **Tests / acceptance:** per cluster. Notable gates: an injected durable-save failure leaves settings unchanged and exits nonzero (SEC-06, LNX-02); an unreadable settings file renders class `error` from the snapshot side and logs once (LNX-03); an empty or 3-character fragment is rejected and a lowercase prefix resolves (LNX-05); first-install and upgrade fixtures show the new daemon PID and version, and a minimal install without recommendations reaches HTTP rather than a TLS failure (BLD-05); an LLimitd test asserts the documented key set equals the emitted keys (BLD-06); absent, corrupt and inaccessible container fixtures never show "No accounts configured" (WID-03); assigned, failing, unknown and removed account ids route safely (WID-20); manual VoiceOver, Reduce Motion and Increase Contrast checks for MAC-04 to MAC-08.
- **Relations:** LED-09, LED-14, LED-21, LED-27, LED-38, LED-49, LED-50, LED-53, LED-61. LNX-17 (MAIN L12, tray amount-only headline and reset radar) and LNX-12 to LNX-15 (TMP R-LNX-12 to R-LNX-15: systemd unit ordering and timeouts, the tray restart loop, `llimit refresh` exit codes, manual refresh feedback) are further Linux operations items in neither order. PRD-03 (expiring headroom) uses WID-20's routes. MAC-21 (#95 covered the dashboard part of R-UX-24).

### ORD-07 Visual modes, theming and new features last
- **Status / severity / effort / platform:** open. Severity: low or proposal, except BLD-02 (high per MAIN) as a release gate. Effort: per item; BLD-02 is L and needs owner decisions (Apple Developer ID, repository secrets). Platform: mostly macOS-only; the QuotaCore building blocks are Linux-testable.
- **Sources:** MAIN AM-ORDER-5; TMP "Shared building blocks"; MAIN M07, M09, M13, Build items 1 and 6, "Provider questions requiring sanitized fixtures"; TMP R-THM-01, R-IDEA-18; LEDGER #89, #90 deferrals.
- **Problem and evidence:**
  - These items depend on honest observations (ORD-03, ORD-04) and correct forecasts: PRD-01 (one estimator after the #109/#87 decision, reset-segmented and confidence-gated) and PRD-02 (#103's pace; Linux `paceDelta`; Muse weekly and Devin lengths only from API identity or reported durations).
  - IDEA-18 (TMP R-IDEA-18, MAIN AM-PROD-17): opt-in split-window menu bars and MAIN's calm/menu mode options (most-constrained single bar, fixed-width gauge or battery, monochrome template or badge). Today each bar is as tall as the most constrained window but colored by the longest (`APP/LLimitApp.swift:189-201`).
  - MAC-16 (MAIN M09): #73's system appearance does not validate a graphite light-surface palette.
  - MAC-11 (TMP R-THM-01, MAIN M07): presets carry ring palettes that are never drawn (`APP/WidgetStylePreset.swift:3-342`, 21 of 24 presets), `id(for:)` (`:299-305`; MAIN cites the matching at `:299-317`) still compares them, and several backgrounds fail white text (Crazy Banana #D9B21B 2.03:1, Default #5994F2 3.02:1).
  - DEBT-05 (MAIN Build item 6, optional): the six exhaustive switches duplicate provider metadata.
  - MAC-19 (MAIN M13): the provider-keyed legacy style fallback in `QC/Models.swift` reuses one entry for two same-provider accounts and saves identical inherited `primaryHexColor` values, so the tiles that act as the trend legend lose account identity.
  - Release and provider claims: BLD-02 (`.github/workflows/release.yml:37-54` disables signing and ad-hoc signs with no entitlement or notarization gates). PRV-27 (Zhipu no-supported-limit case, Zhipu/Z.ai percentages and endpoints, private Google and Anthropic headers; plus #90's unverified Zhipu weekly entry and #89's unread top-level `planInfo` and field-16 overage probing). PRV-28 (Claude CLI namespace and renewal compatibility and #91's detected-version User-Agent). PRV-29 (OpenAI additional limits, credits, `allowed`, reached type, absolute resets; duration-based metric ids as the root fix for R-BUG-13).
  - Shared building blocks (TMP), each built once:
    - Observed reset: a pure `QuotaEvents.observedReset(previous:current:)` that is true only when the current usage is fresh (`fetchedAt` later than the previous one), fetched after the previous metric's `resetAt`, and either `resetAt` moved forward or remaining rose by more than 4 points. Never declare a reset from the clock. The local #110 head e72725c has only a private `detectReset` (`QC/QuotaEvents.swift:301`) with different gates: the previous reading must be at or below the highest alert threshold and remaining must rise by the hysteresis. Extract and align it rather than writing a second detector.
    - Snapshot enrichment: one pure `SnapshotEnrichment.apply(previous:current:ledger:now:)` run in `AppModel.publishSnapshot` (`APP/AppModel.swift:274`, before the history append) and `QuotaDaemon.refreshNow` (`LD/QuotaDaemon.swift:283-316`, before `snapshotStore.save`), stamping optional credential-free fields so StatusRenderer and widgets stay snapshot-only. `ProviderUsage` has custom coding (`QC/Models.swift:357-381`) and needs explicit `decodeIfPresent`.
    - Usage ledger: a credential-free `usage-ledger.json` (mode 600) next to the history file, per (account id, metric id, window kind): the open window's fresh samples from the last 24 h, its minimum remaining and first time at 0, plus closed-window rows capped at about 500. Outside the 3,000-entry cap; purged with `purgeHistory`.
    - macOS command line (IDEA-03): until it ships, the CLI-based ideas are Linux-only.
- **Proposal:**
  1. Finish PRD-01 and PRD-02 semantics before any feature that reads forecasts or pace (IDEA-13 weather, the runway chip).
  2. Then visual modes and theming: IDEA-18 (Single stays the default; split columns need #96's track; above 6 accounts fall back to Single), MAC-16, MAC-11 (background-only presets, `id(for:)` ignoring ring colors, darken or retire backgrounds below 4.5:1, add "Dashboard Graphite" #1D1F27, swatches), WID-08 if not done with WID-07. Any default hex or `steppedColor` formula change reruns the palette validator on graphite `#1D1F27` and widget blue `#5994F2`; danger uses reserved accents, never identity recoloring; widget kinds stay frozen; no `AppIntentConfiguration`.
  3. MAC-19 as a migration only: consume a legacy match once or clear duplicate inherited primaries beyond the first deterministic match; explicit overrides stay authoritative; never recolor deliberate custom matches.
  4. DEBT-05 one genuine duplication at a time; Foundation data in QuotaCore, rendering in the UI; provider branding is not window identity.
  5. Product (PRD-03 onward) and ideas (IDEA-01 onward), each a bounded follow-up with its acceptance condition, reusing the building blocks above.
  6. Before claiming widget distribution or new provider semantics in a release: BLD-02 (Developer ID, matched monotonic app and extension versions, hardened runtime, notarization and stapling, clean-Mac shared-data validation; keep installed-only LaunchServices registration, recursive cleanup, the `chronod` and NotificationCenter restarts) and sanitized captures for PRV-27 to PRV-29.
- **Tests / acceptance:** `observedReset` table tests (fresh vs carried, before vs after `resetAt`, a 4-point rise, `resetAt` moving forward) shared by #110's alerts, IDEA-02, IDEA-06 and IDEA-11; old snapshot files decode with the enriched fields nil; a pure column-model test for IDEA-18; every preset distinct and at least 4.5:1 for white text (MAC-11); two siblings with one legacy entry keep distinguishable variants after save and reload (MAC-19); DEBT-05 tests cover every provider; nested signatures, entitlements, architectures and Gatekeeper pass on a clean Mac (BLD-02).
- **Relations:** LED-27, LED-35, LED-46, LED-52, LED-57, LED-62. IDEA-01 depends on LED-17. PRD-14 (live theme preview), PRD-15 (type scale), PRD-16 (app icon). WID-09 (third-account "pale" variant below the chroma floor). DEBT-03 (localization).

### ORD-08 Documentation hygiene after merges
- **Status / severity / effort / platform:** open. Severity: low (TMP; MAIN rates executable docs medium). Effort: S. Platform: docs; the contract-keys and supported-sources drift tests are Linux-testable.
- **Sources:** TMP R-BKL-01 to R-BKL-10, R-BLD-05, R-BLD-08, R-BLD-09, R-BLD-12, and R-BUG-05 and R-BUG-06 (shortlist 4 asks to update and record units in the AGENTS.md Anthropic notes); the AGENTS.md "Provider API notes" convention for #89 and #90; MAIN Build item 2 and AM-LESSON-1; LEDGER #89, #90, #93.
- **Problem and evidence:**
  - BACKLOG.md is historical input. BKL-01 to BKL-11 list entries that are done, outdated or only partly open (CI outage, global Claude-token replacement, automatic Settings scan, provider-unaware dashboard pairing, cloned dashboard timelines must not be resurrected). Merging this pass's PRs retires more entries, for example `BACKLOG.md:16-17` ("Restore runnable CI").
  - Contract and install docs: BLD-06 (README build command, `install.sh --timer`, the contract table that #105, #64, #50 and #108 extend); BLD-07 (CICD.md describes a different CI; RELEASING.md and `README.md:226` misstate `scripts/release.sh`, which pushes only with `--push`); BLD-10 (Settings names 4 import tools at `APP/Views/SettingsView.swift:281`, the README 7, the `.deb` description 7 of 12 providers, while `QC/CredentialDiscovery.swift:75-89` runs 10 scanners).
  - AGENTS.md provider notes, checked against the local branch heads, which are the final PR heads: #89 (`opus/devin-exhausted-windows` at 30e0299) adds the proto3 omitted-zero rule, the credits rule, `hideDailyQuota`/`hideWeeklyQuota` and `overageBalanceMicros` to the Devin note. #93 (`opus/anthropic-windows` at 4f1aede) adds `seven_day_sonnet`, the generic `five_hour_*`/`seven_day_*` windows, skipped null windows, `extra_usage` amounts as minor units of `currency` (cents for USD), and the amount-only `extra_usage` metric. #90 (`opus/zai-weekly-tokens` at 4cdbdab) does not touch AGENTS.md, and AGENTS.md has no Zhipu or Z.ai API note at all, so the (`unit`, `number`) mapping ((3, 5) 5-hour tokens, (6, 1) weekly tokens) is undocumented.
  - Other AGENTS.md edits the sources call for: the color-identity wording (WID-06), the sweeper and "Leftover sign-ins" policy (SEC-03), the menu-bar description (IDEA-18), the provider lists in the adding-a-provider checklist (BLD-10), and the claim that LLimitd tests run in macOS CI (BLD-08).
- **Proposal:**
  1. After the ledger PRs merge, update BACKLOG.md per BKL-01 to BKL-11, retiring resolved entries without deleting remaining evidence.
  2. Regenerate the examples contract table from the renderer once the status keys settle; fix the README and installer commands; rewrite CICD.md and RELEASING.md from the current workflows (after BLD-03 and BLD-04 change them); add `CredentialDiscovery.supportedSources` and render the lists from it.
  3. Add a Zhipu/Z.ai note to AGENTS.md with #90 (or a follow-up), and confirm the #89 and #93 notes survive their rebases.
- **Tests / acceptance:** every documented command runs as written; the documented contract key set equals the emitted keys; every scanner has a `supportedSources` entry; AGENTS.md describes every provider whose parsing changed in the merged PRs.
- **Relations:** BKL-01 to BKL-11; BLD-06, BLD-07, BLD-08, BLD-10; LED-01, LED-02, LED-04; ORD-02 (BLD-01's BACKLOG line).

## Assembly notes and source ID index

Notes from assembling this document: disagreements between sections that need a
check before the affected work, corrections to the sources found while merging,
owners for deferrals the ledger lists without one, TMP's shortlist ratings, and
the source ID index.

### Open disagreements between sections

1. **#92 and the three panel-geometry tests (resolved).** BLD-01 said #92 adds
   them. LEDGER does not list them, and the local `opus/release-unblock` head
   `53350b7`, which LEDGER's final update gives as #92's final head, leaves
   `scripts/tests/MenuBarPanelGeometryTests.swift` and `BACKLOG.md` identical to
   baseline (ORD-02). BLD-01 now lists the tests as remaining.
2. **#105's age key.** Ledger overlap 3 and LED-15 say #105 adds per-account
   `fetchedAt` and `ageSeconds`. The worktree check in LNX-01 found `fetchedAt` but
   no `ageSeconds`. Check the PR before reconciling key names with #50.
3. **AGENTS.md slot rule.** Baseline `AGENTS.md:283-289` also requires keeping the
   slot loops in `scripts/build.sh` and `scripts/widget-diagnostics.sh` in sync, and
   explains the nested bundles (`WidgetBundleBuilder` takes at most ten widgets per
   block). A later AGENTS.md copy seen while merging omits that sentence. BND-07
   follows the baseline wording and MAIN BOUNDARY-6; check whether the omission was
   intended.

### Corrections to the sources found while merging

Each was checked while merging against the baseline source or, where noted, a PR
worktree, and is recorded in the named entry unless marked otherwise.

- TMP says the OpenCode Go client already treats `rate-limited` as 100% used
  (`QC/Clients/OpenCodeGoQuotaClient.swift:89-104`). At `2d6ac1e` the guard at
  `:90-91` throws `invalidResponse` when the status is `rate-limited` and the
  percent is not 100, so the fetch fails. #81 reports the fix (IDEA-01, LED-51).
- TMP's AGENTS.md citations `:207` and `:252` do not match the baseline file: the
  version rule is at `:275-276` and the adding-a-provider checklist at `:142-152`
  (Build section intro).
- TMP R-SEC-06 cites `QC/OpenAICredentialSync.swift:153-181`, past the end of the
  97-line baseline file (SEC-01).
- TMP's daemon citation `LD/QuotaDaemon.swift:411-425` and MAIN's `:438-448` are two
  different spots: adoption at `:411` (function `:411-429`), and
  `refreshOpenAIAccount` overwriting the account id at `:446-448` (BND-03, SEC-01).
- MAIN's "App `:1427-1440`" in the retired C02 evidence is `APP/LLimitApp.swift`
  (the `sparkPoints` append at now), not AppModel.swift (ledger table 2).
- MAIN lists the tray among surfaces showing literal `INF`/`--`. At baseline the
  tray (`TRAY/llimit_tray.py:75-76`, `:103-104`) and `LD/StatusRenderer.swift:43-44`
  print the English words "unlimited" and "no data" instead (DEBT-03).
- LEDGER's "6 h constant" for #105's stale threshold is 2x the maximum refresh
  interval (`LD/StatusRenderer.swift:24` on the #105 branch); the baseline threshold
  was 2 h (ledger table 1).
- TMP gives `QuotaDaemon.refreshNow` as `:283-316`; the baseline function is
  `:258-320`, with the save at `:312` (PRD-01).
- MAIN A09's "around year 5000" (PRV-22) is MAIN's figure. The year reached depends
  on the timestamp: by this merge's arithmetic (not in PRV-22), a millisecond value
  from 1973 reads as about year 5100, and one from 2000 as about year 32,000.

### Owners for deferrals listed without one

Ledger table 1 lists some deferred follow-ups without an owning cluster. They are
covered here:

| PR | Deferred follow-up | Owner |
|---|---|---|
| #92 | Toolchain checksum or PGP verification via a shared composite action; CI toolchain caching | SEC-05 |
| #92 | Restore terminal echo on signal; v1.0.1 scrollback release note; Musl branch in the `LD/SettingsLock.swift` and `CLI/main.swift` import blocks | SEC-07 (Musl branch also DEBT-06) |
| #92 | Run `scripts/test-panel-geometry.sh` in the Linux job | BLD-01 |
| #93 | Non-USD extra-usage amounts | PRV-14 |
| #104 | `remove` confirmation and `--yes`; 4-character minimum prefix | LNX-05 |
| #104 | Stored import source | SEC-06, BKL-03 (rule in BND-03) |
| #104 | Carry Claude `expiresAt` | LNX-02, BKL-11 |
| #104 | R-LNX-10: an in-flight refresh can re-save an old Venice estimate | COR-01 |
| #105 | R-LNX-16 light-panel tray icons | LNX-09 |
| #105 | Record `refreshIntervalMinutes` so the stale threshold follows the interval | LNX-01 |
| #108 | Snapshot merge and macOS still match failures by account id only | DEBT-06 |
| #109 | Rest of R-VIS-05 | WID-10 |
| #109 | R-UX-22 "store unavailable" empty state | WID-03 |
| #110 | `expiringUnused` flag in `status --json` | PRD-03 |
| #103 | R-NOV-01 remainder (`paceDelta` in Linux JSON, Muse and Devin window lengths) | PRD-02 |
| MAIN | C10 end-to-end cancellation and publication | COR-04 |
| MAIN | L12 tray headline for amount-only accounts and tray reset radar | LNX-17 |

### TMP implementation shortlist ratings

TMP's per-item ratings for its sixteen shortlist candidates, all now implemented by
this pass's PRs. "macOS UI: yes" means the change is verified only by the macOS CI
build plus a manual check.

| # | Shortlist item | TMP IDs | Linux test | macOS UI | Risk | Effort | Now |
|---|---|---|---|---|---|---|---|
| 1 | Unblock the next release: musl-safe imports, hidden secret input, musl CI build, macos-15 runners | R-BLD-02, R-SEC-01, R-BLD-01 | yes | no | low | S | #92 |
| 2 | Never wipe the snapshot on an unreadable settings file; report the failure; stop false successes | R-BUG-04, R-LNX-06, R-LNX-05 | yes | no | low | M | #104, #108 |
| 3 | Honest Linux bar and tray: failures, per-account names, live countdowns, safe markup | R-LNX-01, R-LNX-02, R-LNX-07 | yes | no | low | M | #105 |
| 4 | Anthropic model-specific weekly windows and correct extra-usage amounts | R-BUG-05, R-BUG-06, R-FEAT-01 | yes | no | low | S | #93 |
| 5 | Devin: omitted proto3 zeros are exhausted windows | R-BUG-02 | yes | no | low | S | #89 |
| 6 | Linux: update, reimport and rename accounts in place | R-LNX-03, R-BUG-20 (import-detection part) | yes | no | low | M | #104 |
| 7 | Venice key edits commit on submit | R-BUG-09 | no (only the `QuotaHistoryStore.remove` no-op skip) | yes | medium | M | #101 |
| 8 | Robust managed CLI launches: child PATH, proxy and CA variables, prerelease versions, cached probe | R-BUG-03, R-BUG-42, R-PERF-05 | yes | no | medium | M | #107 |
| 9 | Keep refreshing other accounts during OpenAI sign-in; explain a disabled Refresh | R-BUG-11 | no | yes | low | S | #102 |
| 10 | Z.ai and Zhipu: read every TOKENS_LIMIT entry | R-BUG-01 | yes | no | low | M | #90 |
| 11 | Dropdown layout: balanced gauges, visible "fetched" age, no repeated provider names | R-VIS-01, R-UX-06, R-VIS-11 | no (`accountDetailParts` is Linux-tested; row arithmetic runs in the swiftc harness) | yes | low | M | #95 |
| 12 | Trend widget: gate the depletion warning on live data, make it legible | R-BUG-12, R-A11Y-02 | yes (forecast in QuotaCore) | yes | low | M | #109 |
| 13 | Publish snapshots without redundant history decodes | R-PERF-01 | yes | no | low | S | #94 |
| 14 | Pace ticks against each window's own reset | R-NOV-01 | yes | yes | low | M | #103 |
| 15 | Linux quota alerts: thresholds, resets, auth failures, "use it or lose it" | R-LNX-21, R-NOV-02 | yes | no | low | M | #110 |
| 16 | Quota-aware scripting: `llimit check`, `llimit pick`, status templates | R-NOV-03, R-LNX-20 | yes | no | low | M | #108 |

### Source ID index

For every TMP and MAIN ID: the clusters whose Sources line names it ("owning
clusters"), and the boundaries, order steps and clusters that cite it as context
("also cited in"). For BOUNDARY and AM-ORDER labels the owner is the BND or ORD
entry itself. Every TMP ID (188) and every MAIN ID (132, including AM-* and
BOUNDARY-* labels) has at least one owner. A third table resolves the labels that
entries cite in other forms: MAIN's ledger rows (`AM-LEDGER-#NN`, the dashboard
part of W03), MAIN's provider questions (`AM-PROV-Q0` to `-Q6`), MAIN's evidence
bullets (`EVIDENCE-1` to `-7`), and TMP's refuted findings, rejected sub-claims
and rejected ideas, which entries cite by reviewer ID (for example `CLIENT-7` for
`REF-CLIENT-7`, `CLIENT-1` for `SUB-CLIENT-1-a`).

#### TMP findings and ideas (R-*)

| Source ID | Owning clusters | Also cited in |
|---|---|---|
| R-BUG-01 | LED-02, PRV-27 | BND-09, REF-08 |
| R-BUG-02 | LED-01, PRV-27 | BND-08, BND-09 |
| R-BUG-03 | PRV-05 | REF-20 |
| R-BUG-04 | LED-14, LNX-04 | BND-02, REF-22 |
| R-BUG-05 | LED-04 | ORD-08, REF-09 |
| R-BUG-06 | PRV-14 | ORD-08, REF-09 |
| R-BUG-07 | WID-01 | ORD-04 |
| R-BUG-08 | LED-17 | BND-08 |
| R-BUG-09 | LED-12 |  |
| R-BUG-10 | PRV-01 | ORD-03 |
| R-BUG-11 | LED-13 |  |
| R-BUG-12 | LED-22, WID-19 | BND-05, BND-08 |
| R-BUG-13 | LED-23, PRV-29 | REF-17 |
| R-BUG-14 | PRV-02 | BND-04, ORD-03, REF-21 |
| R-BUG-15 | PRV-03 | BND-04, ORD-03 |
| R-BUG-16 | PRV-04 | BND-04, ORD-03 |
| R-BUG-17 | PRV-08, PRV-29 | BND-04, BND-09, ORD-04 |
| R-BUG-18 | PRV-10 | BND-08, BND-09 |
| R-BUG-19 | PRV-11 | BND-09, REF-10 |
| R-BUG-20 | PRV-12 |  |
| R-BUG-21 | WID-02 | BND-08, ORD-04 |
| R-BUG-22 | PRF-01 | BND-05, ORD-04, REF-12 |
| R-BUG-23 | PRV-13 | BND-09 |
| R-BUG-24 | MAC-10 | BND-05 |
| R-BUG-25 | MAC-09 |  |
| R-BUG-26 | COR-04 |  |
| R-BUG-27 | COR-08 | BND-08 |
| R-BUG-28 | COR-09 | REF-14 |
| R-BUG-29 | COR-12 |  |
| R-BUG-30 | COR-13 |  |
| R-BUG-31 | COR-11 |  |
| R-BUG-32 | PRV-23 |  |
| R-BUG-33 | PRF-03 | ORD-05, REF-13 |
| R-BUG-34 | COR-10 | BND-06, BND-09 |
| R-BUG-35 | MAC-18, DEBT-05 | BND-05 |
| R-BUG-36 | PRV-21 | BND-09 |
| R-BUG-37 | LED-30 | BND-09 |
| R-BUG-38 | PRV-16, BKL-11 |  |
| R-BUG-39 | PRV-20 |  |
| R-BUG-40 | PRV-19 | BND-03 |
| R-BUG-41 | PRV-17 |  |
| R-BUG-42 | LED-19 |  |
| R-BUG-43 | PRV-09 | BND-04, ORD-03 |
| R-BUG-44 | MAC-17 | BND-06 |
| R-BUG-45 | MAC-31 |  |
| R-PERF-01 | LED-05 |  |
| R-PERF-02 | PRF-06 | ORD-05, REF-18 |
| R-PERF-03 | PRF-07 |  |
| R-PERF-04 | PRF-08 |  |
| R-PERF-05 | LED-20 |  |
| R-PERF-06 | PRF-10 | ORD-05 |
| R-VIS-01 | LED-06 |  |
| R-VIS-02 | WID-14 | BND-06 |
| R-VIS-03 | WID-12 |  |
| R-VIS-04 | WID-13 |  |
| R-VIS-05 | WID-10 |  |
| R-VIS-06 | LED-25 |  |
| R-VIS-07 | LED-11 |  |
| R-VIS-08 | LED-07 |  |
| R-VIS-09 | MAC-27 |  |
| R-VIS-10 | MAC-28, IDEA-16 | BND-08 |
| R-VIS-11 | LED-08 |  |
| R-VIS-12 | MAC-29 |  |
| R-VIS-13 | LED-46 |  |
| R-UX-01 | WID-06, IDEA-08 | BND-06, ORD-04, REF-16 |
| R-UX-02 | COR-03 |  |
| R-UX-03 | WID-05 | BND-05, ORD-06 |
| R-UX-04 | MAC-13 | BND-06 |
| R-UX-05 | LED-10 | BND-05, BND-06 |
| R-UX-06 | LED-09 | REF-23 |
| R-UX-07 | MAC-01 | BND-01 |
| R-UX-08 | MAC-02 |  |
| R-UX-09 | WID-04 | BND-02, BND-05 |
| R-UX-10 | WID-04 | BND-06 |
| R-UX-11 | WID-17 | BND-05, BND-07, REF-19 |
| R-UX-12 | MAC-12 | BND-05, BND-06 |
| R-UX-13 | PRV-07 |  |
| R-UX-14 | PRV-24 |  |
| R-UX-15 | MAC-22 |  |
| R-UX-16 | PRV-25 |  |
| R-UX-17 | PRV-26 |  |
| R-UX-18 | MAC-15 |  |
| R-UX-19 | MAC-08 | ORD-06 |
| R-UX-20 | MAC-23 |  |
| R-UX-21 | LED-26 |  |
| R-UX-22 | WID-03 | ORD-06 |
| R-UX-23 | PRV-06 |  |
| R-UX-24 | MAC-21 |  |
| R-UX-25 | MAC-26 |  |
| R-UX-26 | MAC-25 | REF-16 |
| R-A11Y-01 | WID-07, IDEA-08 | BND-06, ORD-04 |
| R-A11Y-02 | LED-24 |  |
| R-A11Y-03 | MAC-06 | ORD-06 |
| R-A11Y-04 | LNX-08 |  |
| R-A11Y-05 | MAC-05 | ORD-06 |
| R-A11Y-06 | MAC-04 | ORD-06 |
| R-A11Y-07 | MAC-07 | ORD-06 |
| R-A11Y-08 | MAC-30 |  |
| R-FEAT-01 | WID-16 | BND-01, BND-02 |
| R-FEAT-02 | PRD-01 |  |
| R-FEAT-03 | PRD-11 |  |
| R-THM-01 | MAC-11 | BND-05, BND-06, ORD-07 |
| R-THM-02 | WID-08 | BND-05, BND-06 |
| R-THM-03 | WID-09 | BND-05, BND-06 |
| R-THM-04 | PRD-16 | BND-07 |
| R-THM-05 | LED-37 |  |
| R-THM-06 | WID-15 | REF-11 |
| R-THM-07 | PRD-15 |  |
| R-NOV-01 | PRD-02 | BND-06, BND-08 |
| R-NOV-02 | PRD-03 | BND-06, BND-08 |
| R-NOV-03 | LED-21, IDEA-09 | BND-05 |
| R-NOV-04 | LED-18 |  |
| R-NOV-05 | PRD-12 |  |
| R-LNX-01 | LNX-01 | BND-01, BND-02, BND-08, ORD-04 |
| R-LNX-02 | LED-15 | BND-02 |
| R-LNX-03 | LNX-02 | BND-03, ORD-06 |
| R-LNX-04 | COR-02 | BND-04 |
| R-LNX-05 | COR-03 |  |
| R-LNX-06 | LNX-03 | BND-01, BND-02, ORD-06 |
| R-LNX-07 | LED-16 | BND-01, BND-02 |
| R-LNX-08 | LNX-04 | ORD-06, REF-22 |
| R-LNX-09 | LNX-05 | ORD-06 |
| R-LNX-10 | COR-01, BKL-10 |  |
| R-LNX-11 | COR-04 |  |
| R-LNX-12 | LNX-14 |  |
| R-LNX-13 | LNX-15 |  |
| R-LNX-14 | LNX-12 | BND-01, BND-02, BND-08 |
| R-LNX-15 | LNX-13 |  |
| R-LNX-16 | LNX-09, IDEA-17 |  |
| R-LNX-17 | LNX-16, IDEA-17 |  |
| R-LNX-18 | LNX-06 | BND-04 |
| R-LNX-19 | LNX-07 |  |
| R-LNX-20 | LNX-10 |  |
| R-LNX-21 | LED-27 | BND-01, BND-05 |
| R-LNX-22 | LED-58 | BND-08 |
| R-LNX-23 | LNX-11 | ORD-06 |
| R-BLD-01 | BLD-01 | ORD-02, REF-03 |
| R-BLD-02 | LED-03 | BND-05, ORD-02 |
| R-BLD-03 | BLD-04 | BND-07, ORD-02 |
| R-BLD-04 | BLD-03 | ORD-02 |
| R-BLD-05 | BLD-06 | ORD-06, ORD-08 |
| R-BLD-06 | BLD-05 | ORD-06 |
| R-BLD-07 | BLD-09 |  |
| R-BLD-08 | BLD-07 | ORD-08 |
| R-BLD-09 | BLD-07 | ORD-08 |
| R-BLD-10 | BLD-08 |  |
| R-BLD-11 | BLD-08 |  |
| R-BLD-12 | BLD-10 | BND-05, ORD-08 |
| R-SEC-01 | SEC-07 | ORD-02, REF-07 |
| R-SEC-02 | SEC-04 | REF-15 |
| R-SEC-03 | SEC-05 |  |
| R-SEC-04 | SEC-06 | ORD-06 |
| R-SEC-05 | SEC-03 | BND-04, ORD-04 |
| R-SEC-06 | SEC-01 | BND-03, ORD-03 |
| R-SEC-07 | SEC-02 | BND-01, ORD-03 |
| R-DEBT-01 | WID-03, DEBT-01 | BND-01, BND-05 |
| R-DEBT-02 | COR-06 | BND-01, BND-09 |
| R-DEBT-03 | DEBT-02 | BND-09, ORD-03 |
| R-DEBT-04 | LED-49 |  |
| R-DEBT-05 | DEBT-03 |  |
| R-BKL-01 | BKL-01, BKL-02 | ORD-08, REF-03 |
| R-BKL-02 | BKL-03 |  |
| R-BKL-03 | BKL-04 |  |
| R-BKL-04 | BKL-05 |  |
| R-BKL-05 | PRD-09, BKL-06 |  |
| R-BKL-06 | BKL-07 |  |
| R-BKL-07 | WID-01, BKL-08 |  |
| R-BKL-08 | MAC-34, BKL-09 |  |
| R-BKL-09 | BKL-10 |  |
| R-BKL-10 | BKL-01, BKL-11 | ORD-08 |
| R-IDEA-01 | IDEA-01 | BND-02, BND-06, BND-08 |
| R-IDEA-02 | IDEA-02 | BND-01 |
| R-IDEA-03 | IDEA-03 | BND-01, BND-02, BND-07 |
| R-IDEA-04 | IDEA-04 | BND-01, BND-02, BND-03, BND-08 |
| R-IDEA-05 | IDEA-05 | BND-01 |
| R-IDEA-06 | IDEA-06 | BND-02, BND-07, BND-08 |
| R-IDEA-07 | IDEA-07 | BND-02 |
| R-IDEA-08 | IDEA-08 | BND-02, BND-06 |
| R-IDEA-09 | IDEA-09 | BND-01, BND-02, BND-08 |
| R-IDEA-10 | IDEA-10 | BND-01 |
| R-IDEA-11 | IDEA-11 |  |
| R-IDEA-12 | IDEA-12 | BND-06, BND-08 |
| R-IDEA-13 | IDEA-13 | BND-02, BND-06, BND-08 |
| R-IDEA-14 | IDEA-14 | BND-08 |
| R-IDEA-15 | IDEA-15 | BND-07 |
| R-IDEA-16 | IDEA-16 |  |
| R-IDEA-17 | IDEA-17 | BND-02, BND-05, BND-06 |
| R-IDEA-18 | IDEA-18 | ORD-07 |

#### MAIN items (C, A, F, L, M, W; AM-*; BOUNDARY-*)

| Source ID | Owning clusters | Also cited in |
|---|---|---|
| C01 | COR-06 | BND-01 |
| C02 | LED-32 | BND-08, LES-02 |
| C03 | LED-14 |  |
| C04 | COR-01, BKL-10 |  |
| C05 | COR-02 | BND-04 |
| C06 | COR-03, DEBT-01 | BND-01 |
| C07 | SEC-01 | BND-03 |
| C08 | COR-05 | BND-04 |
| C09 | SEC-02 | BND-01 |
| C10 | COR-04 | BND-04, LES-05 |
| C11 | COR-07 |  |
| C12 | DEBT-02 | BND-05, BND-09 |
| A01 | LED-30 |  |
| A02 | LED-30 |  |
| A03 | PRV-15 | BND-09 |
| A04 | PRV-06 | BND-04 |
| A05 | PRV-18 | BND-03 |
| A06 | PRV-16, BKL-03, BKL-11 | BND-03 |
| A07 | PRV-17 | BND-03 |
| A08 | LED-13 |  |
| A09 | PRV-22 | BND-09 |
| F01 | PRF-03 | ORD-05, LES-02 |
| F02 | PRF-02 | BND-05 |
| F03 | PRF-04 |  |
| F04 | PRF-10 |  |
| F05 | PRF-05 | ORD-05 |
| F06 | PRF-01 | ORD-04, ORD-05 |
| F07 | PRF-06, REF-01 |  |
| F08 | PRF-09 | ORD-05 |
| F09 | LED-12 | ORD-05 |
| F10 | PRF-10 |  |
| F11 | PRF-12 | ORD-05, LES-04 |
| F12 | PRF-11 | ORD-05 |
| L01 | LED-14 | BND-02 |
| L02 | LNX-01 | BND-02, BND-08, ORD-04 |
| L03 | LNX-01 | ORD-04 |
| L04 | LED-15 | BND-08, LES-01 |
| L05 | BLD-05 | ORD-06 |
| L06 | LNX-04 |  |
| L07 | BLD-05 |  |
| L08 | BLD-06 |  |
| L09 | LNX-02, SEC-06 |  |
| L10 | BLD-05 |  |
| L11 | LNX-11 | BND-02, ORD-06 |
| L12 | LNX-17 | LES-01 |
| M01 | MAC-03 |  |
| M02 | MAC-04 | ORD-06 |
| M03 | MAC-14 | BND-08 |
| M04 | MAC-09 |  |
| M05 | MAC-06, MAC-11 | ORD-06 |
| M06 | MAC-07 | ORD-06 |
| M07 | MAC-11 | BND-06, ORD-07 |
| M08 | MAC-20 | BND-06 |
| M09 | MAC-16 | ORD-07 |
| M10 | MAC-24 |  |
| M11 | MAC-08 | BND-06, ORD-06, LES-03 |
| M12 | DEBT-03 |  |
| M13 | MAC-19 | BND-06, ORD-07 |
| W01 | LED-31 | BND-08 |
| W02 | LED-31 |  |
| W03 | LED-31, WID-03 | ORD-06 |
| W04 | WID-06 | BND-06, ORD-04 |
| W05 | WID-11 |  |
| W06 | LED-22 | BND-08 |
| W07 | MAC-04 | ORD-06 |
| W08 | WID-08 |  |
| W09 | WID-02 | ORD-04 |
| W10 | WID-18 | BND-08 |
| W11 | MAC-09 |  |
| W12 | WID-19 |  |
| W13 | WID-20 | BND-07, ORD-06 |
| W14 | WID-05 | BND-08, ORD-06, LES-05 |
| AM-BUILD-1 | BLD-02 |  |
| AM-BUILD-2 | BLD-07 |  |
| AM-BUILD-3 | BLD-08 |  |
| AM-BUILD-4 | DEBT-04 |  |
| AM-BUILD-5 | BLD-11 |  |
| AM-BUILD-6 | DEBT-05 |  |
| AM-LESSON-1 | BKL-01, BKL-03, BKL-04, BKL-08 | ORD-08 |
| AM-LESSON-2 | REF-01 |  |
| AM-LESSON-3 | MAC-24 |  |
| AM-LESSON-4 | LES-01 |  |
| AM-LESSON-5 | LES-02 |  |
| AM-LESSON-6 | LES-03 |  |
| AM-LESSON-7 | LES-04 |  |
| AM-LESSON-8 | LES-05 |  |
| AM-MAC-NL-1 | MAC-32 |  |
| AM-MAC-NL-2 | MAC-33 |  |
| AM-MAC-NL-3 | MAC-34 |  |
| AM-MAC-NL-4 | MAC-31 |  |
| AM-MAC-NL-5 | MAC-30 |  |
| AM-MAC-NL-6 | MAC-35 |  |
| AM-ORDER-1 | ORD-01 |  |
| AM-ORDER-2 | ORD-03 |  |
| AM-ORDER-3 | ORD-05 |  |
| AM-ORDER-4 | ORD-06 |  |
| AM-ORDER-5 | ORD-07 |  |
| AM-PROD-1 | PRD-05 |  |
| AM-PROD-2 | MAC-01 |  |
| AM-PROD-3 | PRD-14 |  |
| AM-PROD-4 | PRD-15 |  |
| AM-PROD-5 | PRD-08 |  |
| AM-PROD-6 | PRD-04 |  |
| AM-PROD-7 | PRD-13 |  |
| AM-PROD-8 | PRD-03 |  |
| AM-PROD-9 | PRD-01 |  |
| AM-PROD-10 | PRD-20 |  |
| AM-PROD-11 | PRD-21 |  |
| AM-PROD-12 | PRD-07 |  |
| AM-PROD-13 | PRD-02 |  |
| AM-PROD-14 | IDEA-06 |  |
| AM-PROD-15 | PRD-19 |  |
| AM-PROD-16 | IDEA-12 |  |
| AM-PROD-17 | IDEA-18 |  |
| AM-PROD-18 | PRD-06 |  |
| AM-PROD-19 | PRD-17 |  |
| AM-PROD-20 | PRD-09 |  |
| AM-PROD-21 | PRD-10 |  |
| AM-PROD-22 | IDEA-13 |  |
| AM-PROD-23 | PRD-06 |  |
| AM-PROD-24 | PRD-18 |  |
| AM-WID-VC-1 | WID-12 |  |
| AM-WID-VC-2 | PRD-15 |  |
| AM-WID-VC-3 | WID-11 |  |
| AM-WID-VC-4 | WID-21 |  |
| AM-WID-VC-5 | WID-21 |  |
| BOUNDARY-1 | BND-01, BND-02 |  |
| BOUNDARY-2 | BND-03 |  |
| BOUNDARY-3 | BND-04 |  |
| BOUNDARY-4 | BND-05 |  |
| BOUNDARY-5 | BND-06 |  |
| BOUNDARY-6 | BND-07 |  |

#### Ledger, provider-question, evidence and refuted labels

| Source label | Owning entry | Also cited in |
|---|---|---|
| AM-LEDGER-#66 | LED-14 (ledger table 2) | LNX-03, COR-07, ORD-01 |
| AM-LEDGER-#67 | LED-28 (ledger table 2) | MAC-04, MAC-13, MAC-26, LES-03 |
| AM-LEDGER-#70 | LED-29 (ledger table 2) | COR-06, ORD-01 |
| AM-LEDGER-#69 | LED-30 (ledger table 2) | PRV-13; the lessons intro (rejected review suggestions) |
| AM-LEDGER-#72 | LED-31 (ledger table 2) | WID-03, WID-05, ORD-01 |
| AM-LEDGER-#75 | LED-32 (ledger table 2) | COR-08, LES-02, ORD-01 |
| W03-dashboard | LED-31 | WID-03 (tile and trend remainder) |
| AM-LEDGER-#50 | LED-15 (ledger table 3) | LNX-01, LES-01, ORD-01 |
| AM-LEDGER-#51 | LED-33 | PRD-07, LNX-17, LES-01 |
| AM-LEDGER-#52 | LED-34 | PRF-03, LES-02, ORD-01 |
| AM-LEDGER-#53 | LED-35 | WID-09, MAC-20, PRD-14 |
| AM-LEDGER-#54 | LED-36 | WID-03, WID-12, ORD-01 |
| AM-LEDGER-#55 | LED-37 | IDEA-08 |
| AM-LEDGER-#56 | LED-38 | MAC-04, MAC-08, LES-03 |
| AM-LEDGER-#57 | LED-39 |  |
| AM-LEDGER-#58 | LED-40 | IDEA-13 |
| AM-LEDGER-#59 | LED-41 | PRD-06, REF-05 |
| AM-LEDGER-#63 | LED-42 | COR-06, ORD-01 |
| AM-LEDGER-#64 | LED-43 | LNX-01, ORD-01 |
| AM-LEDGER-#65 | LED-44 | COR-04, COR-06, PRV-10, PRV-15, PRV-23, PRV-27, PRF-12, REF-02, LES-05 |
| AM-LEDGER-#68 | LED-12 | ORD-01 |
| AM-LEDGER-#71 | LED-45 | SEC-02, ORD-01 |
| AM-LEDGER-#73 | LED-46 | MAC-06, MAC-16 |
| AM-LEDGER-#74 | LED-45 | SEC-02, ORD-01 |
| AM-LEDGER-#76 | LED-34 | PRF-03, LES-02, ORD-01 |
| AM-LEDGER-#77 | LED-47 | COR-06, PRF-05, PRF-01, ORD-01 |
| AM-LEDGER-#78 | LED-48 | PRF-04, COR-07, DEBT-01 |
| AM-LEDGER-#79 | LED-49 | WID-03 |
| AM-LEDGER-#80 | LED-50 | WID-05, WID-12, MAC-04, MAC-24, DEBT-03, LES-05 |
| AM-LEDGER-#81 | LED-51 | WID-01 |
| AM-LEDGER-#82 | LED-52 | MAC-07, IDEA-06 |
| AM-LEDGER-#83 | LED-53 | LNX-11 |
| AM-LEDGER-#84 | LED-54 | COR-10, PRV-27 |
| AM-LEDGER-#85 | LED-55 | PRF-02 |
| AM-LEDGER-#86 | LED-56 | SEC-06, COR-05, SEC-01 |
| AM-LEDGER-#87 | LED-57 | PRD-01, PRD-02, ORD-01 |
| AM-LEDGER-#88 | LED-58 | LNX-10, PRD-08, PRD-10 |
| AM-LEDGER-#91 | LED-59 | PRV-05, PRV-28 |
| AM-LEDGER-#97 | LED-21 | PRD-04, ORD-01 |
| AM-LEDGER-#98 | LED-58 | LES-02, PRD-17 |
| AM-LEDGER-#99 | LED-60 | LNX-10, REF-37 |
| AM-LEDGER-#100 | LED-61 | PRD-04, WID-04, ORD-01 |
| AM-LEDGER-BADGES | LED-62 | PRD-15 |
| AM-PROV-Q0 | PRV-27 (fixture rules) | BND-09 |
| AM-PROV-Q1 | PRV-10 |  |
| AM-PROV-Q2 | PRV-14 |  |
| AM-PROV-Q3 | PRV-11 |  |
| AM-PROV-Q4 | PRV-28 |  |
| AM-PROV-Q5 | PRV-29 |  |
| AM-PROV-Q6 | PRV-27 |  |
| EVIDENCE-1 to EVIDENCE-5 | Evidence section, "Test and CI results" |  |
| EVIDENCE-6 | Evidence section, "Not exercised" |  |
| EVIDENCE-7 | Evidence section, "Performance claims" |  |
| REF-CLIENT-7 (refuted) | REF-02 | PRV-10, BND-09 |
| REF-MENU-21 (refuted) | REF-03 | BLD-01, BKL-02 |
| REF-BUILD-8 (refuted) | REF-04 |  |
| REF-PRODUCT-15 (refuted) | REF-05 | PRD-06 |
| REF-GAPB-7 (refuted) | REF-06 |  |
| REF-GAPB-10 (refuted) | REF-07 | SEC-07 |
| SUB-APPMODEL-1 | REF-12 | PRF-01 |
| SUB-CLIENT-1-a, SUB-CLIENT-1-b | REF-08 | LED-02 |
| SUB-CLIENT-3, SUB-CLIENT-4 | REF-09 | LED-04, PRV-14 |
| SUB-CLIENT-9 | REF-10 | PRV-11 |
| SUB-CLIENT-14 | REF-11 | WID-15 |
| SUB-CORE-1 | REF-06 | COR-08 |
| SUB-CORE-7 | REF-13 | PRF-03 |
| SUB-APPMODEL-7 | REF-14 | COR-09 |
| SUB-BUILD-1 | REF-03 | BLD-01 |
| SUB-BUILD-7 | REF-15 | BLD-03, SEC-04 |
| SUB-SETTINGS-3, SUB-THEME-15 | REF-16 | WID-06, MAC-25 |
| SUB-WIDGET-2 | REF-17 | LED-23 |
| SUB-WIDGET-11 | REF-18 | PRF-06 |
| SUB-WIDGET-14 | REF-19 | WID-17 |
| SUB-AUTH-1 | REF-20 | PRV-05 |
| SUB-AUTH-4 | REF-21 | PRV-02 |
| SUB-LINUX-1, SUB-LINUX-14 | REF-22 | LED-14, LNX-04 |
| SUB-MENU-6 | REF-23 |  |
| RJ-IDEA-STREAKS | REF-24 | IDEA-11 |
| RJ-IDEA-ENVELOPES | REF-25 | PRD-02 |
| RJ-IDEA-SHIMMER | REF-26 | IDEA-12 |
| RJ-IDEA-DETENTS | REF-27 | MAC-30 |
| RJ-IDEA-VOICE | REF-28 |  |
| RJ-IDEA-EXEC | REF-29 |  |
| RJ-IDEA-PROMETHEUS | REF-30 |  |
| RJ-IDEA-SSH | REF-31 |  |
| RJ-IDEA-SHORTCUTS | REF-32 | PRD-10 |
| RJ-IDEA-PROJECT-LEDGER | REF-33 |  |
| RJ-IDEA-RESET-CLOCK | REF-34 | PRD-07 |
| RJ-IDEA-BURNDOWN | REF-35 | PRD-08 |
| RJ-IDEA-CALENDAR | REF-36 | PRD-08 |
| RJ-IDEA-COLOR-PACKS | end of the REF list (no cluster id) | WID-09, LED-35 |
| RJ-IDEA-TOP | REF-37 | LNX-10 |
