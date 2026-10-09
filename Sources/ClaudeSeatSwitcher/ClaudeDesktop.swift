import AppKit
import Darwin
import Foundation

/// Opens and finds Claude Desktop windows, one independent profile per account.
///
/// Claude Desktop is an Electron app and honours `--user-data-dir`: launched against a
/// separate directory, it is a separate, independently signed-in copy of the app. The
/// sign-in stays inside that directory; this app never reads or copies it.
enum ClaudeDesktop {
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Paths.claudeExecutable.path)
    }

    /// Running Claude Desktop main processes: the default window and each profile directory.
    struct Running: Equatable {
        var mainPID: pid_t?
        var profilePIDs: [String: pid_t] = [:]   // account id → pid
    }

    /// Only processes that macOS reports as the real Claude app (by executable path) and that
    /// belong to the current user are considered. A process can fake its argv, but not this.
    static func running() -> Running {
        let exe = Paths.claudeExecutable.resolvingSymlinksInPath().path
        var lines: [String] = []
        for app in NSWorkspace.shared.runningApplications
        where app.executableURL?.resolvingSymlinksInPath().path == exe {
            let pid = app.processIdentifier
            guard ownedByCurrentUser(pid), let args = arguments(of: pid) else { continue }
            lines.append("\(pid) " + ([exe] + args).joined(separator: " "))
        }
        return parse(psOutput: lines.joined(separator: "\n"), executable: exe,
                     profilesRoot: Paths.desktopProfiles.path + "/")
    }

    /// Parses "pid command args…" lines. Separate from `running()` so it can be tested.
    static func parse(psOutput: String, executable exe: String, profilesRoot: String) -> Running {
        var result = Running()
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[..<space]) else { continue }
            let command = trimmed[trimmed.index(after: space)...]
            guard command.hasPrefix(exe) else { continue }
            let args = command.dropFirst(exe.count)
            guard args.isEmpty || args.hasPrefix(" ") else { continue }   // "…/Claude Helper" is not Claude
            if let range = args.range(of: "--user-data-dir=") {
                // The path may contain spaces ("Application Support"): it runs until the next
                // " --" argument or the end of the line.
                let rest = args[range.upperBound...]
                let dir = rest.range(of: " --").map { rest[..<$0.lowerBound] } ?? rest
                if dir.hasPrefix(profilesRoot) {
                    let id = dir.dropFirst(profilesRoot.count).split(separator: "/").first.map(String.init) ?? ""
                    if Account.isValidID(id) { result.profilePIDs[id] = pid }
                }
            } else {
                result.mainPID = result.mainPID ?? pid
            }
        }
        return result
    }

    /// Brings the account's window to the front, launching it if needed. Call off the main thread.
    static func open(_ account: Account, shareHistory: Bool) {
        let state = running()
        switch account.window {
        case .main:
            if let pid = state.mainPID, let app = NSRunningApplication(processIdentifier: pid) {
                DispatchQueue.main.async { app.activate() }
            } else {
                // -n: without it LaunchServices would just focus an already running PROFILE window.
                Shell.run("/usr/bin/open", ["-n", "-a", Paths.claudeApp.path])
            }
        case .profile:
            guard Account.isValidID(account.id) else { return }
            if let pid = state.profilePIDs[account.id], let app = NSRunningApplication(processIdentifier: pid) {
                DispatchQueue.main.async { app.activate() }
            } else {
                let dir = Paths.desktopProfile(for: account.id)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if shareHistory { SessionSharing.linkProfile(dir) }
                Shell.run("/usr/bin/open", ["-n", "-a", Paths.claudeApp.path, "--args", "--user-data-dir=\(dir.path)"])
            }
        }
    }

    static func isOpen(_ account: Account, in state: Running) -> Bool {
        switch account.window {
        case .main: return state.mainPID != nil
        case .profile: return state.profilePIDs[account.id] != nil
        }
    }

    // MARK: Process inspection

    private static func ownedByCurrentUser(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_uid == getuid()
    }

    /// argv[1...] of a process, via sysctl KERN_PROCARGS2.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buffer[i] != 0 { i += 1 }        // executable path
        while i < size && buffer[i] == 0 { i += 1 }        // padding
        var args: [String] = []
        var start = i
        while i < size && args.count < Int(argc) {
            if buffer[i] == 0 {
                args.append(String(decoding: buffer[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return Array(args.dropFirst())                     // argv[0] is the program name
    }
}
