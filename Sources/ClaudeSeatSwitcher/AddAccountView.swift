import SwiftUI

/// Three steps: describe the account → sign in to its Claude window → sign in for usage data.
struct AddAccountView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Step { case details, desktop, usage }
    enum UsageSource: String, CaseIterable, Identifiable {
        case newSignIn = "Sign in for usage now (recommended)"
        case defaultLogin = "Use my existing Claude Code login"
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
        .frame(width: 480)
        .onAppear {
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
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
            }
        }
    }

    private func finish(cliConfigDir: String?) {
        let stored = cliConfigDir.map { $0.replacingOccurrences(of: Paths.home.path, with: "~") }
        model.add(Account(id: id, email: email, label: label, window: window, role: role, cliConfigDir: stored))
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

    var body: some View {
        switch login.phase {
        case .idle:
            ProgressView("Starting sign-in…")
        case .waitingForCode(let url, let error):
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Open the sign-in page. Make sure your browser is signed in to claude.ai as **\(email.isEmpty ? "this account" : email)**.")
                Button("Open sign-in page") { NSWorkspace.shared.open(url) }
                Text("2. Approve, then paste the code the page shows:")
                HStack {
                    SecureField("Code", text: $code)
                    Button("Submit") { login.submit(code: code); code = "" }
                        .disabled(code.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        case .finishing:
            ProgressView("Finishing…")
        case .done(let signedIn):
            DoneView(signedIn: signedIn, email: email, acceptMismatch: $acceptMismatch,
                     onRetry: onRetry, onDone: onDone)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                Button("Try again", action: onRetry)
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
