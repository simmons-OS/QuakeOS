// HomeScreen.swift — Quake4Mac
//
// The OS layer's springboard home screen, shown on the panel at boot. A grid of app icons across
// the 1920×480 panel; tap an icon to open that app, swipe (or rotate the knob) to change home
// page, knob press to return home. Layout lives in HomeStore (a default for now; the Mac settings
// "Layout" section will edit it later).

import SwiftUI

// AppDest <-> string for persisting the launch target / last-open screen.
extension AppDest {
    var storageKey: String {
        switch self {
        case .macroPage(let n): return "macroPage:\(n)"
        case .panel(let p):     return "panel:\(p)"
        case .builtin(let b):   return "builtin:\(b)"
        }
    }
    init?(storageKey s: String) {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "macroPage": self = .macroPage(parts[1])
        case "panel":     self = .panel(parts[1])
        case "builtin":   self = .builtin(parts[1])
        default:          return nil
        }
    }
    /// User-facing name for pickers.
    var displayName: String {
        switch self {
        case .macroPage(let n): return n
        case .panel(let p):     return p == "monitor" ? "System Monitor" : p.capitalized
        case .builtin(let b):   return b.capitalized
        }
    }
}

struct HomeApp: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String      // SF Symbol
    var tint: Color
    var dest: AppDest
}

private struct HomeAppDTO: Codable {
    var title: String; var symbol: String; var tintHex: String; var dest: String
    init(_ a: HomeApp) { title = a.title; symbol = a.symbol; tintHex = a.tint.hexRGB; dest = a.dest.storageKey }
    func toApp() -> HomeApp { HomeApp(title: title, symbol: symbol, tint: Color(hexRGB: tintHex),
                                      dest: AppDest(storageKey: dest) ?? .builtin("settings")) }
}

final class HomeStore: ObservableObject {
    static let shared = HomeStore()
    @Published var pages: [[HomeApp]] { didSet { save() } }
    private static let key = "home.layout"

    private init() {
        if let d = UserDefaults.standard.data(forKey: HomeStore.key),
           let dto = try? JSONDecoder().decode([[HomeAppDTO]].self, from: d), !dto.isEmpty {
            pages = dto.map { $0.map { $0.toApp() } }
        } else {
            pages = HomeStore.defaultPages()
        }
    }
    private func save() {
        let dto = pages.map { $0.map { HomeAppDTO($0) } }
        if let d = try? JSONEncoder().encode(dto) { UserDefaults.standard.set(d, forKey: HomeStore.key) }
    }

    func app(page: Int, slot: Int) -> HomeApp? {
        guard pages.indices.contains(page), pages[page].indices.contains(slot) else { return nil }
        return pages[page][slot]
    }

    /// Every app available, for the launch-target picker.
    var allApps: [HomeApp] { pages.flatMap { $0 } }

    /// The home app matching a destination (for the app switcher's icon/label).
    func appFor(_ dest: AppDest) -> HomeApp? { allApps.first { $0.dest == dest } }

    // MARK: editing (used by the Mac-side Home Layout editor)
    func addPage() { pages.append([]) }
    func removePage(_ i: Int) { guard pages.count > 1, pages.indices.contains(i) else { return }; pages.remove(at: i) }
    func addApp(_ app: HomeApp, toPage i: Int) {
        guard pages.indices.contains(i) else { return }
        pages[i].append(HomeApp(title: app.title, symbol: app.symbol, tint: app.tint, dest: app.dest))
    }
    func insertApp(_ app: HomeApp, page i: Int, at k: Int) {
        guard pages.indices.contains(i) else { return }
        let idx = min(max(0, k), pages[i].count)
        pages[i].insert(HomeApp(title: app.title, symbol: app.symbol, tint: app.tint, dest: app.dest), at: idx)
    }
    func removeApp(page i: Int, at j: Int) { guard pages.indices.contains(i), pages[i].indices.contains(j) else { return }; pages[i].remove(at: j) }
    func moveApp(page i: Int, from j: Int, to k: Int) {
        guard pages.indices.contains(i), pages[i].indices.contains(j), k >= 0, k < pages[i].count else { return }
        let a = pages[i].remove(at: j); pages[i].insert(a, at: k)
    }

