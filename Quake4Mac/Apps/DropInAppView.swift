import SwiftUI
import WebKit

struct DropInStaticAppScreenView: View {
    let appID: String
    @ObservedObject private var store = DropInAppStore.shared
    @ObservedObject private var loopback = DropInAppLoopbackServer.shared

    var body: some View {
        if let app = store.app(id: appID) {
            if app.manifest.served {
                servedApp(app)
            } else if let url = store.staticLaunchURL(for: app) {
                DropInStaticAppWebView(entryURL: url, readAccessURL: app.rootURL)
            } else {
                DashboardFallbackView(title: "Invalid App Entry", detail: app.manifest.entry)
            }
        } else {
            DashboardFallbackView(title: "App Missing", detail: "Open Settings to refresh drop-in apps.")
        }
    }

    @ViewBuilder private func servedApp(_ app: DropInAppRecord) -> some View {
        if let port = loopback.port,
           let url = store.servedLaunchURL(for: app, port: port) {
            DropInServedAppWebView(entryURL: url)
                .onAppear { loopback.start() }
        } else if !loopback.lastError.isEmpty {
            DashboardFallbackView(title: "Served App Failed", detail: loopback.lastError)
                .onAppear { loopback.start() }
        } else {
            DashboardFallbackView(title: "Starting Served App", detail: app.manifest.name)
                .onAppear { loopback.start() }
        }
    }
}

private struct DropInStaticAppWebView: NSViewRepresentable {
    let entryURL: URL
    let readAccessURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        context.coordinator.load(entryURL: entryURL, readAccessURL: readAccessURL, into: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.load(entryURL: entryURL, readAccessURL: readAccessURL, into: web)
    }

    final class Coordinator {
        private var loadedEntryURL: URL?
        private var loadedReadAccessURL: URL?

        func load(entryURL: URL, readAccessURL: URL, into web: WKWebView) {
            guard loadedEntryURL != entryURL || loadedReadAccessURL != readAccessURL else { return }
            loadedEntryURL = entryURL
            loadedReadAccessURL = readAccessURL
            web.loadFileURL(entryURL, allowingReadAccessTo: readAccessURL)
        }
    }
}

private struct DropInServedAppWebView: NSViewRepresentable {
    let entryURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        context.coordinator.load(entryURL: entryURL, into: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.load(entryURL: entryURL, into: web)
    }

    final class Coordinator {
        private var loadedEntryURL: URL?

        func load(entryURL: URL, into web: WKWebView) {
            guard loadedEntryURL != entryURL else { return }
            loadedEntryURL = entryURL
            web.load(URLRequest(url: entryURL))
        }
    }
}
