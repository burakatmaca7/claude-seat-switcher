import Foundation

/// One Claude account (a personal login or a Team seat) managed by the app.
struct Account: Codable, Identifiable, Hashable {
    enum Window: String, Codable {
        /// The regular Claude Desktop window (the user's default profile).
        case main
        /// A separate Claude Desktop profile owned by this app.
        case profile
    }

    enum Role: String, Codable {
        /// Used interactively; suggested when another account nears its limit.
        case interactive
        /// Used by scripts / `claude -p` jobs; never suggested for interactive work.
        case automation
    }

    /// Short, unique, filesystem-safe name (e.g. "work", "dev2"). Used in folder names, so it is
    /// validated everywhere it enters the app (wizard AND the hand-editable accounts file).
    var id: String

    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9-]{0,19}$"#, options: .regularExpression) != nil
    }

    /// Turns what people type ("Ali Work", "Çalışma 2") into a valid short name ("ali-work", "calisma-2").
    static func suggestedID(from text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let folded = latin.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en"))
            .lowercased()
            .replacingOccurrences(of: "ı", with: "i")
        var out = ""
        for ch in folded {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) }
            else if !out.isEmpty && out.last != "-" { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(20)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    var email: String
    var label: String = ""
    var window: Window = .profile
    var role: Role = .interactive
    /// Claude Code CLI config directory holding this account's sign-in.
    /// `nil` means the user's default CLI login (`~/.claude`), which other tools may share.
    var cliConfigDir: String?

    /// True only for the CLI profile this app created for this account (`CLIProfiles/<id>`), the only
    /// sign-in it may refresh. Any other folder — the default login, or a path typed into the accounts
    /// file — may be used by other tools, and two programs refreshing one token can sign it out.
    var ownsCLIProfile: Bool {
        guard let dir = cliConfigDir else { return false }
        let url = URL(fileURLWithPath: Paths.expand(dir)).standardizedFileURL.resolvingSymlinksInPath()
        let root = Paths.cliProfiles.standardizedFileURL.resolvingSymlinksInPath()
        return url.deletingLastPathComponent().path == root.path && url.lastPathComponent == id
    }
}

/// One usage window (5-hour session, weekly, or a model-scoped weekly limit).
struct UsageWindow: Codable, Hashable {
    var label: String
    var percent: Double
    var resetsAt: Date?
}

struct Usage: Codable, Hashable {
    var session: UsageWindow?
    var weekly: UsageWindow?
    /// A weekly limit scoped to one model (e.g. "Fable"), shown when present.
    var scopedWeekly: UsageWindow?
    var fetchedAt: Date

    var windows: [UsageWindow] { [session, weekly, scopedWeekly].compactMap { $0 } }

    /// The tightest limit that is still in force: a window whose reset time has passed no longer
    /// counts (stale data must not keep an account looking full).
    func effectivePercent(now: Date = Date()) -> Double {
        windows.filter { ($0.resetsAt ?? .distantFuture) > now }.map(\.percent).max() ?? 0
    }
}

enum UsageState: Hashable {
    case unknown
    case loaded(Usage)
    /// `retryAfter`: the server asked us to wait (HTTP 429 Retry-After), in seconds.
    case failed(String, last: Usage?, retryAfter: TimeInterval? = nil)

    var usage: Usage? {
        switch self {
        case .loaded(let u): return u
        case .failed(_, let last, _): return last
        case .unknown: return nil
        }
    }

    var isRateLimited: Bool {
        if case .failed(let message, _, _) = self { return message.hasPrefix("rate limited") }
        return false
    }
}