    /// Every app you can drop onto a home page (built-ins, panels, and your macro pages).
    static func catalog() -> [HomeApp] {
        var out: [HomeApp] = [
            HomeApp(title: "Clock",     symbol: "clock.fill",     tint: .orange, dest: .panel("clock")),
            HomeApp(title: "Music",     symbol: "music.note",     tint: .pink,   dest: .panel("music")),
            HomeApp(title: "Monitor",   symbol: "cpu",            tint: .green,  dest: .panel("monitor")),
            HomeApp(title: "Settings",  symbol: "gearshape.fill", tint: .gray,   dest: .builtin("settings")),
            HomeApp(title: "Wallpaper", symbol: "photo.fill",     tint: .blue,   dest: .builtin("wallpaper")),
            HomeApp(title: "Browser",   symbol: "globe",          tint: .purple, dest: .builtin("browser")),
        ]
        for p in PadStore.shared.pages { out.append(HomeApp(title: p.name, symbol: "square.grid.2x2.fill", tint: .teal, dest: .macroPage(p.name))) }
        return out
    }

    static func defaultPages() -> [[HomeApp]] {
        let osBasics: [HomeApp] = [
            HomeApp(title: "Clock",    symbol: "clock.fill",       tint: .orange, dest: .panel("clock")),
            HomeApp(title: "Settings", symbol: "gearshape.fill",   tint: .gray,   dest: .builtin("settings")),
            HomeApp(title: "Monitor",  symbol: "cpu",              tint: .green,  dest: .panel("monitor")),
            HomeApp(title: "Music",    symbol: "music.note",       tint: .pink,   dest: .panel("music")),
            HomeApp(title: "Wallpaper",symbol: "photo.fill",       tint: .blue,   dest: .builtin("wallpaper")),
            HomeApp(title: "Browser",  symbol: "globe",            tint: .purple, dest: .builtin("browser")),
        ]
        let yourPages: [HomeApp] = [
            HomeApp(title: "Apps",   symbol: "square.grid.2x2.fill", tint: .blue,  dest: .macroPage("Apps")),
            HomeApp(title: "System", symbol: "slider.horizontal.3",  tint: .gray,  dest: .macroPage("System")),
            HomeApp(title: "Web",    symbol: "network",              tint: .teal,  dest: .macroPage("Web")),
        ]
        return [osBasics, yourPages]
    }
}

// Shared layout fractions so the visual grid and PadModel's touch hit-testing agree exactly.
enum HomeLayoutMetrics {
    static let topFrac: CGFloat = 0.22      // status bar band (time / wifi / battery)
    static let bottomFrac: CGFloat = 0.13   // page-dots band
    static let sideFrac: CGFloat = 0.03
    static let cols = 8, rows = 2
}

struct HomeScreenView: View {
    @ObservedObject var store = HomeStore.shared
    let page: Int

    private let M = HomeLayoutMetrics.self

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let apps = store.pages.indices.contains(page) ? store.pages[page] : []
            let gridW = w * (1 - 2 * M.sideFrac)
            let gridH = h * (1 - M.topFrac - M.bottomFrac)
            let cellW = gridW / CGFloat(M.cols), cellH = gridH / CGFloat(M.rows)
            let size = min(cellW, cellH) * 0.56

