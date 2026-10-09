import SwiftUI

/// Three steps: describe the account → sign in to its Claude window → sign in for usage data.
struct AddAccountView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Step { case details, desktop, usage }
    enum UsageSource: String, CaseIterable, Identifiable {
        case newSignIn = "Sign in for usage now (recommended)"
        case defaultLogin = "Use my existing Claude Code login"
        case skip = "Skip — window only (no usage data)"
        var id: String { rawValue }
    }

    @State private var step: Step = .details
    @State private var id = ""
    @State private var email = ""
    @State private var label = ""
    @State private var window: Account.Window = .profile
    @State private var role: Account.Role = .interactive
    @State private var source: UsageSource = .newSignIn
    @State private var code = ""
    @State private var activeLogin: CLILogin?
    /// The profile folder opened in step 2, removed again if the wizard is abandoned.
    @State private var createdProfileID: String?
    @State private var saved = false

    private var idValid: Bool { Account.isValidID(id) && !model.accounts.contains { $0.id == id } }
    private var hasMainAccount: Bool { model.accounts.contains { $0.window == .main } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case .details: details
            case .desktop: desktop
            case .usage: usageStep
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(FloatingWindow())
        .onAppear {
            // The window keeps its state between openings; always start a fresh wizard.
            step = .details; id = ""; email = ""; label = ""; code = ""; role = .interactive
            source = .newSignIn; activeLogin = nil; createdProfileID = nil; saved = false
            window = hasMainAccount ? .profile : .main
            if !hasMainAccount { window = .main }
            if model.defaultLoginInUse { source = .newSignIn }
        }
        .onDisappear(perform: abandon)
    }

    // MARK: Step 1

    private var details: some View {
        Group {
            Text("Add an account").font(.title2.bold())
            Form {
                TextField("Short name", text: $id, prompt: Text("e.g. work, dev2"))
                    .onChange(of: id) { _, new in
                        let fixed = Account.suggestedID(from: new)
                        if fixed != new && !new.hasSuffix(" ") && !new.hasSuffix("-") { id = fixed }
                    }
                TextField("Email", text: $email, prompt: Text("the account's email"))
                TextField("Label (optional)", text: $label)
                Picker("Window", selection: $window) {
                    Text("My regular Claude window").tag(Account.Window.main).disabled(hasMainAccount)
                    Text("A separate window just for this account").tag(Account.Window.profile)
                }
                Picker("Used for", selection: $role) {
                    Text("Interactive work").tag(Account.Role.interactive)
                    Text("Automation (scripts, claude -p)").tag(Account.Role.automation)
                }
                Picker("Usage data", selection: $source) {
                    Text(UsageSource.newSignIn.rawValue).tag(UsageSource.newSignIn)
                    Text(UsageSource.defaultLogin.rawValue).tag(UsageSource.defaultLogin)
                        .disabled(model.defaultLoginInUse)
                    Text(UsageSource.skip.rawValue).tag(UsageSource.skip)
                }
            }
            if model.defaultLoginInUse {
                Text("Your existing Claude Code login is already used by another account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !id.isEmpty && !idValid {
                Text("Use lowercase letters, digits and '-' (max 20), and a name not already used.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Continue") {
                    if window == .profile {
                        createdProfileID = id
                        model.open(Account(id: id, email: email, window: .profile))
                        step = .desktop
                    } else {
                        startUsageStep()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!idValid)
            }
        }
    }

    // MARK: Step 2

    private var desktop: some View {
        Group {
            Text("Sign in to the new Claude window").font(.title2.bold())
            Text("A new Claude window opened. Sign in there as **\(email.isEmpty ? id : email)**.")
            Label("If the email link opens a different Claude window, use the code from the email or continue with Google instead.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("I've signed in") { startUsageStep() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Step 3

    private func startUsageStep() {
        if source == .skip {
            finish(cliConfigDir: nil, windowOnly: true)
            return
        }
        if source == .defaultLogin && !model.defaultLoginInUse {
            finish(cliConfigDir: nil)
            return
        }
        let l = CLILogin(configDir: Paths.cliProfile(for: id))
        activeLogin = l
        l.start()
        step = .usage
    }

    private var usageStep: some View {
        Group {
            Text("Sign in for usage data").font(.title2.bold())
            if let l = activeLogin {
                LoginStatus(login: l, email: email, code: $code,
                            onRetry: { l.cancel(); l.start() },
                            onDone: { finish(cliConfigDir: l.configDir.path) })
            } else {
                // Never an empty step: the sign-in was stopped (window closed and reopened).
                Button("Restart sign-in") { startUsageStep() }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
            }
        }
    }

    private func finish(cliConfigDir: String?, windowOnly: Bool = false) {
        let stored = cliConfigDir.map { $0.replacingOccurrences(of: Paths.home.path, with: "~") }
        model.add(Account(id: id, email: email, label: label, window: window, role: role, cliConfigDir: stored,
                          windowOnly: windowOnly ? true : nil))
        saved = true
        dismiss()
    }

    /// Leaving without saving: stop the sign-in and remove what this wizard created.
    private func abandon() {
        activeLogin?.cancel()
        activeLogin = nil
        guard !saved, Account.isValidID(id), !model.accounts.contains(where: { $0.id == id }) else { return }
        // A finished sign-in left a valid token in the Keychain: remove it with the folder.
        Credentials.deleteAppOwnedSignIn(cliConfigDir: Paths.cliProfile(for: id).path)
        Paths.trashChild(Paths.cliProfile(for: id), of: Paths.cliProfiles)
        if let created = createdProfileID, Account.isValidID(created),
           !model.isOpen(Account(id: created, email: "", window: .profile)) {
            Paths.trashChild(Paths.desktopProfile(for: created), of: Paths.desktopProfiles)
        }
    }
}

private struct LoginStatus: View {
    @ObservedObject var login: CLILogin
    let email: String
    @Binding var code: String
    let onRetry: () -> Void
    let onDone: () -> Void
    @State private var acceptMismatch = false
    @State private var emailCodeWarning = false
    /// The code field opens only after the sign-in page was opened: the code must come from there.
    @State private var pageOpened = false

    var body: some View {
        switch login.phase {
        case .idle:
            ProgressView("Starting sign-in…")
        case .waitingForCode(let url, let error):
            browserFlow(url: url, error: error)
        case .finishing:
            ProgressView("Finishing…")
        case .done(let signedIn):
            DoneView(signedIn: signedIn, email: email, acceptMismatch: $acceptMismatch,
                     onRetry: onRetry, onDone: onDone)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                if !login.diagnostics.isEmpty {
                    ScrollView {
                        Text(login.diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
                HStack {
                    Button("Try again", action: onRetry)
                    Button("Copy details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(message)\n\n\(login.diagnostics)", forType: .string)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func browserFlow(url: URL, error: String?) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Open the sign-in page. Make sure your browser is signed in to claude.ai as **\(email.isEmpty ? "this account" : email)**.")
                Text("The account signed in to claude.ai in your browser is the one that approves. A private window has nobody signed in, so you approve as the account you are adding.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let browser = PrivateBrowser.installed() {
                        Button("Open in a private \(browser.name) window") {
                            if !browser.open(url) { NSWorkspace.shared.open(url) }
                            pageOpened = true
                        }
                    }
                    Button("Open sign-in page") { NSWorkspace.shared.open(url); pageOpened = true }
                    Button("Copy sign-in link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        pageOpened = true
                    }
                }
                Text("2. Approve on that page, then paste its authorization code:")
                Label {
                    Text(LocalizedStringKey("Use the **authorization code** shown after you press **Open sign-in page** above and approve. "
                         + "It is long and contains a #. It is **not** the 6-digit code from the sign-in email "
                         + "— that one was for the Claude window."))
                } icon: {
                    Image(systemName: "key.horizontal.fill")
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5)))
                HStack {
                    SecureField(pageOpened ? "Authorization code from the sign-in page" : "Open the sign-in page first",
                                text: $code)
                        .disabled(!pageOpened)
                    Button("Submit") {
                        if CLILogin.looksLikeEmailCode(code) {
                            emailCodeWarning = true          // never sent: a wrong code would use up this sign-in
                        } else {
                            emailCodeWarning = false
                            login.submit(code: code)
                        }
                        code = ""
                    }
                        .disabled(code.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                if emailCodeWarning {
                    Text("That looks like the 6-digit code from the email — that one is for the Claude window. Paste the long code from the sign-in page instead.")
                        .font(.caption).foregroundStyle(.orange)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                    if !login.diagnostics.isEmpty {
                        Text(login.diagnostics).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(4)
                    }
                }
            }
    }
}

private struct DoneView: View {
    let signedIn: String
    let email: String
    @Binding var acceptMismatch: Bool
    let onRetry: () -> Void
    let onDone: () -> Void

    private var mismatch: Bool { !email.isEmpty && signedIn.lowercased() != email.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mismatch {
                Label("Signed in as \(signedIn), not \(email). Usage would show the wrong account.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                HStack {
                    Button("Sign in again", action: onRetry)
                    Toggle("Save anyway", isOn: $acceptMismatch)
                }
            } else {
                Label("Signed in as \(signedIn)", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            Button("Save account", action: onDone)
                .keyboardShortcut(.defaultAction)
                .disabled(mismatch && !acceptMismatch)
        }
    }
}

/// Keeps the wizard above other windows. The app has no Dock icon, so when step 2 brings a new Claude window to
/// the front the wizard would otherwise sit behind it with no way to Cmd-Tab back.
private struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.level = .floating }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.level = .floating }
    }
}
