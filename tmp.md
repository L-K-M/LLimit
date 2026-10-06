LLimit Project Review — tmp.md (reconstructed)

Key findings from the review session:

Critical bugs:
1. QuotaCoordinator applies VeniceQuotaEstimate to ALL providers (fixed in PR #57)
2. Main-actor persistence stuttering (not implemented, documented)
3. Forced dark mode (partially addressed in PR #73)

Performance:
- Whole-file history rewrites
- Widget reload debounce drops reloads
- No coalescing in refresh loop

Visual/layout:
- Menu bar icon unbounded
- Settings fixed label width
- Badge contrast issues (addressed in PR #82, accidentally added to #61)
- Provider colors need CVD validation

New features implemented:
- Quota Weather (PR #58)
- Best model to burn (PR #59)
- Reset Celebration glow (PR #82)
- Adaptive dark/light dashboard (PR #73)

Remaining shovel-ready ideas for future LLM work:
- Debounced persistence behind dedicated actor
- SQLite or append-only history storage
- Menu bar icon fixed-width modes
- Light-mode adaptive palette
- Search/filter accounts in Settings
- Per-account refresh scheduling
- Quota weather alert thresholds
- Mood gauge / calm-concerned-sweating states
- Menu sparkline mode
- Focus-session budget
- Quota roulette
- Pacing rings
- Honesty mode (verified/inferred/stale labels)
- Keychain-backed credential storage (opt-in)
- About/version panel
- Shortcuts/App Intents
- Auto-update (Sparkle)
- Battery / Low Power awareness
- CSV/JSON history export
