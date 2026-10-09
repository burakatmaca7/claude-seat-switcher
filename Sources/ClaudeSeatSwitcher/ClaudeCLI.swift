import Foundation

/// Finds the Claude Code CLI and drives `claude auth login` for an app-owned profile.
///
/// Usage percentages need an OAuth sign-in. Claude Desktop keeps its sign-in encrypted inside
/// its own profile, so the app signs each account into a separate Claude Code CLI profile
/// (`CLAUDE_CONFIG_DIR`), which stores the token in the user's Keychain.
enum ClaudeCLI {
    /// The CLI installed by the user, or the copy bundled inside Claude Desktop.
    static func executable() -> String? {
        let home = Paths.home.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Claude Desktop ships Claude Code at
        // ~/Library/Application Support/Claude/claude-code/<version>/<hash>/claude.app/Contents/MacOS/claude
        let root = Paths.home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let vdir = root.appendingPathComponent(version)
            for hash in (try? FileManager.default.contentsOfDirectory(atPath: vdir.path)) ?? [] {
                let exe = vdir.appendingPathComponent("\(hash)/claude.app/Contents/MacOS/claude").path
                if FileManager.default.isExecutableFile(atPath: exe) { return exe }
            }
        }
        return nil
    }

    struct Profile {
        var email: String
        var accountUUID: String
        var organizationUUID: String
        var organizationName: String
    }

    /// Reads who is signed in to a CLI profile (non-secret fields only).
    static func profile(configDir: String?) -> Profile? {
        let dir = configDir.map(Paths.expand) ?? Paths.home.appendingPathComponent(".claude").path
        // The CLI keeps account details in <dir>/.claude.json, or ~/.claude.json for the default login.
        let file = configDir == nil
            ? Paths.home.appendingPathComponent(".claude.json")
            : URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = j["oauthAccount"] as? [String: Any],
              let email = a["emailAddress"] as? String else { return nil }
        return Profile(email: email,
                       accountUUID: (a["accountUuid"] as? String) ?? "",
                       organizationUUID: (a["organizationUuid"] as? String) ?? "",
                       organizationName: (a["organizationName"] as? String) ?? "")
    }
}

/// One `claude auth login` run. The CLI prints a sign-in URL and waits for the code that the
/// browser shows after approval; the code is written to its stdin.
@MainActor
final class CLILogin: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waitingForCode(URL, error: String?)
        case finishing
        case done(email: String)
        case failed(String)
    }

    /// Hosts allowed for the sign-in page opened in the browser.
    static let allowedHosts: Set<String> = ["claude.ai", "claude.com", "platform.claude.com", "console.anthropic.com"]

    @Published var phase: Phase = .idle
    private var process: Process?
    private var input: Pipe?
    private var buffer = ""
    private var signInURL: URL?
    /// Bumped on every start/cancel: callbacks from an earlier attempt are ignored.
    private var generation = 0
    let configDir: URL

    init(configDir: URL) {
        self.configDir = configDir
    }

    deinit {
        process?.terminate()
    }

    /// Accepts only an https sign-in page on an Anthropic host.
    static func validSignInURL(_ s: String) -> URL? {
        guard let url = URL(string: s), url.scheme == "https", let host = url.host?.lowercased(),
              allowedHosts.contains(host), url.path.contains("/oauth/authorize") else { return nil }
        return url
    }

    func start() {
        _ = Shell.ignoreSIGPIPE
        guard let exe = ClaudeCLI.executable() else {
            phase = .failed("Claude Code was not found. Install it, or open Claude Desktop's Code tab once.")
            return
        }
        generation += 1
        let gen = generation
        buffer = ""
        signInURL = nil
        phase = .idle
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["auth", "login"]
        var env = ProcessInfo.processInfo.environment
        // Never let an API key or another token source stand in for the browser sign-in.
        env = env.filter { !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE_CODE_") }
        env["CLAUDE_CONFIG_DIR"] = configDir.path
        env["BROWSER"] = "/usr/bin/true"          // the app opens the URL itself, after validating it
        p.environment = env
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp

        // Output and exit are joined so the final output is always consumed before `finished`.
        let eof = DispatchGroup()
        eof.enter()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                eof.leave()
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.consume(text)
            }
        }
        eof.enter()
        p.terminationHandler = { _ in eof.leave() }
        eof.notify(queue: .main) { [weak self] in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.finished(status: status)
            }
        }
        do {
            try p.run()
            process = p
            input = inp
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), let input else { return }
        phase = .finishing
        do {
            try input.fileHandleForWriting.write(contentsOf: Data((trimmed + "\n").utf8))
        } catch {
            phase = .failed("Sign-in ended before the code was sent. Try again.")
        }
    }

    func cancel() {
        generation += 1
        process?.terminate()
        process = nil
        input = nil
    }

    private func consume(_ text: String) {
        buffer += text
        if buffer.count > 64_000 { buffer = String(buffer.suffix(16_000)) }
        // The URL counts only once it is followed by whitespace: output arrives in chunks.
        if signInURL == nil,
           let range = buffer.range(of: #"https://\S+(?=\s)"#, options: .regularExpression) {
            guard let url = Self.validSignInURL(String(buffer[range])) else {
                cancel()
                phase = .failed("Unexpected sign-in address from Claude Code — stopped for safety.")
                return
            }
            signInURL = url
            phase = .waitingForCode(url, error: nil)
            return
        }
        // A wrong code: the CLI reports an error and/or asks again.
        if case .finishing = phase, let url = signInURL {
            let tail = buffer.suffix(400).lowercased()
            if tail.contains("invalid") || tail.contains("error") || tail.hasSuffix("> ") {
                phase = .waitingForCode(url, error: "That code was not accepted. Copy it again from the page.")
            }
        }
    }

    private func finished(status: Int32) {
        process = nil
        input = nil
        if status == 0, let profile = ClaudeCLI.profile(configDir: configDir.path) {
            phase = .done(email: profile.email)
        } else if case .failed = phase {
            return
        } else {
            let last = buffer.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
            phase = .failed("Sign-in did not complete: \(last.prefix(160))")
        }
    }
}
