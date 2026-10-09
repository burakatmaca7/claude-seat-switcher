import AppKit

/// Opens the usage sign-in page in a private window of an installed browser.
///
/// The page is approved by whichever account is signed in to claude.ai in the browser, so adding several seats
/// in a row approved them all as the previous one. A private window has nobody signed in. (An embedded web view
/// was tried and is refused by claude.ai's browser check, rightly — so a real browser is used.)
struct PrivateBrowser {
    let name: String
    let app: String          // path of the .app bundle
    let flag: String         // the browser's own "new private window" command-line flag

    static let known: [PrivateBrowser] = [
        PrivateBrowser(name: "Chrome", app: "/Applications/Google Chrome.app", flag: "--incognito"),
        PrivateBrowser(name: "Brave", app: "/Applications/Brave Browser.app", flag: "--incognito"),
        PrivateBrowser(name: "Edge", app: "/Applications/Microsoft Edge.app", flag: "--inprivate"),
        PrivateBrowser(name: "Firefox", app: "/Applications/Firefox.app", flag: "--private-window"),
    ]

    /// The first installed browser that can open a private window from the command line (Safari cannot).
    static func installed() -> PrivateBrowser? {
        known.first { FileManager.default.fileExists(atPath: $0.app) }
    }

    /// Opens `url` in a new private window. Only https Anthropic sign-in pages are ever passed on.
    @discardableResult
    func open(_ url: URL, dryRun: Bool = false) -> Bool {
        guard CLILogin.validSignInURL(url.absoluteString) != nil else { return false }
        if dryRun { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", app, "--args", flag, url.absoluteString]
        do { try p.run(); return true } catch { return false }
    }
}
