// BrowserApp.swift — Quake4Mac
//
// An embedded web browser that runs ON the Quake panel (a real WKWebView, not Safari on the Mac).
// Touch‑only: device HID touches are bridged to the page — a tap follows links / clicks elements,
// a vertical drag scrolls. A thin top toolbar gives Back / Home / Reload. Starts on a bookmark
// "new tab" page (Web/browser-home.html).

import SwiftUI
import WebKit

final class BrowserState: ObservableObject {
    @Published var urlText: String = "Home"
}

struct BrowserAppView: View {
    @StateObject private var state = BrowserState()
    static let toolbarFrac: CGFloat = 0.14

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                toolbar(w: geo.size.width)
                    .frame(height: geo.size.height * Self.toolbarFrac)
                BrowserWebView(state: state, toolbarFrac: Self.toolbarFrac)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func toolbar(w: CGFloat) -> some View {
        HStack(spacing: w * 0.02) {
            Image(systemName: "chevron.left")
            Image(systemName: "house.fill")
            Spacer()
            Text(state.urlText).font(.system(size: 22, weight: .medium)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
            Spacer()
            Image(systemName: "arrow.clockwise")
        }
        .font(.system(size: 30, weight: .semibold))
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, w * 0.03)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.06))
    }
}

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var state: BrowserState
    let toolbarFrac: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(state: state, toolbarFrac: toolbarFrac) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let bridge = """
        window.__quakeTap = function(nx, ny){
          var x = nx*window.innerWidth, y = ny*window.innerHeight;
          var el = document.elementFromPoint(x, y); if(!el) return;
          var a = el.closest && el.closest('a[href]');
          if(a && a.href){ window.location.href = a.href; return; }
          ['mousedown','mouseup','click'].forEach(function(t){
            el.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,clientX:x,clientY:y,view:window}));
          });
        };
        window.__quakeScroll = function(dx, dy){ window.scrollBy(dx, dy); };
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: cfg)
        // A standard desktop Safari UA so sites serve their normal layout.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        context.coordinator.loadHome()

        let coord = context.coordinator
        ScreenTouchRouter.shared.install(owner: coord,
            began: { [weak coord] p in coord?.began(p) },
            moved: { [weak coord] p in coord?.moved(p) },
            ended: { [weak coord] in coord?.ended() })
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        ScreenTouchRouter.shared.release(owner: coordinator)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        let state: BrowserState
        let toolbarFrac: CGFloat
        private var start: CGPoint?
        private var last: CGPoint?

        init(state: BrowserState, toolbarFrac: CGFloat) { self.state = state; self.toolbarFrac = toolbarFrac }

        var homeURL: URL? { Bundle.main.url(forResource: "browser-home", withExtension: "html", subdirectory: "Web") }
        func loadHome() { if let u = homeURL { web?.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) } }

        // MARK: touch bridge
        func began(_ p: CGPoint) { start = p; last = p }
        func moved(_ p: CGPoint) {
            defer { last = p }
            guard let s = start, let l = last, let web = web, s.y >= toolbarFrac else { return }
            let dyNorm = (l.y - p.y) / (1 - toolbarFrac)          // finger up → page scrolls down
            let px = dyNorm * web.bounds.height
            if abs(px) > 0.5 { web.evaluateJavaScript("window.__quakeScroll && window.__quakeScroll(0, \(px));", completionHandler: nil) }
        }
        func ended() {
            defer { start = nil; last = nil }
            guard let s = start, let e = last, let web = web else { return }
            let moved = max(abs(e.x - s.x), abs(e.y - s.y))
            guard moved < 0.02 else { return }                    // a drag/scroll, not a tap
            if s.y < toolbarFrac {
                if s.x < 0.08 { web.goBack() }
                else if s.x < 0.16 { loadHome() }
                else if s.x > 0.92 { web.reload() }
            } else {
                let ny = (s.y - toolbarFrac) / (1 - toolbarFrac)
                web.evaluateJavaScript("window.__quakeTap && window.__quakeTap(\(s.x), \(ny));", completionHandler: nil)
            }
        }

        // MARK: nav delegate → update the toolbar URL label
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { updateLabel() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateLabel() }
        private func updateLabel() {
            guard let url = web?.url else { return }
            state.urlText = url.isFileURL ? "Home" : (url.host ?? url.absoluteString)
        }
    }
}
