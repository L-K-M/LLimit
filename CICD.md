# CI/CD

LLimit ships with two GitHub Actions workflows that build, test, and release the
app straight from the repo. Everything runs on GitHub-hosted macOS runners and
requires **no secrets** — the app is built unsigned and ad-hoc signed, exactly
like a local `xcodebuild` build with signing turned off.

The Xcode project (`LLimit.xcodeproj`) is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), but the generated project is
committed, so CI builds it directly with `xcodebuild` and does not need XcodeGen
installed.

## Workflows
| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `.github/workflows/ci.yml` | PRs + pushes to `main` | Build the app (unsigned) and run the `QuotaCore` unit tests |
| `.github/workflows/release.yml` | Pushing a `v*` tag | Build a Release, ad-hoc sign it, and publish a `.zip` + `.dmg` to a GitHub Release |

## Continuous integration (`ci.yml`)
Runs on every pull request and on every push to `main`. Steps:

1. **Checkout** the repository.
2. **Select Xcode** with `maxim-lobanov/setup-xcode`, pinned to `16.2` so a
   runner-image bump can't silently change the toolchain.
3. **Install xcbeautify** (via Homebrew) to keep the `xcodebuild` log readable.
4. **Build app** — `xcodebuild clean build` on the shared `LLimitApp` scheme with
   `CODE_SIGNING_ALLOWED=NO`, so it builds with no certificate or provisioning
   profile. The result bundle is written to `TestResults.xcresult`.
5. **Test QuotaCore package** — `swift test` against the `QuotaCore` Swift package
   under `Packages/`. See the note below on why the tests run this way.
6. **Upload build results on failure** — if anything fails, `TestResults.xcresult`
   is uploaded as an artifact for inspection.

In-progress runs are cancelled when the same ref is pushed again
(`concurrency.cancel-in-progress: true`).

### A note on tests
There is no unit-test target inside the Xcode app project — the `LLimitApp`
scheme's test action has an empty `Testables` list, so `xcodebuild test` on it
would not execute anything. The real unit tests live in the **`QuotaCore` Swift
package** (`Packages/QuotaCore/Tests/QuotaCoreTests/`), which is the bulk of the
app's logic. CI therefore **builds** the app with `xcodebuild` and **tests** the
package with `swift test`. SwiftPM does not rely on Xcode schemes, so no
scheme-sharing is required for the test step.

### Scheme sharing
The `LLimitApp` scheme is **shared** (it is committed at
`LLimit.xcodeproj/xcshareddata/xcschemes/LLimitApp.xcscheme`), so GitHub Actions
can see it. If you ever regenerate the project and the scheme stops being shared,
re-enable it in Xcode via **Product → Scheme → Manage Schemes… → ✓ Shared**, or
keep it shared in `project.yml`; otherwise the CI build step will fail with
"scheme not found".

### Running CI checks locally
Reproduce the exact CI build and tests from the repo root:

```sh
# Build the app (unsigned), mirroring the CI build step
xcodebuild \
  -project LLimit.xcodeproj \
  -scheme LLimitApp \
  -destination 'platform=macOS' \
  -resultBundlePath TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  clean build | xcbeautify

# Run the unit tests
swift test --package-path Packages/QuotaCore
```

(`| xcbeautify` is optional — drop it if you don't have xcbeautify installed.)

## Releases (`release.yml`)
To cut a release:

```
git tag v1.2.3
git push origin v1.2.3
```

Pushing any `v*` tag triggers the release workflow, which:

1. Selects Xcode `16.2` and installs `xcbeautify` + `create-dmg`.
2. Derives `VERSION` from the tag (`v1.2.3` → `1.2.3`) and stamps it into
   `MARKETING_VERSION`; `CURRENT_PROJECT_VERSION` is set to the workflow run number.
3. Builds the app in **Release** configuration with `CODE_SIGNING_ALLOWED=NO`
   (no Developer ID, no provisioning profile).
4. **Ad-hoc signs** the app (`codesign --sign -`). This requires no certificate or
   keychain but is needed for the app to launch on Apple Silicon. It is **not** a
   Developer ID signature and the app is **not** notarized.
5. Packages a `LLimit-<version>.zip` (via `ditto`) and a `LLimit-<version>.dmg`
   (via `create-dmg`).
6. Publishes a **GitHub Release** named `LLimit <version>` with the `.dmg` and
   `.zip` attached and auto-generated release notes.

### Artifacts and Gatekeeper
Each release attaches the **unsigned** app two ways:
- `LLimit-<version>.zip` — the `.app` zipped with `ditto`.
- `LLimit-<version>.dmg` — a drag-to-Applications disk image.

Because the build is unsigned (no Developer ID) and not notarized, macOS
Gatekeeper will warn on first launch. To open it:

- **Right-click** (or Control-click) the app → **Open** → **Open**, or
- clear the quarantine attribute after copying it to Applications:

  ```sh
  xattr -dr com.apple.quarantine /Applications/LLimit.app
  ```

This caveat is also included in the auto-generated release notes.

## Secrets
**None are required.** Both workflows build with `CODE_SIGNING_ALLOWED=NO` and the
release is only ad-hoc signed, so there are no certificates, API keys, or other
secrets to configure — everything works on a fresh fork out of the box.

To distribute a properly signed, Gatekeeper-friendly build later, you would add
**Developer ID signing + notarization**, which needs:

- An Apple Developer **"Developer ID Application"** certificate (`.p12`) and its
  password, stored as repository secrets and imported into a temporary keychain
  during the build.
- The signing **team ID**, and a switch from ad-hoc `codesign --sign -` to signing
  with that Developer ID identity (dropping `CODE_SIGNING_ALLOWED=NO`).
- **Notarization** credentials for `xcrun notarytool` — either an App Store Connect
  API key (issuer ID, key ID, `.p8`) or an Apple ID + app-specific password — plus
  an `xcrun stapler staple` step on the `.app`/`.dmg`.
