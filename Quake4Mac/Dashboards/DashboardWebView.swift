import SwiftUI
import WebKit

struct DashboardScreenView: View {
    let dashboardID: UUID
    @ObservedObject private var store = DashboardStore.shared

    var body: some View {
        if let dashboard = store.dashboard(id: dashboardID) {
            if dashboard.url == nil {
                DashboardFallbackView(title: "Invalid Dashboard URL", detail: dashboard.urlString)
            } else if let authError = authError(for: dashboard) {
                DashboardFallbackView(title: "Dashboard Auth Needed", detail: authError)
            } else {
                DashboardWebView(dashboard: dashboard)
                    .ignoresSafeArea()
            }
        } else {
            DashboardFallbackView(title: "Dashboard Missing", detail: "Open Settings to choose another dashboard.")
        }
    }

    private func authError(for dashboard: DashboardConfig) -> String? {
        do {
            _ = try store.resolvedAuth(for: dashboard)
            return nil
        } catch {
            return "Open Settings to update credentials."
        }
    }
}

struct DirectWebDashboardView: View {
    let urlString: String

    var body: some View {
        if let url = URL(string: urlString) {
            DirectWebDashboardWeb(url: url).ignoresSafeArea()
        } else {
            DashboardFallbackView(title: "Invalid URL", detail: urlString)
        }
    }
}

struct DashboardFallbackView: View {
    let title: String
    let detail: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.cyan)
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 48)
        }
    }
}

struct DashboardWebView: NSViewRepresentable {
    let dashboard: DashboardConfig

    func makeCoordinator() -> Coordinator {
        Coordinator(dashboard: dashboard)
    }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: Self.configuration())
        web.customUserAgent = BrowserUserAgent.desktop
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        context.coordinator.load()
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.update(dashboard: dashboard)
    }

    private static func configuration() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.processPool = DashboardWebProcess.shared
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        return cfg
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        private var dashboard: DashboardConfig
        private var policy: DashboardAuthPolicy?
        private var loadedDashboardID: UUID?

        init(dashboard: DashboardConfig) {
            self.dashboard = dashboard
        }

        func update(dashboard: DashboardConfig) {
            guard dashboard != self.dashboard else { return }
            self.dashboard = dashboard
            loadedDashboardID = nil
            load()
        }

        func load() {
            guard loadedDashboardID != dashboard.id, let web else { return }
            loadedDashboardID = dashboard.id

            do {
                let auth = try DashboardStore.shared.resolvedAuth(for: dashboard)
                let policy = DashboardAuthPolicy(dashboard: dashboard, auth: auth)
                self.policy = policy
                guard let url = dashboard.url else { return }
                web.load(policy.requestByApplyingAuth(to: URLRequest(url: url)))
            } catch {
                NSLog("[Quake] Dashboard auth failed: \(error.localizedDescription)")
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let policy, policy.requestNeedsAuth(navigationAction.request) else {
                decisionHandler(.allow)
                return
            }
            webView.load(policy.requestByApplyingAuth(to: navigationAction.request))
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let credential = policy?.basicCredential(for: challenge.protectionSpace.host) {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[Quake] Dashboard load failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[Quake] Dashboard provisional load failed: \(error.localizedDescription)")
        }
    }
}

private struct DirectWebDashboardWeb: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.customUserAgent = BrowserUserAgent.desktop
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}
}

private enum BrowserUserAgent {
    static let desktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}

private enum DashboardWebProcess {
    static let shared = WKProcessPool()
}
