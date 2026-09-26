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
        try verifyRetainedProfiles(under: fixture)
        print("Claude integration checks passed: independent profiles, isolated environment, argv, PTY, Unicode input, hidden-session lifetime, exits, cancellation, and private retention records.")
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

    private static func verifyRetainedProfiles(under fixture: URL) throws {
        let files = FileManager.default
        let root = fixture.appendingPathComponent("retention fixtures", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let service = ClaudeProfileService(root: root)
        let profiles = [ClaudeCodeProfile(), ClaudeCodeProfile()]
        var originals: [URL: Data] = [:]
        for (index, profile) in profiles.enumerated() {
            let directory = profile.directory(under: root)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let credentialFile = directory.appendingPathComponent(".credentials.json")
            let sentinel = Data("{\"accessToken\":\"fixture-access-\(index)\",\"refreshToken\":\"fixture-refresh-\(index)\"}".utf8)
            try sentinel.write(to: credentialFile)
            originals[credentialFile] = sentinel
            try service.retain(profile)
        }

        let records = root.appendingPathComponent("RetainedProfiles", isDirectory: true)
        let directoryPermissions = try files.attributesOfItem(atPath: records.path)[.posixPermissions] as? NSNumber
        precondition(directoryPermissions?.intValue == 0o700, "Retention records directory is not private")
        var recordedIDs: Set<String> = []
        for profile in profiles {
            let marker = records.appendingPathComponent(profile.id.uuidString.lowercased() + ".json")
            let data = try Data(contentsOf: marker)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            precondition(Set(object?.keys.map { $0 } ?? []) == ["version", "profile_id", "recorded_at"],
                         "Retention record contains unexpected fields")
            precondition(object?["version"] as? Int == 1)
            precondition(object?["profile_id"] as? String == profile.id.uuidString.lowercased())
            precondition(ISO8601DateFormatter().date(from: object?["recorded_at"] as? String ?? "") != nil)
            recordedIDs.insert(object?["profile_id"] as? String ?? "")
            let markerPermissions = try files.attributesOfItem(atPath: marker.path)[.posixPermissions] as? NSNumber
            precondition(markerPermissions?.intValue == 0o600, "Retention record is not private")
            let text = String(decoding: data, as: UTF8.self)
            precondition(!text.contains("fixture-access-") && !text.contains("fixture-refresh-"),
                         "Retention record contains credential values")
            precondition(!files.fileExists(atPath: profile.directory(under: root).appendingPathComponent(".llimit-retained.json").path),
                         "Retention marker was written inside a potentially active profile")
        }
        precondition(recordedIDs.count == 2, "Retaining one profile overwrote another profile's marker")
        try service.retain(profiles[0])
        let recordNames = try files.contentsOfDirectory(atPath: records.path)
        precondition(recordNames.count == 2,
                     "Retaining a profile twice created a duplicate marker")
        for (url, original) in originals {
            let current = try Data(contentsOf: url)
            precondition(current == original, "Retention changed a profile's credential file")
        }

        let unsafeProfile = ClaudeCodeProfile()
        let target = fixture.appendingPathComponent("retention-symlink-target.json")
        let sentinel = Data("do not change this file".utf8)
        try sentinel.write(to: target)
        try files.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let unsafeMarker = records.appendingPathComponent(unsafeProfile.id.uuidString.lowercased() + ".json")
        try files.createSymbolicLink(at: unsafeMarker, withDestinationURL: target)
        var rejected = false
        do {
            try service.retain(unsafeProfile)
        } catch ClaudeProfileService.Failure.unsafeDirectory {
            rejected = true
        }
        precondition(rejected, "Retention accepted a symbolic-link marker")
        let targetContents = try Data(contentsOf: target)
        precondition(targetContents == sentinel, "Retention overwrote a symbolic-link target")
        let targetPermissions = try files.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        precondition(targetPermissions?.intValue == 0o640, "Retention changed symbolic-link target permissions")
        let markerType = try files.attributesOfItem(atPath: unsafeMarker.path)[.type] as? FileAttributeType
        precondition(markerType == .typeSymbolicLink, "Retention replaced a symbolic-link marker")
        precondition(!files.fileExists(atPath: unsafeProfile.directory(under: root).path),
                     "Retention unexpectedly created a profile directory")
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
