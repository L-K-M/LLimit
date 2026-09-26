import AppKit
import Foundation
import QuotaCore

/// Runs production terminal sessions against a fake CLI, never the installed
/// Claude binary, a network endpoint, or the user's credential stores.
@main
struct ClaudeTerminalTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let files = FileManager.default
        let fixture = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("LLimit terminal \(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: fixture) }

        let executable = fixture.appendingPathComponent("fake claude;literal")
        try fakeCLI.write(to: executable, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let firstProfile = ClaudeCodeProfile()
        let secondProfile = ClaudeCodeProfile()
        let firstDirectory = firstProfile.directory(under: fixture)
        let secondDirectory = secondProfile.directory(under: fixture)
        for directory in [firstDirectory, secondDirectory] {
            try files.createDirectory(at: directory.appendingPathComponent("work"), withIntermediateDirectories: true)
        }

        // These parent credentials and overrides must never reach either login.
        let parent = [
            "HOME": fixture.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
            "CLAUDE_CONFIG_DIR": "/wrong-profile", "ANTHROPIC_API_KEY": "do-not-inherit",
            "ANTHROPIC_BASE_URL": "https://invalid.example", "CLAUDE_CODE_OAUTH_TOKEN": "do-not-inherit"
        ]
        let first = session(executable: executable, directory: firstDirectory, parent: parent)
        let second = session(executable: executable, directory: secondDirectory, parent: parent)
        var callbacks = 0
        for session in [first, second] {
            session.onExit = { code in
                precondition(code == 0, "Fake CLI failed its isolation checks with status \(String(describing: code))")
                callbacks += 1
            }
            session.start()
        }
        precondition(first.isRunning && second.isRunning)

        let host = NSView()
        host.addSubview(first.terminalView())
        first.terminalView().removeFromSuperview()
        precondition(first.isRunning, "Hiding the terminal interrupted login")

        second.send("login Grüezi 👋\r")
        waitForExit(second, label: "second login")
        precondition(first.isRunning, "Completing one account interrupted the other")
        precondition(!files.fileExists(atPath: firstDirectory.appendingPathComponent(".credentials.json").path))
        first.send("login Grüezi 👋\r")
        waitForExit(first, label: "first login")
        precondition(callbacks == 2, "Login completion was not delivered exactly once per profile")

        let firstLogin = try credentials(in: firstDirectory)
        let secondLogin = try credentials(in: secondDirectory)
        precondition(firstLogin.accessToken != secondLogin.accessToken, "Profiles overwrote one another's credentials")
        precondition(firstLogin.accessToken == firstProfile.id.uuidString.lowercased())
        precondition(secondLogin.accessToken == secondProfile.id.uuidString.lowercased())

        let exitSeven = ClaudeTerminalSession(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 7"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: fixture)
        exitSeven.start()
        waitForExit(exitSeven, label: "exit status")
        precondition(exitSeven.state == .exited(7), "Child exit status was not normalized")

        let missing = ClaudeTerminalSession(
            executable: fixture.appendingPathComponent("missing"), arguments: [],
            environment: [:], workingDirectory: fixture)
        missing.start()
        precondition(missing.state == .exited(nil), "Missing executable did not fail explicitly")

        let cancellationReady = fixture.appendingPathComponent("ready-for-cancellation")
        let cancelled = ClaudeTerminalSession(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap 'exit 130' INT; touch \"$1\"; read answer", "test", cancellationReady.path],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: fixture)
        cancelled.start()
        let readinessDeadline = Date().addingTimeInterval(5)
        while !files.fileExists(atPath: cancellationReady.path) && Date() < readinessDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(files.fileExists(atPath: cancellationReady.path), "Cancellation fixture did not start")
        cancelled.interrupt()
        waitForExit(cancelled, label: "cancellation")
        precondition(cancelled.state == .exited(130), "Control-C did not cancel the child")
        print("Claude terminal integration checks passed: independent profiles, isolated environment, argv, PTY, Unicode input, hidden-session lifetime, exits, and cancellation.")
    }

    @MainActor private static func session(
        executable: URL, directory: URL, parent: [String: String]
    ) -> ClaudeTerminalSession {
        ClaudeTerminalSession(
            executable: executable, arguments: ["auth", "login", "--claudeai"],
            environment: ClaudeCodeProcess.environment(parent: parent, profileDirectory: directory),
            workingDirectory: directory.appendingPathComponent("work"))
    }

    @MainActor private static func waitForExit(_ session: ClaudeTerminalSession, label: String) {
        let deadline = Date().addingTimeInterval(5)
        while session.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(!session.isRunning, "The \(label) child did not finish within five seconds")
    }

    private static func credentials(in directory: URL) throws -> ClaudeCodeCredentials {
        let data = try Data(contentsOf: directory.appendingPathComponent(".credentials.json"))
        guard let credentials = ClaudeCodeProfile.parseCredentials(data) else {
            preconditionFailure("Fake CLI did not persist a readable credential bundle")
        }
        return credentials
    }

    private static let fakeCLI = #"""
    #!/bin/sh
    set -eu
    test "$#" = 3 || exit 10
    test "$1" = auth || exit 11
    test "$2" = login || exit 12
    test "$3" = --claudeai || exit 13
    test -t 0 && test -t 1 && test -t 2 || exit 14
    test "$PWD" -ef "$CLAUDE_CONFIG_DIR/work" || exit 15
    test -z "${ANTHROPIC_API_KEY-}" || exit 16
    test -z "${ANTHROPIC_BASE_URL-}" || exit 17
    test -z "${CLAUDE_CODE_OAUTH_TOKEN-}" || exit 18
    printf '\033[32mFake login ready\033[0m\n'
    IFS= read -r answer
    test "$answer" = 'login Grüezi 👋' || exit 19
    umask 077
    printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":2000000000000}}' "${CLAUDE_CONFIG_DIR##*/}" > "$CLAUDE_CONFIG_DIR/.credentials.json"
    """#
}
