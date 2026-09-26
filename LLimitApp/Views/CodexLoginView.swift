import SwiftUI

struct CodexLoginView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    if let login = model.codexLogin {
      VStack(alignment: .leading, spacing: 18) {
        Text(login.title)
          .font(.title2.bold())

        Text("Choose the ChatGPT account you want to track in your browser. To add a different account, switch accounts there before completing sign-in. Your usual Codex login stays separate.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(alignment: .top, spacing: 10) {
          if login.isBusy {
            ProgressView()
              .controlSize(.small)
          }
          Text(login.message)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

        HStack {
          if login.authURL != nil && login.isBusy {
            Button("Open Browser Again") { model.reopenCodexLoginBrowser() }
          }
          Spacer()
          Button(login.isBusy ? "Cancel Sign-In" : "Close") {
            if login.isBusy {
              model.cancelCodexLogin()
            } else {
              model.dismissCodexLogin()
            }
          }
          .keyboardShortcut(.cancelAction)
        }
      }
      .padding(24)
      .frame(width: 520)
      .interactiveDismissDisabled(login.isBusy)
    }
  }
}
