import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// ~/Library/Application Support/ClaudeSeatSwitcher
    static let support = home
        .appendingPathComponent("Library/Application Support/ClaudeSeatSwitcher", isDirectory: true)

    static let accountsFile = support.appendingPathComponent("accounts.json")
    static let stateFile = support.appendingPathComponent("state.json")

    /// Claude Desktop user-data directories, one per `.profile` account.
    static let desktopProfiles = support.appendingPathComponent("DesktopProfiles", isDirectory: true)

    /// Claude Code CLI config directories, one per account added through the app.
    static let cliProfiles = support.appendingPathComponent("CLIProfiles", isDirectory: true)

    /// Executable scripts whose first output line becomes a menu line.
    static let statusLines = support.appendingPathComponent("StatusLines", isDirectory: true)

    static let claudeApp = URL(fileURLWithPath: "/Applications/Claude.app")
    static let claudeExecutable = claudeApp.appendingPathComponent("Contents/MacOS/Claude")

    static func desktopProfile(for id: String) -> URL {
        desktopProfiles.appendingPathComponent(id, isDirectory: true)
    }

    static func cliProfile(for id: String) -> URL {
        cliProfiles.appendingPathComponent(id, isDirectory: true)
    }

    static func ensureDirectories() {
        for dir in [support, desktopProfiles, cliProfiles, statusLines] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Moves `url` to the Trash only if, after resolving symlinks and "..", it is a DIRECT child of
    /// `parent`. Guards every removal against crafted or mistyped paths in the accounts file.
    @discardableResult
    static func trashChild(_ url: URL, of parent: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = parent.standardizedFileURL.resolvingSymlinksInPath()
        guard target.deletingLastPathComponent().path == root.path,
              !target.lastPathComponent.isEmpty, target.lastPathComponent != "..",
              FileManager.default.fileExists(atPath: target.path) else { return false }
        return (try? FileManager.default.trashItem(at: target, resultingItemURL: nil)) != nil
    }

    /// Expands a leading "~" in a stored path.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
