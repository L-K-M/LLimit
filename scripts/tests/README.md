# Claude terminal integration checks

On macOS, run `scripts/test-claude-profile.sh` from any directory. An optional first
argument selects an existing Xcode DerivedData directory to reuse its build cache.
The script builds the app, then links the production terminal session and QuotaCore
against the same SwiftTerm package used by the app. Xcode 26 and newer may require
Apple's optional Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
After building the latest source in Debug, use
`scripts/test-claude-profile.sh --skip-build <DerivedData directory>` to reuse that
build in CI. Reusing a stale build does not validate changes to QuotaCore.

The harness opens two fake CLI sessions in separate temporary profiles. It checks
the actual PTY, command arguments, filtered environment, working directory,
independent credential files, Unicode keyboard input, completion callbacks,
process exit codes, cancellation, and hiding a terminal without terminating login.
It also runs the production profile-retention service with an injected temporary
root: separate records must have private permissions, contain no credentials,
preserve profile files, and reject symbolic-link markers without modifying their
targets.
It never launches Claude Code, accesses Keychain, or uses real credentials.

Run `swift test --package-path Packages/QuotaCore` for the renewal sequence,
credential identity checks, failure recovery, and subprocess timeout regressions.

To verify the real sign-in flow manually:

1. In Settings, add Claude and choose **Connect Claude**. Finish the normal Claude
   Code browser login and confirm usage loads for the displayed email address.
2. Add a second Claude account with a different subscription. Confirm each row
   has the intended identity and usage, and your ordinary CLI login still works.
3. Hide a login terminal before finishing, then reopen it from its account.
   Confirm the same login process resumes and completing it updates that account.
4. Reconnect an account with a different identity and confirm LLimit rejects the
   mismatch. Signing in to an already connected account must report a duplicate.
5. After credentials approach expiry, refresh usage and confirm Claude Code
   renews that profile while the other account retains its own credentials.
6. For an existing imported Claude account, choose **Connect Claude**, then cancel
   with **Send Control-C**. Confirm its original credentials still work and the
   **Import or paste a token** controls remain available. A canceled sign-in must
   leave the existing credentials dictionary unchanged.
7. Finish sign-in while a global refresh is waiting on another provider. If that
   cycle fetches the new profile, confirm the queued login refresh reuses its
   successful result. An earlier result from an imported token or another profile
   must not suppress the new profile's first fetch. The core receipt tests cover
   profile isolation and the login-completion time boundary.
8. If LLimit exits during renewal, relaunch it and remove the account before
   renewal is verified, including while offline or without Claude Code installed.
   The account and cached token must leave settings; its CLI profile and Keychain
   item must remain intact, with a private `RetainedProfiles/<profile UUID>.json`
   record. Confirm the UI reports pending login cleanup. A missing or old CLI lock
   is not proof that renewal exited. Repeat with a settings-save failure: the
   account must remain and its profile must not be deleted. Core retirement tests
   cover callback ordering and failures; the host harness checks private records.
9. With a controlled snapshot-store write failure, complete a login and confirm
   fresh usage remains visible alongside a local-save warning. Do not re-poll
   Claude just to retry local persistence.

These manual checks involve real accounts and are separate from the synthetic
regression suite. The synthetic suite does not establish live OAuth compatibility.

# Codex browser sign-in integration checks

Run `swift test --package-path Packages/QuotaCore --filter Codex` for the isolated
Codex transport, profile store, service, identity, and rate-limit regressions.
`OpenAIClientTests` and `OpenAICredentialSyncTests` additionally cover routing and
keeping managed accounts out of global token adoption and renewal. The complete
QuotaCore suite runs these checks on macOS and Linux; the account-management UI
is macOS-only.

The transport tests launch temporary shell fixtures, not Codex. They verify the
initialize/initialized handshake, literal arguments, isolated environment and
working directory, interleaved notifications, concurrent responses, sanitized
errors, bounded message queues, cancellation, late replies after timeout, and
closing a pipe when the child has already exited. A timed-out operation must stay
tracked until its reply or process exit. The service tests exercise separate
profiles, identity checks around renewal, failed/canceled login, and durable
operation markers. Store tests cover private permissions, exclusive ownership,
symlink rejection, and refusal to delete an uncertain profile. These tests never
open a browser, contact OpenAI, or use real credentials.

The login fixture also reproduces Codex 0.144.4's notification ordering: browser
completion arrives before the auth cache reload and `account/updated`. Early
account reads return null. LLimit must wait for both successful completion and
the ChatGPT account update, in either order, without forcing token renewal.

A separate no-authentication smoke check on September 26, 2026 used the installed
Homebrew Codex 0.144.4 executable with a fresh temporary `CODEX_HOME`, file-backed
credential storage, and the ChatGPT-only login override. The official app-server
accepted initialize/initialized and `account/read` with `refreshToken: false`,
reported a null account, and exited with status 0 after stdin closed. This checks
protocol compatibility and that the normal Codex login was not inherited. It did
not start sign-in, read quota, or verify OAuth renewal.

To verify the real flow manually:

1. In Settings, add OpenAI and choose **Connect OpenAI**. Complete browser sign-in
   and confirm the intended email, account, and usage appear. Repeat with a second
   account and confirm your ordinary Codex CLI login is unchanged.
2. Cancel once while Codex is starting and once while browser sign-in is open.
   Confirm an existing account keeps its previous connection. Try a different
   identity during reconnect and a duplicate identity in a second row; both must
   be rejected without replacing either saved connection.
3. Refresh after the managed login needs renewal. Confirm the official Codex
   process updates only that account's private profile, while LLimit settings
   contain profile/identity metadata and no copied access or refresh token.
4. Disable one account, refresh all accounts, and confirm the disabled profile is
   not launched or changed. Re-enable it and confirm usage can refresh normally.
5. Interrupt a controlled fixture during renewal, then restart LLimit. Its durable
   pending marker must prevent reopening or deleting the uncertain profile. A
   reconnect uses a fresh profile; account removal may detach the old login with
   an explicit cleanup notice. Do not clear a marker merely because it is old or
   the original app process is no longer running.
6. Make the CLI unavailable or simulate a failed request. Confirm the last good
   usage stays visible with an error. A failed snapshot save after sign-in must
   retain fresh in-memory usage and show a local-storage warning.

Live browser sign-in, multiple real accounts, and expiry-driven renewal have not
been verified by the synthetic suite or the no-authentication smoke check.

# Limit color integration checks

On macOS, run `scripts/test-limit-colors.sh [DerivedData directory]`. The script
builds the app, then links its QuotaCore object with the shared SwiftUI color
resolver. To reuse a current Debug build, run
`scripts/test-limit-colors.sh --skip-build <DerivedData directory>`.

The harness checks resolved sRGB components: an account's chosen primary color
renders exactly for every account variant, ring and trend colors agree, and
session colors, unlimited colors, and missing or invalid overrides preserve
their defaults. Account accents follow the most constrained metric. These checks
exercise the production metric-selection helper and color resolver; they do not
render widget layouts or automate the Settings color picker.
