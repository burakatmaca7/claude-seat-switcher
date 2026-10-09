import CryptoKit
import Foundation

/// Makes Claude Desktop's Code-tab conversations visible from every account.
///
/// Claude Desktop lists Code-tab sessions from `<profile>/claude-code-sessions/<account>/<org>/local_*.json`.
/// The transcripts themselves live in `~/.claude/projects` and are already shared. Two steps:
///
/// 1. Every app-owned profile's `claude-code-sessions` is a symlink to the default profile's folder,
///    so all windows read and write one place.
/// 2. `sync()` copies session files that one account has and another lacks, between accounts of the
///    SAME organization only. It never overwrites an existing file. Each copy is journaled with its
///    hash: `undo()` removes a copy only if it is still unchanged, and a copy the user deleted is
///    never copied again.
enum SessionSharing {
    static let sharedRoot = Paths.home
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    static let journal = Paths.support.appendingPathComponent("session-sync-journal.json")

    /// All sync/undo work is serialized: the journal is read-modify-write.
    private static let lock = NSLock()

    struct Member: Hashable {
        var accountUUID: String
        var organizationUUID: String
    }

    struct JournalEntry: Codable, Hashable {
        var path: String
        var sha256: String
    }

    // MARK: Profile link

    /// Points a profile's `claude-code-sessions` at the shared folder. Safe to call repeatedly.
    /// The profile's window must not be running. Content that cannot be merged is kept in a
    /// `claude-code-sessions.bak-<date>` folder, never deleted.
    static func linkProfile(_ profileDir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        let link = profileDir.appendingPathComponent("claude-code-sessions")
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if dest == sharedRoot.path { return }
            try? fm.removeItem(at: link)                      // a stale symlink only
        } else if fm.fileExists(atPath: link.path) {
            mergeMove(from: link, into: sharedRoot)
            if ((try? fm.contentsOfDirectory(atPath: link.path)) ?? []).isEmpty {
                try? fm.removeItem(at: link)
            } else {
                let stamp = Int(Date().timeIntervalSince1970)
                try? fm.moveItem(at: link, to: profileDir.appendingPathComponent("claude-code-sessions.bak-\(stamp)"))
            }
        }
        try? fm.createSymbolicLink(at: link, withDestinationURL: sharedRoot)
    }

    /// Moves what does not exist in `dst`; leaves conflicts in `src`; removes emptied folders.
    private static func mergeMove(from src: URL, into dst: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
            let from = src.appendingPathComponent(name), to = dst.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            } else if fm.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue {
                mergeMove(from: from, into: to)
                if ((try? fm.contentsOfDirectory(atPath: from.path)) ?? []).isEmpty { try? fm.removeItem(at: from) }
            }
        }
    }

    // MARK: Sync

    /// Copies missing `local_*.json` session files between accounts of the same organization.
    /// Returns the number of files copied.
    @discardableResult
    static func sync(members: [Member], root: URL = sharedRoot, journal: URL = journal) -> Int {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        var entries = loadJournal(journal)
        let alreadyCopied = Set(entries.map(\.path))
        let byOrg = Dictionary(grouping: members.filter { safeComponent($0.accountUUID) && safeComponent($0.organizationUUID) },
                               by: \.organizationUUID)
        var copied = 0
        for (org, accounts) in byOrg where Set(accounts.map(\.accountUUID)).count > 1 {
            let dirs = Set(accounts.map(\.accountUUID)).map { root.appendingPathComponent("\($0)/\(org)", isDirectory: true) }
            var union: [String: URL] = [:]                       // file name → first source
            for dir in dirs {
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                where isSessionFile(name) && union[name] == nil && isRegularFile(dir.appendingPathComponent(name)) {
                    union[name] = dir.appendingPathComponent(name)
                }
            }
            for dir in dirs {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for (name, source) in union {
                    let dest = dir.appendingPathComponent(name)
                    // Never overwrite; never re-create a copy the user has since deleted.
                    guard !fm.fileExists(atPath: dest.path), !alreadyCopied.contains(dest.path) else { continue }
                    if (try? fm.copyItem(at: source, to: dest)) != nil, let hash = sha256(dest) {
                        entries.append(JournalEntry(path: dest.path, sha256: hash))
                        copied += 1
                    }
                }
            }
        }
        if copied > 0 { saveJournal(entries, to: journal) }
        return copied
    }

    // MARK: Undo

    /// Moves to the Trash every copy that `sync()` made and that is still unchanged. A copy the user
    /// has continued in another account (content changed) is kept. Only regular `local_*.json` files
    /// inside the shared folder are ever touched, whatever the journal says.
    @discardableResult
    static func undo(root: URL = sharedRoot, journal: URL = journal, useTrash: Bool = true) -> Int {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var removed = 0
        for entry in loadJournal(journal) {
            let url = URL(fileURLWithPath: entry.path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(rootPath),
                  isSessionFile(url.lastPathComponent),
                  isRegularFile(url),
                  sha256(url) == entry.sha256 else { continue }
            if (useTrash && (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil)
                || (try? fm.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        try? fm.removeItem(at: journal)
        return removed
    }

    // MARK: Helpers

    private static func isSessionFile(_ name: String) -> Bool {
        name.hasPrefix("local_") && name.hasSuffix(".json") && !name.contains("/")
    }

    /// Account and organization ids become folder names: only UUID-like values are accepted.
    private static func safeComponent(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    private static func sha256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadJournal(_ url: URL) -> [JournalEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([JournalEntry].self, from: data)) ?? []
    }

    private static func saveJournal(_ entries: [JournalEntry], to url: URL) {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}
