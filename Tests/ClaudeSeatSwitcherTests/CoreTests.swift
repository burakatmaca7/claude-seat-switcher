import Foundation
import XCTest
@testable import ClaudeSeatSwitcher

final class UsageParserTests: XCTestCase {
    func testLimitsArray() throws {
        let json = """
        {"limits":[
          {"kind":"session","group":"session","percent":42,"resets_at":"2026-10-09T11:59:59.724545+00:00","scope":null},
          {"kind":"weekly","group":"weekly","percent":10,"resets_at":"2026-10-12T09:00:00+00:00","scope":null},
          {"kind":"weekly_scoped","group":"weekly","percent":3,"resets_at":"2026-10-12T09:00:00+00:00",
           "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}
        ]}
        """
        let u = try UsageParser.parse(Data(json.utf8))
        XCTAssertEqual(u.session?.percent, 42)
        XCTAssertNotNil(u.session?.resetsAt)
        XCTAssertEqual(u.weekly?.percent, 10)
        XCTAssertEqual(u.scopedWeekly?.label, "Fable (wk)")
        XCTAssertEqual(u.scopedWeekly?.percent, 3)
    }

    func testScopedWeeklyIsNotMistakenForAccountWeekly() throws {
        let json = """
        {"limits":[{"group":"weekly","percent":80,"resets_at":null,
          "scope":{"model":{"display_name":"Fable"}}}]}
        """
        let u = try UsageParser.parse(Data(json.utf8))
        XCTAssertNil(u.weekly)
        XCTAssertEqual(u.scopedWeekly?.percent, 80)
    }

    func testLegacyShape() throws {
        let json = #"{"five_hour":{"utilization":12.5,"resets_at":"2026-10-09T11:00:00Z"},"seven_day":{"utilization":40}}"#
        let u = try UsageParser.parse(Data(json.utf8))
        XCTAssertEqual(u.session?.percent, 12.5)
        XCTAssertEqual(u.weekly?.percent, 40)
    }
}

final class CredentialsTests: XCTestCase {
    func testDefaultService() {
        XCTAssertEqual(Credentials.serviceName(cliConfigDir: nil), "Claude Code-credentials")
    }

    /// Claude Code names a profile's Keychain item after SHA-256 of the directory path;
    /// a trailing slash must not change it.
    func testProfileServiceIsStableAndIgnoresTrailingSlash() {
        let a = Credentials.serviceName(cliConfigDir: "/tmp/profile-x")
        XCTAssertEqual(a, Credentials.serviceName(cliConfigDir: "/tmp/profile-x/"))
        XCTAssertTrue(a.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(a, "Claude Code-credentials-beef0ac1")   // sha256("/tmp/profile-x")[:8]
    }

    /// The secret must be hex-only, so no part of it can ever be parsed as another `security` command.
    func testWriteCommandHexEncodesSecret() throws {
        let raw: [String: Any] = ["claudeAiOauth": ["accessToken": "x\"\ndelete-generic-password -s victim"]]
        let cmd = try XCTUnwrap(Credentials.writeCommand(service: "Claude Code-credentials", account: "me", raw: raw))
        let secret = try XCTUnwrap(cmd.components(separatedBy: " -X ").last?.trimmingCharacters(in: .newlines))
        XCTAssertTrue(secret.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(cmd.filter { $0 == "\n" }.count, 1)
    }

    func testWriteCommandRejectsUnsafeNamesAndOversizedItems() {
        let raw: [String: Any] = ["a": "b"]
        XCTAssertNil(Credentials.writeCommand(service: "x\"; delete", account: "me", raw: raw))
        XCTAssertNil(Credentials.writeCommand(service: "svc", account: "me\nquit", raw: raw))
        XCTAssertNil(Credentials.writeCommand(service: "svc", account: "", raw: raw))
        let big: [String: Any] = ["blob": String(repeating: "A", count: 3000)]
        XCTAssertNil(Credentials.writeCommand(service: "svc", account: "me", raw: big))
    }
}

final class SessionSharingTests: XCTestCase {
    /// Sync copies missing session files within one organization only, never overwrites,
    /// and undo removes exactly the copies.
    func testSyncWithinOrganizationNeverOverwrites() throws {
        let fm = FileManager.default
        // A temporary folder: the real Claude session folder is never touched by tests.
        let root = fm.temporaryDirectory.appendingPathComponent("css-test-\(UUID().uuidString)")
        let journal = root.appendingPathComponent("journal.json")
        defer { try? fm.removeItem(at: root) }
        let tag = "x"
        let a = "test-a-\(tag)", b = "test-b-\(tag)", c = "test-c-\(tag)"
        let org = "org-\(tag)", other = "other-\(tag)"

        func write(_ acct: String, _ o: String, _ name: String, _ body: String) throws {
            let dir = root.appendingPathComponent("\(acct)/\(o)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write(a, org, "local_1.json", "from-a")
        try write(b, org, "local_1.json", "b-own-version")
        try write(b, org, "local_2.json", "from-b")
        try write(c, other, "local_3.json", "other-org")

        let copied = SessionSharing.sync(members: [
            .init(accountUUID: a, organizationUUID: org),
            .init(accountUUID: b, organizationUUID: org),
            .init(accountUUID: c, organizationUUID: other),
        ], root: root, journal: journal)
        XCTAssertEqual(copied, 1)   // only local_2 → a
        let b1 = try String(contentsOf: root.appendingPathComponent("\(b)/\(org)/local_1.json"), encoding: .utf8)
        XCTAssertEqual(b1, "b-own-version")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("\(a)/\(org)/local_2.json").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("\(a)/\(other)").path))

        SessionSharing.undo(root: root, journal: journal, useTrash: false)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("\(a)/\(org)/local_2.json").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("\(b)/\(org)/local_2.json").path))
    }
}

