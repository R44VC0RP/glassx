import SwiftUI
import WebKit

/// x.com's own sign-in page in a private web view. As soon as X sets the `auth_token` and
/// `ct0` cookies, the session is handed to the app and the web view's data is discarded.
struct LoginWebView: NSViewRepresentable {
    var onSession: ([String: String]) -> Void
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = XClient.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .windowBackgroundColor
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.webView = webView
        webView.load(URLRequest(url: URL(string: "https://x.com/i/flow/login")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
        nsView.stopLoading()
        coordinator.closePopups()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let parent: LoginWebView
        weak var webView: WKWebView?
        private var finished = false
        private var popups: [NSWindow] = []

        /// "Continue with Google/Apple" open a popup that reports back to x.com via `window.opener`,
        /// so it has to be a real child web view sharing this configuration.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 640), configuration: configuration)
            popup.customUserAgent = XClient.userAgent
            popup.uiDelegate = self
            let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Sign in"
            window.contentView = popup
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            popups.append(window)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            popups.removeAll { window in
                guard window.contentView === webView else { return false }
                window.close()
                return true
            }
        }

        func closePopups() {
            popups.forEach { $0.close() }
            popups.removeAll()
        }

        init(_ parent: LoginWebView) { self.parent = parent }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                var jar: [String: String] = [:]
                for cookie in cookies where cookie.domain.hasSuffix("x.com") { jar[cookie.name] = cookie.value }
                guard jar["auth_token"] != nil, jar["ct0"] != nil, jar["twid"] != nil else { return }
                self.finished = true
                DispatchQueue.main.async {
                    self.popups.forEach { $0.close() }
                    self.popups.removeAll()
                    self.parent.onSession(jar)
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
