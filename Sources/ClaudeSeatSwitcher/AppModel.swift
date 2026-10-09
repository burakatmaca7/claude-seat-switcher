import AppKit
import Foundation
import UserNotifications

/// App state: accounts, their usage, open windows, alerts and custom status lines.
@MainActor
final class AppModel: ObservableObject {
    static let warnPercent = 90.0
    /// An alert re-arms only after usage drops below this (no repeats when hovering around 90%).
    static let rearmPercent = 85.0
    static let busyPercent = 70.0
    /// Polling is deliberately gentle: the usage endpoint answers 429 to bursts.
    /// Every account at most once per `normalInterval`; one near its limit every `tick`.
    static let normalInterval: TimeInterval = 5 * 60
    static let tick: TimeInterval = 2 * 60
    /// Even a manual refresh asks for the same account at most this often.
    static let minInterval: TimeInterval = 60

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var usage: [String: UsageState] = [:]
    @Published private(set) var running = ClaudeDesktop.Running()
    @Published private(set) var statusLines: [StatusLine] = []
    @Published private(set) var update: Network.Release?
    @Published private(set) var notificationsOff = false
    @Published var checkForUpdates: Bool {
        didSet { UserDefaults.standard.set(checkForUpdates, forKey: "checkForUpdates") }
    }
    @Published var shareHistory: Bool {
        didSet { UserDefaults.standard.set(shareHistory, forKey: "shareHistory") }
    }
    @Published var openAtLogin = false {
        didSet { if !Self.isDemo, openAtLogin != LoginItem.isEnabled { LoginItem.set(openAtLogin) } }
    }
    /// Off by default: running scripts from a folder is opt-in.
    @Published var runStatusLines: Bool {
        didSet { UserDefaults.standard.set(runStatusLines, forKey: "runStatusLines") }
    }

    private var lastUpdateCheck: Date = .distantPast
    private var lastFetch: [String: Date] = [:]
    /// After HTTP 429 an account is left alone until this time (Retry-After, else 10 min doubling to 1 h).
    private var cooldownUntil: [String: Date] = [:]
    private var cooldownLength: [String: TimeInterval] = [:]
    /// Alerts already sent, persisted so a restart does not repeat them.
    private var alerted: Set<String> {
        didSet { UserDefaults.standard.set(Array(alerted), forKey: "alerted") }
    }
    private var isRefreshing = false
    private var pendingRefresh: Bool?          // nil = none queued; value = force flag
    private var timer: Timer?
    private let notifications = NotificationPresenter()

    /// `--demo`: sample accounts and usage for screenshots. No Keychain, no network, and every
    /// action that would touch files or windows is disabled.
    static let isDemo = CommandLine.arguments.contains("--demo")

    init() {
        let d = UserDefaults.standard
        if Self.isDemo {
            shareHistory = true
            checkForUpdates = false
            runStatusLines = true
            alerted = []
            loadDemo()
            return
        }
        shareHistory = d.object(forKey: "shareHistory") as? Bool ?? true
        checkForUpdates = d.object(forKey: "checkForUpdates") as? Bool ?? true
        LoginItem.enableOnFirstLaunch()
        openAtLogin = LoginItem.isEnabled
        runStatusLines = d.object(forKey: "runStatusLines") as? Bool ?? false
        alerted = Set(d.stringArray(forKey: "alerted") ?? [])
        Paths.ensureDirectories()
        accounts = AccountStore.load()
        notifications.install { [weak self] off in
            Task { @MainActor in self?.notificationsOff = off }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh(force: true) }
    }

    // MARK: Accounts

    func add(_ account: Account) {
        guard !Self.isDemo, Account.isValidID(account.id) else { return }
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        AccountStore.save(accounts)
        Task { await refresh(force: true) }
    }

    func update(_ account: Account) {
        guard !Self.isDemo, let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account
        AccountStore.save(accounts)
    }

    /// Forgets an account. Its window must be closed first. The app-owned Claude Desktop profile and
    /// CLI profile folders go to the Trash, and the app-owned Keychain sign-in is deleted (a valid
    /// refresh token must not be left behind). The default Claude Code login is never touched.
    /// Returns an error message, or nil on success.
    func remove(_ account: Account) -> String? {
        guard !Self.isDemo else { return nil }
        if isOpen(account) { return "Close \(account.id)'s Claude window first." }
        accounts.removeAll { $0.id == account.id }
        AccountStore.save(accounts)
        usage[account.id] = nil
        guard Account.isValidID(account.id) else { return nil }
        if account.window == .profile {
            Paths.trashChild(Paths.desktopProfile(for: account.id), of: Paths.desktopProfiles)
        }
        if let dir = account.cliConfigDir, account.ownsCLIProfile {
            // Only the CLI profile this app created for this account is ever removed.
            Credentials.deleteAppOwnedSignIn(cliConfigDir: dir)
            Paths.trashChild(URL(fileURLWithPath: Paths.expand(dir)), of: Paths.cliProfiles)
        }
        return nil
    }

