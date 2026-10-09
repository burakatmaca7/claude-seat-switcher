import Foundation

enum AppInfo {
    static let version = "0.1.4"
    static let repository = URL(string: "https://github.com/burakatmaca7/claude-seat-switcher")!

    /// True when `candidate` (e.g. "0.2.0") is a higher version than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}
