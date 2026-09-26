import AppKit
import Combine
import SwiftTerm

/// Owns a Claude Code process independently of the sheet displaying its terminal.
/// Keep the session alive until the child exits so hiding a sheet cannot interrupt
/// an OAuth refresh between token rotation and credential persistence.
@MainActor
final class ClaudeTerminalSession: NSObject, ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case running
        case exited(Int32?)
    }

    let id = UUID()
    @Published private(set) var state: State = .idle

    var onExit: ((Int32?) -> Void)?

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL
    private let terminal: LocalProcessTerminalView

    init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 820, height: 440))
        super.init()
        terminal.processDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.94, alpha: 1)
        terminal.setAccessibilityLabel("Claude Code terminal")
    }

    var isRunning: Bool { state == .running }

    func start() {
        guard state == .idle else { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              (try? workingDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            didExit(nil)
            return
        }

        var terminalEnvironment = environment
        terminalEnvironment["TERM"] = "xterm-256color"
        state = .running
        // An argument array is passed directly to execve; no shell interprets
        // the executable path, profile directory, or environment values.
        terminal.startProcess(
            executable: executable.path,
            args: arguments,
            environment: terminalEnvironment.map { "\($0.key)=\($0.value)" }.sorted(),
            currentDirectory: workingDirectory.path
        )
        if !terminal.process.running { didExit(nil) }
    }

    func send(_ text: String) {
        guard isRunning else { return }
        terminal.process.send(data: Array(text.utf8)[...])
    }

    /// Explicit user cancellation, equivalent to pressing Control-C in the CLI.
    func interrupt() {
        send("\u{03}")
    }

    func terminalView() -> NSView { terminal }

    private func didExit(_ exitCode: Int32?) {
        if case .exited = state { return }
        state = .exited(exitCode)
        onExit?(exitCode)
    }
}

extension ClaudeTerminalSession: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    // Terminal titles and directories can contain private authentication data.
    // Keep all child output in SwiftTerm's transient terminal buffer.
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // SwiftTerm's macOS forkpty runner reports the raw waitpid status.
        let code = exitCode.map { status in
            status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        }
        // LocalProcessTerminalView delivers delegate callbacks on its default
        // DispatchQueue.main, although the dependency's protocol is unannotated.
        MainActor.assumeIsolated { didExit(code) }
    }
}
