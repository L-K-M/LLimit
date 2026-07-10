# Releasing LLimit

LLimit builds and releases entirely from the command line — no Xcode GUI.

## TL;DR

```bash
# Build locally (dev-signed, runs on your Mac) + reveal LLimit.app in Finder:
./scripts/build.sh

# Cut a release: bump version, tag, push -> GitHub Actions builds & publishes:
./scripts/release.sh 0.2.1
```

## Building locally (`scripts/build.sh`)

Requires macOS + Xcode command-line tools + [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
./scripts/build.sh                     # incremental dev-signed build -> reveals LLimit.app in Finder
./scripts/build.sh --clean             # reset wedged Xcode build daemons + wipe build/ first
./scripts/build.sh --dmg --zip         # also package dist/LLimit-<version>.{dmg,zip}
./scripts/build.sh --app-version 0.2.1 # override the stamped version
```

- **Dev-signed build** (default, no signing vars): the app is signed with the
  project's team so the embedded widget extension registers and can read the shared
  App Group container, and runs on *your* Mac. Packaging is opt-in — pass `--dmg`
  and/or `--zip` to produce distributables under `dist/`. If you copy the app to
  another machine, Gatekeeper will block it until you run
  `xattr -dr com.apple.quarantine /path/to/LLimit.app`.
- **Signed + notarized build** (for distribution): set the env vars below and the
  script signs with Developer ID, enables the hardened runtime, and notarizes:

  ```bash
  export DEVELOPMENT_TEAM="ABCDE12345"
  export CODE_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"
  export NOTARY_APPLE_ID="you@example.com"
  export NOTARY_PASSWORD="app-specific-password"   # appleid.apple.com
  export NOTARY_TEAM_ID="ABCDE12345"
  ./scripts/build.sh --dmg --zip
  ```

## Cutting a release (`scripts/release.sh`)

```bash
./scripts/release.sh 0.2.1            # bump + commit + tag v0.2.1 + push
./scripts/release.sh 0.2.1 --local    # also build locally before pushing
```

It bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, commits,
creates an annotated tag `v0.2.1`, and pushes the branch + tag. Pushing the tag
triggers the **Release** workflow.

## GitHub Actions (`.github/workflows/release.yml`)

Runs on every `v*` tag (or manually via *Run workflow*). It builds on a macOS
runner via `.github/workflows/release.yml` directly (the workflow inlines its own
`xcodebuild` + packaging — it does not call `scripts/build.sh`) and attaches
`dist/*.zip` and `dist/*.dmg` to a GitHub Release. Works out of the box producing
an **ad-hoc** build.

To produce **signed + notarized** releases, add these repository secrets
(*Settings → Secrets and variables → Actions*):

| Secret | What it is |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Your *Developer ID Application* cert exported as `.p12`, base64-encoded (`base64 -i cert.p12 \| pbcopy`) |
| `P12_PASSWORD` | Password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Any throwaway password for the temporary CI keychain |
| `DEVELOPMENT_TEAM` | Apple Developer team id (e.g. `ABCDE12345`) |
| `CODE_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (ABCDE12345)` |
| `NOTARY_APPLE_ID` | Apple ID email for notarization |
| `NOTARY_PASSWORD` | App-specific password from appleid.apple.com |
| `NOTARY_TEAM_ID` | Team id for notarization (usually same as `DEVELOPMENT_TEAM`) |

If `BUILD_CERTIFICATE_BASE64` is absent, the signing/notarization steps are
skipped and an ad-hoc artifact is published.

> Note: a Developer ID-signed, sandboxed-free app with an App Group + widget
> extension is fine for direct distribution (it just can't go on the Mac App
> Store). See [`AGENTS.md`](AGENTS.md) for why the host app isn't sandboxed.