final class ClaudeDesktopTests: XCTestCase {
    func testParsesMainWindowAndProfilesWithSpacesInPath() {
        let exe = "/Applications/Claude.app/Contents/MacOS/Claude"
        let root = "/Users/x/Library/Application Support/ClaudeSeatSwitcher/DesktopProfiles/"
        let ps = """
          100 /Applications/Claude.app/Contents/MacOS/Claude
          200 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=\(root)work
          300 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=\(root)dev2 --some-flag
          400 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu
          500 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/elsewhere/profile
        """
        let r = ClaudeDesktop.parse(psOutput: ps, executable: exe, profilesRoot: root)
        XCTAssertEqual(r.mainPID, 100)
        XCTAssertEqual(r.profilePIDs, ["work": 200, "dev2": 300])
    }
}

final class AppInfoTests: XCTestCase {
    func testVersionComparisonIsNumeric() {
        XCTAssertTrue(AppInfo.isNewer("0.10.0", than: "0.9.1"))
        XCTAssertTrue(AppInfo.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertFalse(AppInfo.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(AppInfo.isNewer("0.1.0", than: "0.2.0"))
    }
}

final class FormatTests: XCTestCase {
    func testRemaining() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(2 * 3600 + 15 * 60), now: now), "2h 15m")
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(3 * 86_400 + 4 * 3600), now: now), "3d 4h")
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(-10), now: now), "1m")
    }

    func testResetShowsCountdownWithinADay() {
        let now = Date()
        XCTAssertEqual(Format.reset(now.addingTimeInterval(90 * 60), now: now), "↻ 1h 30m")
        XCTAssertTrue(Format.reset(now.addingTimeInterval(3 * 86_400), now: now).hasPrefix("↻ "))
        XCTAssertEqual(Format.reset(nil, now: now), "—")
    }
}

final class PathSafetyTests: XCTestCase {
    func testAccountIDValidation() {
        for ok in ["work", "dev2", "a", "team-seat-1"] { XCTAssertTrue(Account.isValidID(ok), ok) }
        for bad in ["", "..", "../x", "a/b", "Work", "-x", " x", "a.b", String(repeating: "a", count: 21)] {
            XCTAssertFalse(Account.isValidID(bad), bad)
        }
    }

    /// Removal is limited to direct children of the given folder, whatever the stored path says.
    func testTrashChildRefusesEscapes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("css-trash-\(UUID().uuidString)")
        let parent = root.appendingPathComponent("CLIProfiles")
        let outside = root.appendingPathComponent("Documents")
        try fm.createDirectory(at: parent.appendingPathComponent("work"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        XCTAssertFalse(Paths.trashChild(parent.appendingPathComponent("../Documents"), of: parent))
        XCTAssertFalse(Paths.trashChild(parent, of: parent))
        XCTAssertFalse(Paths.trashChild(URL(fileURLWithPath: "/"), of: parent))
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
        XCTAssertTrue(Paths.trashChild(parent.appendingPathComponent("work"), of: parent))
    }
}

final class SessionSharingSafetyTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var journal: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("css-share-\(UUID().uuidString)")
        journal = root.appendingPathComponent("journal.json")
        try fm.createDirectory(at: root.appendingPathComponent("a/org"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("b/org"), withIntermediateDirectories: true)
        try "chat".write(to: root.appendingPathComponent("a/org/local_1.json"), atomically: true, encoding: .utf8)
    }

    override func tearDown() { try? fm.removeItem(at: root) }

    private var members: [SessionSharing.Member] {
        [.init(accountUUID: "a", organizationUUID: "org"), .init(accountUUID: "b", organizationUUID: "org")]
    }

