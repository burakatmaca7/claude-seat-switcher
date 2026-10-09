import Darwin
import Foundation

/// A custom line in the menu, produced by a user script.
struct StatusLine: Identifiable, Hashable {
    enum Level: String { case normal, warning, error }
    var id: String
    var text: String
    var level: Level
}

/// Runs every executable file in `~/Library/Application Support/ClaudeSeatSwitcher/StatusLines/`.
///
/// Script contract: print one line. An optional prefix sets the colour:
///   `ok: text`, `warn: text` or `error: text`. Anything else is shown as-is.
/// Scripts run with a 5-second timeout, in name order. They are the user's own files; the app
/// ships none and never downloads any. The feature is off until the user turns it on.
///
/// A script (or the symlink target) runs only if it is a regular file owned by the current user and
/// not writable by group or others, inside a folder with the same properties — so no other account
/// on the Mac can plant code that this app would run.
enum StatusLines {
    static func run() async -> [StatusLine] {
        await Task.detached(priority: .utility) { () -> [StatusLine] in
            let fm = FileManager.default
            let dir = Paths.statusLines
            guard isTrusted(dir.path, directory: true) else {
                return [StatusLine(id: "_", text: "Status-line folder is writable by others — scripts not run", level: .error)]
            }
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            return names.compactMap { name -> StatusLine? in
                let link = dir.appendingPathComponent(name)
                let path = link.resolvingSymlinksInPath().path
                guard !name.hasPrefix(".") else { return nil }
                guard isTrusted(path, directory: false), fm.isExecutableFile(atPath: path) else {
                    return StatusLine(id: name, text: "\(name): skipped (not owned by you, or writable by others)", level: .warning)
                }
                let r = Shell.run(path, [], environment: safeEnvironment, timeout: 5)
                let first = r.stdout.split(separator: "\n").first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard !first.isEmpty else {
                    return StatusLine(id: name, text: "\(name): no output", level: .warning)
                }
                for (prefix, level) in [("ok:", StatusLine.Level.normal), ("warn:", .warning), ("error:", .error)]
                where first.lowercased().hasPrefix(prefix) {
                    return StatusLine(id: name, text: first.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces),
                                      level: level)
                }
                return StatusLine(id: name, text: first, level: .normal)
            }
        }.value
    }
}

extension StatusLines {
    /// Owned by the current user, not group/other-writable, and of the expected type.
    static func isTrusted(_ path: String, directory: Bool) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o022 == 0 else { return false }
        let type = st.st_mode & S_IFMT
        return directory ? type == S_IFDIR : type == S_IFREG
    }

    /// Scripts get a minimal environment: nothing from this app leaks into them.
    static var safeEnvironment: [String: String] {
        let env = ProcessInfo.processInfo.environment
        var out = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"] { out[key] = env[key] }
        return out
    }
}