    func open(_ account: Account) {
        guard !Self.isDemo else { return }
        let share = shareHistory
        Task {
            await offload { ClaudeDesktop.open(account, shareHistory: share) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            running = await offload { ClaudeDesktop.running() }
        }
    }

    /// True if any account already uses the default Claude Code login (only one may).
    var defaultLoginInUse: Bool { accounts.contains { $0.cliConfigDir == nil } }

    // MARK: Derived

    func isOpen(_ account: Account) -> Bool { ClaudeDesktop.isOpen(account, in: running) }

    func sessionPercent(_ id: String) -> Double? { usage[id]?.usage?.session?.percent }

    /// The tightest active limit (5-hour, weekly or model weekly) for an account.
    func effectivePercent(_ id: String) -> Double? { usage[id]?.usage?.effectivePercent() }

    /// The interactive account with the most room, counting every limit (a seat with an exhausted
    /// weekly limit has no room, however empty its 5-hour window).
    var suggested: Account? {
        let candidates = accounts.filter { $0.role == .interactive && effectivePercent($0.id) != nil }
        let roomy = candidates.filter { (effectivePercent($0.id) ?? 100) < Self.warnPercent }
        return (roomy.isEmpty ? candidates : roomy).min { (effectivePercent($0.id) ?? 0) < (effectivePercent($1.id) ?? 0) }
    }

    /// Short unique labels for the menu bar: first letter, or more when two accounts share it.
    private var shortNames: [String: String] {
        var result: [String: String] = [:]
        for a in accounts {
            var n = 1
            while n < a.id.count, accounts.contains(where: { $0.id != a.id && $0.id.hasPrefix(String(a.id.prefix(n))) }) {
                n += 1
            }
            result[a.id] = String(a.id.prefix(n)).uppercased()
        }
        return result
    }

    var menuBarTitle: String {
        let known = accounts.filter { sessionPercent($0.id) != nil }
        guard !known.isEmpty else { return "" }
        func pct(_ id: String) -> String { "\(Int((sessionPercent(id) ?? 0).rounded()))%" }
        if accounts.count <= 3 {
            let names = shortNames
            return accounts.map { "\(names[$0.id] ?? $0.id) \(sessionPercent($0.id) == nil ? "?" : pct($0.id))" }
                .joined(separator: " · ")
        }
        let open = known.filter(isOpen)
        var parts = open.map { "\($0.id) \(pct($0.id))" }
        if let s = suggested, !open.contains(s) { parts.append("free: \(s.id) \(pct(s.id))") }
        return parts.joined(separator: " · ")
    }

    var highestPercent: Double {
        accounts.compactMap { effectivePercent($0.id) }.max() ?? 0
    }

    // MARK: Refresh

    /// One refresh at a time; a call made meanwhile runs once more right after.
    func refresh(force: Bool = false) async {
        if Self.isDemo { return }
        if isRefreshing {
            pendingRefresh = (pendingRefresh ?? false) || force
            return
        }
        isRefreshing = true
        var nextForce: Bool? = force
        while let f = nextForce {
            pendingRefresh = nil
            await refreshOnce(force: f)
            nextForce = pendingRefresh
        }
        isRefreshing = false
    }

    private func refreshOnce(force: Bool) async {
        running = await offload { ClaudeDesktop.running() }
        let now = Date()
        await withTaskGroup(of: (String, UsageState).self) { group in
            for account in accounts {
                let hot = (effectivePercent(account.id) ?? 0) >= Self.busyPercent
                let since = now.timeIntervalSince(lastFetch[account.id] ?? .distantPast)
                let due = since >= (hot ? Self.tick - 5 : Self.normalInterval - 5)
                guard force || due, since >= Self.minInterval,
                      now >= (cooldownUntil[account.id] ?? .distantPast) else { continue }
                lastFetch[account.id] = now
                let previous = usage[account.id]?.usage
                group.addTask { (account.id, await UsageService.fetch(account, previous: previous)) }
            }
            for await (id, state) in group {
                usage[id] = state
                if state.isRateLimited {
                    var length = min((cooldownLength[id] ?? 300) * 2, 3600)
                    if case .failed(_, _, let retry?) = state, retry.isFinite { length = min(max(retry, 60), 3600) }
                    cooldownLength[id] = length
                    cooldownUntil[id] = Date().addingTimeInterval(length)
                } else if case .loaded = state {
                    cooldownLength[id] = nil
                    cooldownUntil[id] = nil
                }
            }
        }
        alertIfNeeded()
        statusLines = runStatusLines ? await StatusLines.run() : []
        if shareHistory { await syncHistory() }
        if checkForUpdates, Date().timeIntervalSince(lastUpdateCheck) > 24 * 3600 {
            lastUpdateCheck = Date()
            if let r = await Network.latestRelease(), AppInfo.isNewer(r.version, than: AppInfo.version) {
                update = r
            }
        }
    }

    private func syncHistory() async {
        let accounts = self.accounts
        await offload {
            let members = accounts.compactMap { a -> SessionSharing.Member? in
                guard let p = ClaudeCLI.profile(configDir: a.cliConfigDir) else { return nil }
                return .init(accountUUID: p.accountUUID, organizationUUID: p.organizationUUID)
            }
            SessionSharing.sync(members: members)
        }
    }

    /// Removes the copies made by history sharing and turns sharing off (otherwise the next
    /// refresh would copy everything again). Returns the number of files removed.
    func undoHistorySharing() async -> Int {
        shareHistory = false
        return await offload { SessionSharing.undo() }
    }

    private func alertIfNeeded() {
        for account in accounts {
            guard let u = usage[account.id]?.usage else { continue }
            for window in u.windows {
                let key = "\(account.id):\(window.label):\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0))"
                if window.percent < Self.rearmPercent {
                    alerted = alerted.filter { !$0.hasPrefix("\(account.id):\(window.label):") }
                    continue
                }
                guard window.percent >= Self.warnPercent, !alerted.contains(key) else { continue }
                alerted.insert(key)
                if account.role == .automation {
                    notifications.post(id: key,
                                       title: "Automation account \(account.id) at \(Int(window.percent))%",
                                       body: "\(window.label) limit" + (window.resetsAt.map { ", resets \(Format.time($0))" } ?? ""))
                } else {
                    let next = suggested.flatMap { $0.id == account.id ? nil : $0 }
                    notifications.post(id: key,
                                       title: "\(account.id) is at \(Int(window.percent))%",
                                       body: "\(window.label) limit" + (next.map { " — switch to \($0.id)" } ?? ""))
                }
            }
        }
    }

    // MARK: Demo

    private func loadDemo() {
        let h: TimeInterval = 3600
        let now = Date()
        func u(_ s: Double, _ w: Double, _ sr: TimeInterval, _ wr: TimeInterval) -> UsageState {
            .loaded(Usage(session: UsageWindow(label: "5-hour", percent: s, resetsAt: now.addingTimeInterval(sr)),
                          weekly: UsageWindow(label: "Weekly", percent: w, resetsAt: now.addingTimeInterval(wr)),
                          fetchedAt: now))
        }
        accounts = [
            Account(id: "work", email: "you@company.com", label: "Team seat", window: .main),
            Account(id: "dev2", email: "dev2@company.com", label: "Team seat"),
            Account(id: "personal", email: "you@example.com", label: "Max"),
            Account(id: "agent", email: "bot@company.com", label: "nightly jobs", role: .automation),
        ]
        usage = ["work": u(92, 64, 1.2 * h, 52 * h), "dev2": u(18, 31, 3.5 * h, 75 * h),
                 "personal": u(47, 22, 2 * h, 30 * h), "agent": u(71, 58, 4 * h, 100 * h)]
        running = ClaudeDesktop.Running(mainPID: 1, profilePIDs: ["dev2": 2])
        statusLines = [StatusLine(id: "build", text: "Build server: green ✓", level: .normal)]
    }
}

/// Shows notifications even while the menu panel (and so this app) is active, and reports
/// whether the user has turned them off.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private var onStatus: ((Bool) -> Void)?

    func install(onStatus: @escaping (Bool) -> Void) {
        self.onStatus = onStatus
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in onStatus(!granted) }
    }

    func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            self?.onStatus?(s.authorizationStatus == .denied)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum AccountStore {
    static func load() -> [Account] {
        guard let data = try? Data(contentsOf: Paths.accountsFile) else { return [] }
        let all = (try? JSONDecoder().decode([Account].self, from: data)) ?? []
        // The file is hand-editable: an invalid id ("", "..", "a/b") must never reach a path,
        // and only one account may use the default Claude Code login.
        var seen = Set<String>()
        var dirs = Set<String>()
        var defaultLoginSeen = false
        return all.filter { a in
            guard Account.isValidID(a.id), seen.insert(a.id).inserted else { return false }
            if let dir = a.cliConfigDir {
                // Two accounts on one sign-in would refresh the same token concurrently.
                guard dirs.insert(Credentials.serviceName(cliConfigDir: dir)).inserted else { return false }
            } else {
                if defaultLoginSeen { return false }
                defaultLoginSeen = true
            }
            return true
        }
    }

    static func save(_ accounts: [Account]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(accounts) {
            try? data.write(to: Paths.accountsFile, options: .atomic)
        }
    }
}