    /// A copy the user continued in (content changed) survives undo.
    func testUndoKeepsModifiedCopies() throws {
        XCTAssertEqual(SessionSharing.sync(members: members, root: root, journal: journal), 1)
        let copy = root.appendingPathComponent("b/org/local_1.json")
        try "continued on b".write(to: copy, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionSharing.undo(root: root, journal: journal, useTrash: false), 0)
        XCTAssertTrue(fm.fileExists(atPath: copy.path))
    }

    /// A copy the user deleted is not brought back.
    func testDeletedCopyIsNotRecreated() throws {
        SessionSharing.sync(members: members, root: root, journal: journal)
        try fm.removeItem(at: root.appendingPathComponent("b/org/local_1.json"))
        XCTAssertEqual(SessionSharing.sync(members: members, root: root, journal: journal), 0)
    }

    /// A tampered journal cannot make undo delete anything outside the shared folder.
    func testUndoIgnoresPathsOutsideRoot() throws {
        let outside = fm.temporaryDirectory.appendingPathComponent("css-outside-\(UUID().uuidString).json")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: outside) }
        let entries = [SessionSharing.JournalEntry(path: outside.path, sha256: "x"),
                       SessionSharing.JournalEntry(path: root.appendingPathComponent("../\(outside.lastPathComponent)").path, sha256: "x")]
        try JSONEncoder().encode(entries).write(to: journal)
        XCTAssertEqual(SessionSharing.undo(root: root, journal: journal, useTrash: false), 0)
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
    }

    /// Account/org ids that are not UUID-like never become folder names.
    func testUnsafeMemberIDsAreIgnored() {
        let bad: [SessionSharing.Member] = [.init(accountUUID: "../x", organizationUUID: "org"),
                                            .init(accountUUID: "a", organizationUUID: "org")]
        XCTAssertEqual(SessionSharing.sync(members: bad, root: root, journal: journal), 0)
    }
}

@MainActor
final class LoginURLTests: XCTestCase {
    func testOnlyAnthropicHTTPSAuthorizePagesAreAccepted() {
        XCTAssertNotNil(CLILogin.validSignInURL("https://claude.com/cai/oauth/authorize?code=true&client_id=x"))
        XCTAssertNil(CLILogin.validSignInURL("http://claude.com/cai/oauth/authorize"))
        XCTAssertNil(CLILogin.validSignInURL("https://evil.example/?oauth/authorize"))
        XCTAssertNil(CLILogin.validSignInURL("https://claude.com.evil.example/oauth/authorize"))
        XCTAssertNil(CLILogin.validSignInURL("file:///etc/passwd"))
    }
}

final class EffectivePercentTests: XCTestCase {
    /// An exhausted weekly limit makes the account full, whatever its 5-hour window says;
    /// a window whose reset has passed no longer counts.
    func testTightestActiveLimitWins() {
        let now = Date()
        let u = Usage(session: UsageWindow(label: "5-hour", percent: 5, resetsAt: now.addingTimeInterval(3600)),
                      weekly: UsageWindow(label: "Weekly", percent: 100, resetsAt: now.addingTimeInterval(86_400)),
                      fetchedAt: now)
        XCTAssertEqual(u.effectivePercent(now: now), 100)
        let stale = Usage(session: UsageWindow(label: "5-hour", percent: 95, resetsAt: now.addingTimeInterval(-60)),
                          fetchedAt: now)
        XCTAssertEqual(stale.effectivePercent(now: now), 0)
    }
}

final class ShellTests: XCTestCase {
    /// A child that ignores SIGTERM is killed; the call returns instead of hanging.
    func testTimeoutKillsStubbornChild() {
        let start = Date()
        let r = Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertNotEqual(r.status, 0)
    }

    /// A grandchild holding stdout open cannot block the caller.
    func testGrandchildHoldingPipeDoesNotBlock() {
        let start = Date()
        let r = Shell.run("/bin/sh", ["-c", "sleep 30 & echo ok"], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertTrue(r.stdout.contains("ok"))
    }
}

final class OwnershipTests: XCTestCase {
    /// Only CLIProfiles/<id> counts as app-owned; any other folder might be shared with other tools.
    func testOwnsOnlyItsOwnProfileFolder() {
        let own = Account(id: "work", email: "", cliConfigDir: Paths.cliProfile(for: "work").path)
        XCTAssertTrue(own.ownsCLIProfile)
        XCTAssertFalse(Account(id: "work", email: "", cliConfigDir: Paths.cliProfile(for: "other").path).ownsCLIProfile)
        XCTAssertFalse(Account(id: "work", email: "", cliConfigDir: "~/.claude-work").ownsCLIProfile)
        XCTAssertFalse(Account(id: "work", email: "", cliConfigDir: Paths.cliProfiles.path + "/../work").ownsCLIProfile)
        XCTAssertFalse(Account(id: "work", email: "", cliConfigDir: nil).ownsCLIProfile)
    }
}
