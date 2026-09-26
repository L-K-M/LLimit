import AppKit
import SwiftUI

/// The session outlives this view. Dismantling a sheet must not close its PTY.
struct ClaudeTerminalView: NSViewRepresentable {
    let session: ClaudeTerminalSession

    func makeNSView(context: Context) -> NSView {
        let terminal = session.terminalView()
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ClaudeTerminalSheet: View {
    @ObservedObject var session: ClaudeTerminalSession
    let title: String
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ClaudeTerminalView(session: session)
                .frame(minWidth: 780, minHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.isRunning {
                    Button("Send Control-C") { session.interrupt() }
                        .help("Ask Claude Code to cancel the current operation.")
                }
                Button(session.isRunning ? "Hide Terminal" : "Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 550)
        .onAppear { session.start() }
    }

    private var status: String {
        switch session.state {
        case .idle: return "Starting Claude Code…"
        case .running: return "Claude Code is running. You can hide and reopen this terminal."
        case .exited(0): return "Claude Code finished."
        case .exited: return "Claude Code stopped. Review the terminal for details."
        }
    }
}
