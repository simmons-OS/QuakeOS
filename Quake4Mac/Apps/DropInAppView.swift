import AppKit
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
                appRuntime(app) {
                    DropInStaticAppWebView(entryURL: url, readAccessURL: app.rootURL)
                }
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
            appRuntime(app) {
                DropInServedAppWebView(entryURL: url)
                    .onAppear { loopback.start() }
            }
        } else if !loopback.lastError.isEmpty {
            DashboardFallbackView(title: "Served App Failed", detail: loopback.lastError)
                .onAppear { loopback.start() }
        } else {
            DashboardFallbackView(title: "Starting Served App", detail: app.manifest.name)
                .onAppear { loopback.start() }
        }
    }

    @ViewBuilder private func appRuntime<Content: View>(_ app: DropInAppRecord,
                                                        @ViewBuilder content: () -> Content) -> some View {
        if let grid = app.manifest.grid {
            let tiles = grid.nativeTiles()
            if tiles.contains(where: { !$0.isEmpty }) {
                DropInGridRuntimeView(appID: app.id, grid: grid, tiles: tiles, store: store, content: content)
                    .ignoresSafeArea()
            } else {
                content()
            }
        } else {
            content()
        }
    }
}

struct DropInGridTileFrame: Identifiable {
    let id: Int
    let tile: Tile
    let column: Int
    let row: Int
    let columnSpan: Int
    let rowSpan: Int
}

enum DropInGridTileLayout {
    static func frames(for tiles: [Tile], columns: Int, rows: Int) -> [DropInGridTileFrame] {
        let columns = max(1, columns)
        let rows = max(1, rows)
        let totalSlots = columns * rows
        var covered = Set<Int>()
        var frames: [DropInGridTileFrame] = []

        for index in 0..<min(tiles.count, totalSlots) {
            guard !covered.contains(index) else { continue }
            let tile = tiles[index]
            let column = index % columns
            let row = index / columns
            let columnSpan = min(max(1, tile.columnSpan), columns - column)
            let rowSpan = min(max(1, tile.rowSpan), rows - row)
            frames.append(DropInGridTileFrame(id: index,
                                              tile: tile,
                                              column: column,
                                              row: row,
                                              columnSpan: columnSpan,
                                              rowSpan: rowSpan))

            guard !tile.isEmpty else { continue }
            for coveredRow in row..<(row + rowSpan) {
                for coveredColumn in column..<(column + columnSpan) {
                    covered.insert(coveredRow * columns + coveredColumn)
                }
            }
        }

        return frames
    }
}

private struct DropInGridRuntimeView<Content: View>: View {
    let appID: String
    let grid: DropInAppGridConfig
    let tiles: [Tile]
    @ObservedObject var store: DropInAppStore
    let content: Content
    @StateObject private var actionRunner = DropInTileActionRunner()

    init(appID: String,
         grid: DropInAppGridConfig,
         tiles: [Tile],
         store: DropInAppStore,
         @ViewBuilder content: () -> Content) {
        self.appID = appID
        self.grid = grid
        self.tiles = tiles
        self.store = store
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let columns = displayColumns
            let rows = displayRows
            let stripWidth = min(geo.size.width * 0.58, CGFloat(columns) * max(72, geo.size.height / CGFloat(rows)))

            HStack(spacing: 0) {
                content
                DropInGridActionStripView(appID: appID,
                                          tiles: Array(tiles.prefix(columns * rows)),
                                          columns: columns,
                                          rows: rows,
                                          store: store,
                                          actionRunner: actionRunner)
                    .frame(width: stripWidth)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var displayColumns: Int {
        max(1, min(3, grid.cols))
    }

    private var displayRows: Int {
        max(1, min(6, grid.rows))
    }
}

private struct DropInGridActionStripView: View {
    let appID: String
    let tiles: [Tile]
    let columns: Int
    let rows: Int
    @ObservedObject var store: DropInAppStore
    @ObservedObject var actionRunner: DropInTileActionRunner

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 10
            let cellWidth = (geo.size.width - gap * CGFloat(max(0, columns - 1))) / CGFloat(columns)
            let cellHeight = (geo.size.height - gap * CGFloat(max(0, rows - 1))) / CGFloat(rows)

            ZStack(alignment: .topLeading) {
                ForEach(DropInGridTileLayout.frames(for: tiles, columns: columns, rows: rows)) { frame in
                    let width = cellWidth * CGFloat(frame.columnSpan) + gap * CGFloat(max(0, frame.columnSpan - 1))
                    let height = cellHeight * CGFloat(frame.rowSpan) + gap * CGFloat(max(0, frame.rowSpan - 1))
                    DropInGridTileButton(appID: appID,
                                         slot: frame.id,
                                         tile: frame.tile,
                                         store: store,
                                         actionRunner: actionRunner)
                        .frame(width: width, height: height)
                        .position(x: CGFloat(frame.column) * (cellWidth + gap) + width / 2,
                                  y: CGFloat(frame.row) * (cellHeight + gap) + height / 2)
                }
            }
        }
        .padding(10)
        .background(
            LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.14),
                                    Color(red: 0.01, green: 0.02, blue: 0.04)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
        )
    }
}

