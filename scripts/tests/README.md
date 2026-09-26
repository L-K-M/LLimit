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

These manual checks involve real accounts and are separate from the synthetic
regression suite. The synthetic suite does not establish live OAuth compatibility.
