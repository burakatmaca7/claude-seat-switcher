import SwiftUI
import WebKit

/// The usage sign-in page in a clean, cookie-free window inside the app.
///
/// In the user's browser the page is approved by whichever account happens to be signed in there, so adding
/// several seats in a row approved them all as the previous one, and the long code had to be copied by hand
/// (easily confused with the 6-digit email code). Here nobody is signed in: the person signs in as the account
/// being added, approves, and the app reads the code from the callback address itself.
///
/// The view never stores anything (non-persistent data store), loads only Anthropic and identity-provider
/// pages, and hands over only the `code#state` value from the callback.
struct SignInWebView: NSViewRepresentable {
    let url: URL
    let onCode: (String) -> Void

    /// Pages the sign-in may pass through. Anything else is refused.
    nonisolated static let allowedHosts: Set<String> = CLILogin.allowedHosts.union([
        "accounts.google.com", "accounts.youtube.com", "appleid.apple.com", "login.microsoftonline.com",
    ])

    /// `code#state` from the callback page address, or nil if `url` is not that page.
    nonisolated static func callbackCode(from url: URL) -> String? {
        guard url.scheme == "https", let host = url.host?.lowercased(), CLILogin.allowedHosts.contains(host),
              url.path.hasSuffix("/oauth/code/callback"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty,
              !code.contains(where: \.isWhitespace), !state.contains(where: \.isWhitespace)
        else { return nil }
        return "\(code)#\(state)"
    }

    nonisolated static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return url.scheme == "about" }
        return allowedHosts.contains(host) || allowedHosts.contains { host.hasSuffix("." + $0) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()          // a fresh session every time; nothing left behind
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if !delivered, let code = SignInWebView.callbackCode(from: url) {
                delivered = true
                onCode(code)
            }
            decisionHandler(SignInWebView.isAllowed(url) ? .allow : .cancel)
        }
    }
}