private struct DropInGridTileButton: View {
    let appID: String
    let slot: Int
    let tile: Tile
    @ObservedObject var store: DropInAppStore
    @ObservedObject var actionRunner: DropInTileActionRunner

    var body: some View {
        if tile.isEmpty {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        } else if let defaultValue = tile.counterValue {
            DropInGridCounterTile(appID: appID,
                                  slot: slot,
                                  tile: tile,
                                  defaultValue: defaultValue,
                                  store: store)
        } else {
            Button { actionRunner.run(tile.action) } label: {
                VStack(spacing: 8) {
                    TileGlyphView(symbol: tile.symbol,
                                  image: tile.image,
                                  tint: tile.tint,
                                  appBundleID: tile.appBundleID,
                                  url: tile.openURLValue,
                                  size: 64,
                                  customIcon: tile.customIcon)
                    Text(tile.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.86))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.65)
                    if let value = tile.counterValue {
                        Text("\(value)")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(tile.tint.opacity(0.38), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct DropInGridCounterTile: View {
    let appID: String
    let slot: Int
    let tile: Tile
    let defaultValue: Int
    @ObservedObject var store: DropInAppStore

    private var value: Int {
        store.counterValue(appID: appID, slot: slot, defaultValue: defaultValue)
    }

    var body: some View {
        HStack(spacing: 0) {
            counterButton(symbol: "minus") {
                store.adjustCounter(appID: appID, slot: slot, defaultValue: defaultValue, delta: -1)
            }
            VStack(spacing: 6) {
                TileGlyphView(symbol: tile.symbol,
                              image: tile.image,
                              tint: tile.tint,
                              appBundleID: tile.appBundleID,
                              url: tile.openURLValue,
                              size: 52,
                              customIcon: tile.customIcon)
                Text(tile.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.80))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.65)
                Text("\(value)")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            counterButton(symbol: "plus") {
                store.adjustCounter(appID: appID, slot: slot, defaultValue: defaultValue, delta: 1)
            }
        }
        .background(
            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tile.tint.opacity(0.38), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func counterButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white.opacity(0.82))
                .frame(width: 34)
                .frame(maxHeight: .infinity)
                .background(Color.white.opacity(0.07))
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private final class DropInTileActionRunner: ObservableObject {
    private var macroBusy = false

    func run(_ action: PadAction) {
        switch action {
        case .launchApp(let bundleID):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .openURL(let value):
            if let url = URL(string: value) { NSWorkspace.shared.open(url) }
        case .openPath(let path):
            let expanded = (path as NSString).expandingTildeInPath
            NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
        case .shell(let command):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            try? process.run()
        case .appleScript(let source):
            runAppleScript(source)
        case .system(let action):
            runSystemAction(action)
        case .luminance(let delta):
            NotificationCenter.default.post(name: .quakeAdjustLuminanceRequested, object: delta)
        case .openPage(let name):
            NotificationCenter.default.post(name: .quakeOpenPageRequested, object: name)
        case .keyCombo(let combo):
            if let source = MacroKeyCombo.appleScriptSource(for: combo) { runAppleScript(source) }
        case .typeText(let text):
            runAppleScript(MacroText.appleScriptSource(for: text))
        case .pasteText(let text):
            pasteText(text)
        case .macro(let steps):
            runMacro(steps)
        case .counter, .none:
            break
        }
    }

    private func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private func runSystemAction(_ action: SystemAction) {
        switch action {
        case .lockScreen:
            if let source = action.appleScriptSource { runAppleScript(source) }
        case .openSettings:
            NotificationCenter.default.post(name: .quakeOpenSettingsRequested, object: nil)
        }
    }

    private func pasteText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let source = MacroKeyCombo.appleScriptSource(for: "command+v") {
            runAppleScript(source)
        }
    }

    private func runMacro(_ steps: [MacroStep]) {
        guard !macroBusy else { return }
        macroBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { macroBusy = false }
            for step in steps {
                if step.kind == .delay {
                    try? await Task.sleep(nanoseconds: UInt64(step.delayMilliseconds) * 1_000_000)
                } else if let action = step.padAction {
                    run(action)
                }
            }
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
