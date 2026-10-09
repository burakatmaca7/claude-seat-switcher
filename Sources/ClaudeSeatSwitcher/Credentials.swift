import CryptoKit
import Foundation

/// Reads and writes Claude Code CLI sign-ins stored in the macOS Keychain.
///
/// The CLI stores each sign-in as a generic password. The default login uses the service
/// "Claude Code-credentials"; a login made with `CLAUDE_CONFIG_DIR=<dir>` uses
/// "Claude Code-credentials-" + the first 8 hex digits of SHA-256(<dir>).
///
/// Access goes through `/usr/bin/security` (the tool the CLI itself uses), so macOS does not
/// prompt for Keychain access on every rebuild of this unsigned app.
enum Credentials {
    struct OAuth {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var refreshTokenExpiresAt: Date?
        /// The full stored JSON, kept so a refresh writes back everything else unchanged.
        var raw: [String: Any]
        var keychainAccount: String
    }

    static func serviceName(cliConfigDir: String?) -> String {
        guard let dir = cliConfigDir else { return "Claude Code-credentials" }
        var path = Paths.expand(dir)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    static func read(service: String) -> OAuth? {
        let secret = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        guard secret.status == 0,
              let data = secret.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = raw["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              let refresh = oauth["refreshToken"] as? String,
              let expires = oauth["expiresAt"] as? Double
        else { return nil }

        let attrs = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service])
        // Greedy to the end of the line, so an account name containing a quote is captured whole
        // (and then rejected by `writeCommand`) instead of silently truncated to another item's name.
        guard let account = firstMatch(#"(?m)"acct"<blob>="(.*)"$"#, in: attrs.stdout) else { return nil }
        return OAuth(accessToken: access, refreshToken: refresh,
                     expiresAt: Date(timeIntervalSince1970: expires / 1000),
                     refreshTokenExpiresAt: (oauth["refreshTokenExpiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                     raw: raw, keychainAccount: account)
    }

    /// `security -i` reads its input in 4095-byte chunks: a longer line is split and the remainder is
    /// executed as a separate command. Every command we send must stay well below that.
    static let maxCommandBytes = 4000
    /// Room for a refreshed token being longer than the current one.
    private static let refreshHeadroom = 400

    /// Builds the `security -i` command that stores `raw` as the item's password.
    ///
    /// The secret goes through stdin, never argv, so it cannot be read from the process list.
    /// It is hex-encoded (`-X`): no hex string can form a `security` command, so even an
    /// attacker-influenced value (the item also holds MCP server tokens) cannot inject one.
    static func writeCommand(service: String, account: String, raw: [String: Any]) -> String? {
        let unsafe: (String) -> Bool = { $0.isEmpty || $0.contains { "\n\r\0\"\\".contains($0) } }
        guard !unsafe(service), !unsafe(account),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -X \(hex)\n"
        return command.utf8.count < maxCommandBytes ? command : nil
    }

    /// True if a refreshed copy of this item can be written back safely. Checked BEFORE refreshing:
    /// a refresh rotates the token on the server, so a token that cannot be saved would be lost.
    static func canWriteBack(service: String, oauth: OAuth) -> Bool {
        guard let cmd = writeCommand(service: service, account: oauth.keychainAccount, raw: oauth.raw) else {
            return false
        }
        return cmd.utf8.count + refreshHeadroom * 2 < maxCommandBytes
    }

    /// Deletes the Keychain sign-in of an app-owned CLI profile (never the default login).
    static func deleteAppOwnedSignIn(cliConfigDir: String) {
        let service = serviceName(cliConfigDir: cliConfigDir)
        guard service != serviceName(cliConfigDir: nil) else { return }
        DispatchQueue.global(qos: .utility).async {
            Shell.run("/usr/bin/security", ["delete-generic-password", "-s", service])
        }
    }

    /// Writes refreshed tokens back into the same Keychain item, then reads it back to confirm.
    static func write(service: String, oauth: OAuth) -> Bool {
        var raw = oauth.raw
        var inner = (raw["claudeAiOauth"] as? [String: Any]) ?? [:]
        inner["accessToken"] = oauth.accessToken
        inner["refreshToken"] = oauth.refreshToken
        inner["expiresAt"] = Int(oauth.expiresAt.timeIntervalSince1970 * 1000)
        if let r = oauth.refreshTokenExpiresAt {
            inner["refreshTokenExpiresAt"] = Int(r.timeIntervalSince1970 * 1000)
        }
        raw["claudeAiOauth"] = inner
        guard let command = writeCommand(service: service, account: oauth.keychainAccount, raw: raw) else {
            return false
        }
        Shell.run("/usr/bin/security", ["-i"], input: command)
        // Success is what the Keychain now holds, not what the tool printed.
        return read(service: service)?.accessToken == oauth.accessToken
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
