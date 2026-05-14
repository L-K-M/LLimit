# LLimit macOS Widget

macOS menu bar app and desktop widget that shows LLM account quota usage for manually configured provider accounts:

- OpenAI
- Zhipu AI
- Z.ai (`https://api.z.ai/api/monitor/usage/quota/limit`)
- Google Cloud (Antigravity)
- GitHub Copilot

Multiple accounts can be configured for the same provider, such as two separate OpenAI accounts.

## Requirements

- macOS 14+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Generate and Run

1. Install XcodeGen if needed:

```bash
brew install xcodegen
```

2. Generate the Xcode project:

```bash
xcodegen generate
```

Or run:

```bash
./scripts/bootstrap.sh
```

3. Open `LLimit.xcodeproj` in Xcode.
4. Select your Apple Developer signing team in both targets before running.
5. App Group identifier uses your signing team prefix: `$(TeamIdentifierPrefix)group.ch.lkmc.llimit` (must match both entitlements files and runtime resolution in `Shared/SharedConstants.swift`).
6. Run the `LLimitApp` target once, add provider accounts in preferences, then add the widget.
