LLimit Review — tmp.md

Critical bugs found:
1. QuotaCoordinator applies VeniceQuotaEstimate to ALL providers (line 104-107 QuotaCoordinator.swift)
2. Main-actor persistence on every keystroke (AppModel.swift)
3. Dashboard forced dark mode (LLimitApp.swift line 601)
4. Menu bar icon grows unbounded (LLimitApp.swift)
5. Fixed settings label width (180pt) (SettingsView.swift)
6. Widget badges too small/low contrast (LLimitQuotaWidget.swift)
7. Settings window uses WindowAccessor with async mutation loop (potential race)

Performance: history archive rewrites whole file; refresh loop spins without coalescing; widget reload debounce drops reloads.

Visual issues: provider colors need CVD validation; ring glow is excessive; no light mode; no adaptive icon.

Delight ideas: Quota Weather, Reset Celebration, Mood Gauge, Menu Sparkline, Best Model to Burn, Focus-Session Budget, Honesty Mode, Quota Roulette, Pacing Rings.

Full details in the original tmp.md (lost, reconstructed from memory). Proceeding with implementations.
