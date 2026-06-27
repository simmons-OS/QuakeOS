import SwiftUI
import WebKit

struct DropInStaticAppScreenView: View {
    let appID: String
    @ObservedObject private var store = DropInAppStore.shared

    var body: some View {
        if let app = store.app(id: appID) {
            if app.manifest.served {
                DashboardFallbackView(title: "Served App Not Available",
                                      detail: "\(app.manifest.name) needs the loopback runtime coming in a later release.")
            } else if let url = store.staticLaunchURL(for: app) {
                DropInStaticAppWebView(entryURL: url, readAccessURL: app.rootURL)
            } else {
                DashboardFallbackView(title: "Invalid App Entry", detail: app.manifest.entry)
            }
        } else {
            DashboardFallbackView(title: "App Missing", detail: "Open Settings to refresh drop-in apps.")
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
