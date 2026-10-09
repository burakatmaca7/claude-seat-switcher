import Foundation

/// EVERY network call the app makes lives in this file.
///
/// Hosts contacted (and nothing else):
///   - https://api.anthropic.com/api/oauth/usage   — read an account's usage percentages
///   - https://platform.claude.com/v1/oauth/token  — refresh an app-owned sign-in before it expires
///   - https://api.github.com/repos/<this repo>/releases/latest — once a day, is there a newer version?
///     (can be turned off; sends nothing but a plain GET)
///
/// Anthropic requests carry only the account's own OAuth token. No analytics, no telemetry.
enum Network {
    static let userAgent = "ClaudeSeatSwitcher/\(AppInfo.version) (+https://github.com/burakatmaca7/claude-seat-switcher)"
    /// The public OAuth client of Claude Code; sign-ins created by `claude auth login` belong to it.
    static let claudeCodeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral   // no cookies, no cache on disk
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// None of these endpoints redirect. Following one could resend the Authorization header or a
    /// refresh token to another host, so every redirect is refused.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case http(Int, retryAfter: TimeInterval?)
        case redirected
        case badResponse
        var description: String {
            switch self {
            case .http(401, _), .http(400, _): return "signed out — add the account again"
            case .http(429, _): return "rate limited — will retry"
            case .http(let c, _): return "Anthropic returned HTTP \(c) — will retry"
            case .redirected: return "unexpected redirect — request blocked"
            case .badResponse: return "unexpected response — will retry"
            }
        }
        var retryAfter: TimeInterval? {
            if case .http(_, let r) = self { return r }
            return nil
        }
        /// 400 invalid_grant / 401: the sign-in is no longer valid.
        var isSignedOut: Bool {
            if case .http(let c, _) = self { return c == 400 || c == 401 }
            return false
        }
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.statusCode == 200 else {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                .flatMap { $0.isFinite && $0 >= 0 ? min($0, 3600) : nil }
            throw Failure.http(http.statusCode, retryAfter: retry)
        }
    }

    static func fetchUsage(accessToken: String) async throws -> Usage {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, resp) = try await session.data(for: req)
        if (resp as? HTTPURLResponse).map({ (300..<400).contains($0.statusCode) }) == true { throw Failure.redirected }
        try check(resp)
        return try UsageParser.parse(data)
    }

    struct Release {
        var version: String
        var page: URL
    }

    /// The latest published release, or nil if it cannot be read. No credentials are sent.
    static func latestRelease() async -> Release? {
        let url = URL(string: "https://api.github.com/repos/burakatmaca7/claude-seat-switcher/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              tag.range(of: #"^v?[0-9]+(\.[0-9]+){0,3}$"#, options: .regularExpression) != nil
        else { return nil }
        // The download link is built here from the validated tag, never taken from the response.
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, page: AppInfo.repository.appendingPathComponent("releases/tag/v\(version)"))
    }

    struct RefreshedToken {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: TimeInterval
        var refreshTokenExpiresIn: TimeInterval?
    }

    static func refresh(refreshToken: String) async throws -> RefreshedToken {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": claudeCodeClientID,
        ])
        let (data, resp) = try await session.data(for: req)
        if (resp as? HTTPURLResponse).map({ (300..<400).contains($0.statusCode) }) == true { throw Failure.redirected }
        try check(resp)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = j["access_token"] as? String else { throw Failure.badResponse }
        return RefreshedToken(accessToken: access,
                              refreshToken: j["refresh_token"] as? String,
                              expiresIn: (j["expires_in"] as? Double) ?? 28_800,
                              refreshTokenExpiresIn: j["refresh_token_expires_in"] as? Double)
    }
}

/// Parses the usage endpoint's JSON. Kept separate from networking so it can be unit-tested.
enum UsageParser {
    static func parse(_ data: Data, now: Date = Date()) throws -> Usage {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Network.Failure.badResponse
        }
        var usage = Usage(fetchedAt: now)
        for limit in (j["limits"] as? [[String: Any]]) ?? [] {
            let percent = (limit["percent"] as? Double) ?? 0
            let resets = date(limit["resets_at"])
            let group = limit["group"] as? String
            let scope = limit["scope"] as? [String: Any]
            switch group {
            case "session":
                usage.session = UsageWindow(label: "5-hour", percent: percent, resetsAt: resets)
            case "weekly" where scope == nil:
                usage.weekly = UsageWindow(label: "Weekly", percent: percent, resetsAt: resets)
            case "weekly" where usage.scopedWeekly == nil:
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                usage.scopedWeekly = UsageWindow(label: "\(model ?? "Model") (wk)", percent: percent, resetsAt: resets)
            default:
                break
            }
        }
        // Older response shape: utilization fields at the top level.
        if usage.session == nil, let s = j["five_hour"] as? [String: Any] {
            usage.session = UsageWindow(label: "5-hour", percent: (s["utilization"] as? Double) ?? 0,
                                        resetsAt: date(s["resets_at"]))
        }
        if usage.weekly == nil, let s = j["seven_day"] as? [String: Any] {
            usage.weekly = UsageWindow(label: "Weekly", percent: (s["utilization"] as? Double) ?? 0,
                                       resetsAt: date(s["resets_at"]))
        }
        return usage
    }

    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