            ZStack(alignment: .topLeading) {
                Color.clear

                statusBar(w: w)
                    .frame(width: w * (1 - 2 * M.sideFrac), height: h * M.topFrac)
                    .position(x: w / 2, y: h * M.topFrac / 2)

                VStack(spacing: 0) {
                    ForEach(0..<M.rows, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<M.cols, id: \.self) { c in
                                let idx = r * M.cols + c
                                Group {
                                    if idx < apps.count { iconCell(apps[idx], size: size) } else { Color.clear }
                                }
                                .frame(width: cellW, height: cellH)
                            }
                        }
                    }
                }
                .frame(width: gridW, height: gridH)
                .position(x: w / 2, y: h * M.topFrac + gridH / 2)

                dots.position(x: w / 2, y: h * (1 - M.bottomFrac / 2))
            }
            .frame(width: w, height: h)
        }
    }

    private func statusBar(w: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack {
                Text(timeString(ctx.date))
                    .font(.system(size: w * 0.016, weight: .semibold)).foregroundColor(.white)
                Spacer()
                HStack(spacing: w * 0.012) {
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                }
                .font(.system(size: w * 0.015, weight: .medium)).foregroundColor(.white.opacity(0.9))
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = ClockStore.shared.hour24 ? "HH:mm" : "h:mm"
        return f.string(from: d)
    }

    private func iconCell(_ app: HomeApp, size: CGFloat) -> some View {
        VStack(spacing: size * 0.14) {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(app.tint.opacity(0.92))
                .frame(width: size, height: size)
                .overlay(Image(systemName: app.symbol)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundColor(.white))
                .shadow(color: app.tint.opacity(0.5), radius: size * 0.12)
            Text(app.title)
                .font(.system(size: size * 0.2, weight: .medium))
                .foregroundColor(.white.opacity(0.9)).lineLimit(1)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var dots: some View {
        HStack(spacing: 10) {
            ForEach(0..<store.pages.count, id: \.self) { i in
                Circle().fill(i == page ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 9, height: 9)
            }
        }
    }
}

// iOS-style app switcher: recently-used apps as a horizontal carousel (most-recent on the right).
// Knob rotate scrubs the highlight, knob press / tap opens it.
struct AppSwitcherView: View {
    let recents: [AppDest]
    let index: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let cardW = h * 0.46, cardH = h * 0.6
            let step = cardW * 1.22
            let center = (CGFloat(recents.count - 1) / 2 - CGFloat(index)) * step
            ZStack {
                Color.black.opacity(0.84).ignoresSafeArea()
                Text("Recent apps")
                    .font(.system(size: h * 0.06, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, h * 0.06)
                HStack(spacing: step - cardW) {
                    ForEach(recents.indices, id: \.self) { i in
                        card(recents[i], focused: i == index, w: cardW, h: cardH)
                    }
                }
                .frame(width: w)
                .offset(x: center)
            }
            .frame(width: w, height: h)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: index)
        }
    }

    private func card(_ dest: AppDest, focused: Bool, w: CGFloat, h: CGFloat) -> some View {
        let app = HomeStore.shared.appFor(dest)
        let title = app?.title ?? dest.displayName
        let symbol = app?.symbol ?? "app.fill"
        let tint = app?.tint ?? .gray
        return VStack(spacing: w * 0.1) {
            RoundedRectangle(cornerRadius: w * 0.22, style: .continuous)
                .fill(tint.opacity(0.92)).frame(width: w * 0.6, height: w * 0.6)
                .overlay(Image(systemName: symbol).font(.system(size: w * 0.28, weight: .medium)).foregroundColor(.white))
            Text(title).font(.system(size: w * 0.13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
        }
        .frame(width: w, height: h)
        .background(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous).fill(Color.white.opacity(focused ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous).strokeBorder(focused ? Color.cyan : Color.clear, lineWidth: 3))
        .scaleEffect(focused ? 1.0 : 0.84)
        .opacity(focused ? 1 : 0.6)
    }
}

// MARK: - Home Layout editor (Mac settings → Layout)

struct HomeLayoutView: View {
    @ObservedObject private var store = HomeStore.shared
    @ObservedObject private var wp = WallpaperStore.shared
    @State private var editPage = 0

    private let cols = 8, rows = 2
    private let pvW: CGFloat = 820
    private var pvH: CGFloat { pvW / 4 }     // 1920×480 → 4:1
    private let lib = [GridItem(.adaptive(minimum: 86, maximum: 120), spacing: 12, alignment: .top)]

    private var wallpaperOptions: [(String, String)] {
        [("default", "Default (global)")] + WallpaperStore.options.map { ($0.id, $0.title) }
    }
    private var page: Int { min(editPage, max(0, store.pages.count - 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(title: "Layout",
                           subtitle: "Drag an app from the library onto your home screen. Arrows switch pages; drag an icon to the trash to remove it.")
            previewRow
            controlsRow
            NeonCard("Apps — drag onto the home screen above") {
                LazyVGrid(columns: lib, spacing: 12) {
                    ForEach(HomeStore.catalog()) { app in
                        libTile(app).draggable("lib:\(app.dest.storageKey)")
                    }
                }
                .padding(.vertical, 8)
            }
            trashZone
            Spacer()
        }
        .onChange(of: store.pages.count) { _ in if editPage > store.pages.count - 1 { editPage = max(0, store.pages.count - 1) } }
    }

    // MARK: live preview (drop target) + page arrows

    private var previewRow: some View {
        HStack(spacing: 14) {
            arrow("chevron.left", enabled: page > 0) { editPage = max(0, page - 1) }
            previewCanvas
            arrow("chevron.right", enabled: page < store.pages.count - 1) { editPage = min(store.pages.count - 1, page + 1) }
        }
        .frame(maxWidth: .infinity)
    }

    private func arrow(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                .foregroundColor(enabled ? NeonTheme.cyan : NeonTheme.textTertiary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(NeonTheme.panel)).overlay(Circle().strokeBorder(NeonTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain).disabled(!enabled)
    }

    private var previewCanvas: some View {
        let cellW = pvW / CGFloat(cols), cellH = pvH / CGFloat(rows)
        let size = min(cellW, cellH) * 0.52
        return ZStack {
            WallpaperView(id: wp.id(forPage: page))
            Color.black.opacity(0.25)
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<cols, id: \.self) { c in cell(r * cols + c, cellW: cellW, cellH: cellH, size: size) }
                    }
                }
            }
        }
        .frame(width: pvW, height: pvH)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func cell(_ k: Int, cellW: CGFloat, cellH: CGFloat, size: CGFloat) -> some View {
        let apps = store.pages.indices.contains(page) ? store.pages[page] : []
        let app = apps.indices.contains(k) ? apps[k] : nil
        ZStack {
            if let app { iconTile(app, size: size).draggable("idx:\(k)") }
        }
        .frame(width: cellW, height: cellH)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in handleDrop(items, cell: k) }
    }

    private func handleDrop(_ items: [String], cell k: Int) -> Bool {
        guard let s = items.first else { return false }
        let count = store.pages.indices.contains(page) ? store.pages[page].count : 0
        if s.hasPrefix("lib:") {
            let key = String(s.dropFirst(4))
            guard let a = HomeStore.catalog().first(where: { $0.dest.storageKey == key }) else { return false }
            store.insertApp(a, page: page, at: min(k, count)); return true
        } else if s.hasPrefix("idx:"), let j = Int(s.dropFirst(4)) {
            store.moveApp(page: page, from: j, to: min(k, max(0, count - 1))); return true
        }
        return false
    }

    // MARK: controls + library + trash

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Text("Page \(page + 1) of \(store.pages.count)").font(.system(size: 12)).foregroundColor(NeonTheme.textSecondary)
            HStack(spacing: 6) {
                ForEach(0..<store.pages.count, id: \.self) { i in
                    Circle().fill(i == page ? NeonTheme.cyan : Color.white.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            Spacer()
            Picker("", selection: wallpaperBinding(page)) {
                ForEach(wallpaperOptions, id: \.0) { Text($0.1).tag($0.0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 190)
            Button { store.addPage(); editPage = store.pages.count - 1 } label: {
                Label("Add page", systemImage: "plus").font(.system(size: 12, weight: .medium)).foregroundColor(NeonTheme.cyan)
            }.buttonStyle(.plain)
            if store.pages.count > 1 {
                Button { store.removePage(page); editPage = min(page, store.pages.count - 1) } label: {
                    Label("Remove page", systemImage: "trash").font(.system(size: 12)).foregroundColor(NeonTheme.magenta)
                }.buttonStyle(.plain)
            }
        }
    }

    private var trashZone: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash"); Text("Drag an app here to remove it").font(.system(size: 12))
        }
        .foregroundColor(NeonTheme.textTertiary)
        .frame(maxWidth: .infinity).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(NeonTheme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5])))
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, s.hasPrefix("idx:"), let j = Int(s.dropFirst(4)) else { return false }
            store.removeApp(page: page, at: j); return true
        }
    }

    private func iconTile(_ app: HomeApp, size: CGFloat) -> some View {
        VStack(spacing: size * 0.12) {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(app.tint.opacity(0.92))
                .frame(width: size, height: size)
                .overlay(Image(systemName: app.symbol).font(.system(size: size * 0.44, weight: .medium)).foregroundColor(.white))
            Text(app.title).font(.system(size: size * 0.2, weight: .medium)).foregroundColor(.white.opacity(0.9)).lineLimit(1)
        }
    }

    private func libTile(_ app: HomeApp) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(app.tint.opacity(0.92))
                .frame(width: 54, height: 54)
                .overlay(Image(systemName: app.symbol).font(.system(size: 24, weight: .medium)).foregroundColor(.white))
            Text(app.title).font(.system(size: 10, weight: .medium)).foregroundColor(NeonTheme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).frame(height: 92)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func wallpaperBinding(_ p: Int) -> Binding<String> {
        Binding(get: { wp.perPage[p] ?? "default" },
                set: { wp.setPage(p, $0 == "default" ? nil : $0) })
    }
}

// Placeholder for on-device apps not built yet (Settings / Wallpaper / Browser).
struct HomeBuiltinView: View {
    let title: String
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 14) {
                Image(systemName: "hammer.fill").font(.system(size: 40)).foregroundColor(.white.opacity(0.5))
                Text(title).font(.system(size: 34, weight: .semibold)).foregroundColor(.white)
                Text("Coming soon — press the knob to go home")
                    .font(.system(size: 18)).foregroundColor(.white.opacity(0.5))
            }
        }
    }
}
