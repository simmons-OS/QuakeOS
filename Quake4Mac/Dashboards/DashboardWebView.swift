import SwiftUI
import WebKit
import Combine

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
                DashboardRuntimeView(dashboard: dashboard)
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

private final class DashboardWebCommandCenter: ObservableObject {
    let actions = PassthroughSubject<DashboardSideAction, Never>()

    func send(_ action: DashboardSideAction) {
        actions.send(action)
    }
}

private struct DashboardRuntimeView: View {
    let dashboard: DashboardConfig
    @StateObject private var commandCenter = DashboardWebCommandCenter()

    var body: some View {
        if dashboard.actionStrip.isEnabled, !dashboard.actionStrip.actions.isEmpty {
            GeometryReader { geo in
                let columns = stripColumns(for: dashboard.actionStrip.actions.count)
                let width = min(geo.size.width * 0.42, CGFloat(columns) * max(120, geo.size.height / 2))

                HStack(spacing: 0) {
                    if dashboard.actionStrip.side == .left {
                        DashboardActionStripView(dashboard: dashboard, commandCenter: commandCenter, columns: columns)
                            .frame(width: width)
                    }
                    DashboardWebView(dashboard: dashboard, commandCenter: commandCenter)
                    if dashboard.actionStrip.side == .right {
                        DashboardActionStripView(dashboard: dashboard, commandCenter: commandCenter, columns: columns)
                            .frame(width: width)
                    }
                }
            }
        } else {
            DashboardWebView(dashboard: dashboard, commandCenter: commandCenter)
        }
    }

    private func stripColumns(for count: Int) -> Int {
        min(3, max(1, Int(ceil(Double(count) / 2.0))))
    }
}

private struct DashboardActionStripView: View {
    let dashboard: DashboardConfig
    @ObservedObject var commandCenter: DashboardWebCommandCenter
    let columns: Int

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(dashboard.actionStrip.actions) { action in
                Button { commandCenter.send(action) } label: {
                    VStack(spacing: 8) {
                        Image(systemName: action.symbol.isEmpty ? action.kind.defaultSymbol : action.symbol)
                            .font(.system(size: 24, weight: .semibold))
                            .frame(height: 30)
                        Text(action.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.72)
                    }
                    .frame(maxWidth: .infinity, minHeight: 92)
                    .padding(.horizontal, 8)
                    .background(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .center)
        .background(Color.black.opacity(0.94))
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

private struct DashboardWebView: NSViewRepresentable {
    let dashboard: DashboardConfig
    @ObservedObject var commandCenter: DashboardWebCommandCenter

    func makeCoordinator() -> Coordinator {
        Coordinator(dashboard: dashboard, commandCenter: commandCenter)
    }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: Self.configuration())
        web.customUserAgent = dashboard.browser.useDesktopUserAgent ? BrowserUserAgent.desktop : nil
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
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
        private var commandCenter: DashboardWebCommandCenter
        private var policy: DashboardAuthPolicy?
        private var loadedDashboardID: UUID?
        private var actionSub: AnyCancellable?

        init(dashboard: DashboardConfig, commandCenter: DashboardWebCommandCenter) {
            self.dashboard = dashboard
            self.commandCenter = commandCenter
            super.init()
            bindActions()
        }

        func update(dashboard: DashboardConfig) {
            guard dashboard != self.dashboard else { return }
            let previousDesktopUA = self.dashboard.browser.useDesktopUserAgent
            self.dashboard = dashboard
            if previousDesktopUA != dashboard.browser.useDesktopUserAgent {
                web?.customUserAgent = dashboard.browser.useDesktopUserAgent ? BrowserUserAgent.desktop : nil
            }
            loadedDashboardID = nil
            load()
        }

        func load(force: Bool = false) {
            guard let web else { return }
            if force { loadedDashboardID = nil }
            guard loadedDashboardID != dashboard.id else { return }
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

        private func bindActions() {
            actionSub = commandCenter.actions.sink { [weak self] action in
                self?.run(action)
            }
        }

        private func run(_ action: DashboardSideAction) {
            guard let web else { return }
            switch action.kind {
            case .reload:
                web.reload()
            case .back:
                if web.canGoBack { web.goBack() }
            case .forward:
                if web.canGoForward { web.goForward() }
            case .home:
                load(force: true)
            case .openURL:
                guard let url = action.url else { return }
                let request = policy?.requestByApplyingAuth(to: URLRequest(url: url)) ?? URLRequest(url: url)
                web.load(request)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if DashboardNavigationPolicy.shouldOpenExternally(
                dashboard: dashboard,
                navigationType: navigationAction.navigationType,
                url: navigationAction.request.url
            ) {
                if let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }

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

extension DashboardWebView.Coordinator: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard DashboardNavigationPolicy.shouldOpenNewWindowExternally(
            dashboard: dashboard,
            url: navigationAction.request.url
        ), let url = navigationAction.request.url else { return nil }
        NSWorkspace.shared.open(url)
        return nil
    }
}

enum DashboardNavigationPolicy {
    static func shouldOpenExternally(dashboard: DashboardConfig, navigationType: WKNavigationType, url: URL?) -> Bool {
        guard dashboard.browser.openLinksExternally,
              navigationType == .linkActivated,
              isHTTPURL(url) else { return false }
        return true
    }

    static func shouldOpenNewWindowExternally(dashboard: DashboardConfig, url: URL?) -> Bool {
        guard dashboard.browser.openLinksExternally,
              isHTTPURL(url) else { return false }
        return true
    }

    private static func isHTTPURL(_ url: URL?) -> Bool {
        let scheme = url?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
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
