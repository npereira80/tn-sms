//
//  GoogleLoginView.swift
//  SMS TN
//
//  Embedded Google sign-in used for Gaia (Google-account) pairing.
//  The user signs in to their Google account; once Google redirects to
//  messages.google.com we harvest the cookies libgm needs and hand them
//  back. Cookies live only in a non-persistent web data store and are
//  passed straight to the protocol layer, never written to disk here.
//

import SwiftUI
import WebKit

struct GoogleLoginView: View {
    /// Called with the harvested cookie set once sign-in completes.
    let onCookies: ([String: String]) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Google")
                    .font(.headline)
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
            }
            .padding(12)
            Divider()
            GoogleWebView(onCookies: onCookies)
        }
        .frame(width: 520, height: 640)
    }
}

private struct GoogleWebView: NSViewRepresentable {
    let onCookies: ([String: String]) -> Void

    // Cookies libgm requires for Gaia pairing.
    static let requiredCookies: Set<String> = ["SID", "HSID", "OSID", "SSID", "APISID", "SAPISID"]

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookies: onCookies)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Use a desktop Safari UA so Google serves the standard sign-in flow.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        let url = URL(string: "https://accounts.google.com/AccountChooser?continue=https://messages.google.com/web/config")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCookies: ([String: String]) -> Void
        private var finished = false

        init(onCookies: @escaping ([String: String]) -> Void) {
            self.onCookies = onCookies
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished else { return }
            let host = webView.url?.host ?? ""
            // Only harvest once Google has redirected to Messages, which
            // means the account session cookies are set.
            guard host.contains("messages.google.com") else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                var map: [String: String] = [:]
                for cookie in cookies where cookie.domain.contains("google.com") {
                    map[cookie.name] = cookie.value
                }
                guard GoogleWebView.requiredCookies.isSubset(of: Set(map.keys)) else { return }
                self.finished = true
                self.onCookies(map)
            }
        }
    }
}
