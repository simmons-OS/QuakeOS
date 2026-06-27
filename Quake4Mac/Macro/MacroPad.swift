// MacroPad.swift — Quake4Mac (Phase 2)
//
// The actual shortcut pad: pages of glowing tiles laid out on the Quake's ultra-wide
// panel. Touch a tile to fire its action; turn the knob to flip pages; press the knob
// to jump home. Everything is data-driven (see PadModel.defaultPages) so it's easy to
// extend into a user-editable config later.

import SwiftUI
import AppKit
import Combine
import CryptoKit

// MARK: - Model

enum PadAction {
    case launchApp(bundleID: String)   // open an app by bundle identifier
    case openURL(String)               // open a URL in the default browser
    case openPath(String)              // open a local file or folder
    case shell(String)                 // run a shell command (/bin/zsh -lc)
    case appleScript(String)           // run an AppleScript snippet
    case system(SystemAction)          // invoke a built-in macOS system action
    case luminance(delta: Int)         // nudge the Quake panel backlight
    case openPage(String)              // jump to another Quake page (by name)
    case keyCombo(String)              // send a key combo to the focused app via System Events
    case typeText(String)              // type literal text into the focused app
    case pasteText(String)             // place text on the clipboard and paste it
    case counter(value: Int)           // persistent +/- tile counter
    case macro([MacroStep])            // run ordered macro steps without overlap
    case none
}

enum SystemAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case lockScreen
    case openSettings = "config"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lockScreen: return "Lock Screen"
        case .openSettings: return "Open Settings"
        }
    }

    var appleScriptSource: String? {
        switch self {
        case .lockScreen:
            return MacroKeyCombo.appleScriptSource(for: "control+command+q")
        case .openSettings:
            return nil
        }
    }
}

enum TileIcon: Codable, Hashable {
    case emoji(String)
    case imagePath(String)
    case imageURL(url: String, cachePath: String)

    private enum CodingKeys: String, CodingKey { case kind, value, cachePath }

    var isEmpty: Bool {
        switch self {
        case .emoji(let value), .imagePath(let value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .imageURL(let url, let cachePath):
            return url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || cachePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var nonEmpty: TileIcon? { isEmpty ? nil : self }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        let value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        switch kind {
        case "emoji": self = .emoji(value)
        case "image": self = .imagePath(value)
        case "url":
            let cachePath = try container.decodeIfPresent(String.self, forKey: .cachePath) ?? ""
            self = .imageURL(url: value, cachePath: cachePath)
        default: self = .emoji("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .emoji(let value):
            try container.encode("emoji", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .imagePath(let value):
            try container.encode("image", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .imageURL(let url, let cachePath):
            try container.encode("url", forKey: .kind)
            try container.encode(url, forKey: .value)
            try container.encode(cachePath, forKey: .cachePath)
        }
    }
}

enum TileIconCache {
    static let maxBytes = 3 * 1024 * 1024

    struct ImageInfo: Equatable {
        let fileExtension: String
        let mimeType: String
    }

    enum CacheError: LocalizedError {
        case invalidURL
        case unsupportedScheme
        case badStatus(Int)
        case tooLarge
        case unsupportedImage
        case missingCacheDirectory

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a valid image URL."
            case .unsupportedScheme: return "Image URLs must use http or https."
            case .badStatus(let status): return "The image request failed with HTTP \(status)."
            case .tooLarge: return "Image URLs are limited to 3 MB."
            case .unsupportedImage: return "The URL did not return a supported image."
            case .missingCacheDirectory: return "The icon cache folder could not be created."
            }
        }
    }

    static func imageInfo(from data: Data) -> ImageInfo? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return ImageInfo(fileExtension: "png", mimeType: "image/png")
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return ImageInfo(fileExtension: "jpg", mimeType: "image/jpeg")
        }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            return ImageInfo(fileExtension: "gif", mimeType: "image/gif")
        }
        if bytes.count >= 12,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return ImageInfo(fileExtension: "webp", mimeType: "image/webp")
        }
        if bytes.starts(with: [0x42, 0x4D]) {
            return ImageInfo(fileExtension: "bmp", mimeType: "image/bmp")
        }
        if bytes.starts(with: [0x00, 0x00, 0x01, 0x00]) {
            return ImageInfo(fileExtension: "ico", mimeType: "image/x-icon")
        }
        if let text = String(data: data.prefix(512), encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.hasPrefix("<svg") || (trimmed.hasPrefix("<?xml") && trimmed.contains("<svg")) {
                return ImageInfo(fileExtension: "svg", mimeType: "image/svg+xml")
            }
        }
        return nil
    }

    static func cacheFilename(for urlString: String, fileExtension: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(hash).\(fileExtension)"
    }

    static func cachedDataURL(path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
              let info = imageInfo(from: data) else { return nil }
        return "data:\(info.mimeType);base64,\(data.base64EncodedString())"
    }

    static func fetchIcon(from urlString: String) async throws -> TileIcon {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw CacheError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else { throw CacheError.unsupportedScheme }

        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CacheError.badStatus(http.statusCode)
        }

        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw CacheError.tooLarge }
        }
        guard let info = imageInfo(from: data) else { throw CacheError.unsupportedImage }

        guard let cacheDirectory else { throw CacheError.missingCacheDirectory }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let fileURL = cacheDirectory.appendingPathComponent(cacheFilename(for: trimmed, fileExtension: info.fileExtension))
        try data.write(to: fileURL, options: .atomic)
        return .imageURL(url: trimmed, cachePath: fileURL.path)
    }

    private static var cacheDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Quake4Mac", isDirectory: true)
            .appendingPathComponent("IconCache", isDirectory: true)
    }
}

enum MacroStepKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case key
    case text
    case pasteText
    case delay
    case app
    case url
    case openPath
    case shell
    case appleScript
    case lockScreen
    case openSettings
    case page
    case brightness

    var id: String { rawValue }

    var title: String {
        switch self {
        case .key: return "Keystroke"
        case .text: return "Type Text"
        case .pasteText: return "Paste Text"
        case .delay: return "Delay"
        case .app: return "Open App"
        case .url: return "Open URL"
        case .openPath: return "Open File/Folder"
        case .shell: return "Shell"
        case .appleScript: return "AppleScript"
        case .lockScreen: return "Lock Screen"
        case .openSettings: return "Open Settings"
        case .page: return "Go to Page"
        case .brightness: return "Brightness"
        }
    }
}

struct MacroStep: Identifiable, Codable, Hashable {
    private enum CodingKeys: String, CodingKey { case id, kind, value, intValue }

    var id: UUID = UUID()
    var kind: MacroStepKind = .delay
    var value: String = ""
    var intValue: Int = 250

    static let maxDelayMs = 60_000

    init(id: UUID = UUID(), kind: MacroStepKind = .delay, value: String = "", intValue: Int = 250) {
        self.id = id
        self.kind = kind
        self.value = value
        self.intValue = intValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(MacroStepKind.self, forKey: .kind) ?? .delay
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        intValue = try container.decodeIfPresent(Int.self, forKey: .intValue) ?? MacroStep.defaultStep(kind: kind).intValue
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    }

    static func defaultStep(kind: MacroStepKind = .delay) -> MacroStep {
        switch kind {
        case .delay:
            return MacroStep(kind: .delay, value: "", intValue: 250)
        case .brightness:
            return MacroStep(kind: .brightness, value: "", intValue: 26)
        default:
            return MacroStep(kind: kind, value: "", intValue: 0)
        }
    }

    var delayMilliseconds: Int {
        min(Self.maxDelayMs, max(0, intValue))
    }

    var padAction: PadAction? {
        switch kind {
        case .key: return .keyCombo(value)
        case .text: return .typeText(value)
        case .pasteText: return .pasteText(value)
        case .delay: return nil
        case .app: return .launchApp(bundleID: value)
        case .url: return .openURL(value)
        case .openPath: return .openPath(value)
        case .shell: return .shell(value)
        case .appleScript: return .appleScript(value)
        case .lockScreen: return .system(.lockScreen)
        case .openSettings: return .system(.openSettings)
        case .page: return .openPage(value)
        case .brightness: return .luminance(delta: intValue)
        }
    }
}

enum MacroKeyCombo {
    private static let modifierNames: [String: String] = [
        "command": "command down", "cmd": "command down", "meta": "command down", "win": "command down",
        "control": "control down", "ctrl": "control down",
        "option": "option down", "opt": "option down", "alt": "option down",
        "shift": "shift down"
    ]

    private static let keyCodes: [String: Int] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "page up": 116, "pagedown": 121, "page down": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    static func appleScriptSource(for combo: String) -> String? {
        let tokens = combo.split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var modifiers: [String] = []
        var key: String?
        for token in tokens {
            if let modifier = modifierNames[token] {
                if !modifiers.contains(modifier) { modifiers.append(modifier) }
            } else {
                key = token
            }
        }
        guard let key else { return nil }

        let usingClause = modifiers.isEmpty ? "" : " using {\(modifiers.joined(separator: ", "))}"
        if let code = keyCodes[key] {
            return "tell application \"System Events\" to key code \(code)\(usingClause)"
        }
        if key.count == 1 {
            return "tell application \"System Events\" to keystroke \"\(MacroText.escapedAppleScriptString(key))\"\(usingClause)"
        }
        return nil
    }
}

enum MacroText {
    static func escapedAppleScriptString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func appleScriptSource(for text: String) -> String {
        "tell application \"System Events\" to keystroke \"\(escapedAppleScriptString(text))\""
    }
}

// A page can be a tile grid (the default), a live web dashboard, or a bundled "app" screen
// (Clock, etc.). Keeps the "page = app" abstraction clean as we add open-quake / DK-Suite presets.
enum PadPageKind: Equatable {
    case grid                  // 8×2 tile grid (current behaviour)
    case web(url: String)      // full-screen web dashboard
    case app(id: String)       // a bundled renderer, keyed by id ("clock", …)
}

// What a home-screen app icon opens (the OS layer). Springboard home → tap an icon → open one
// of these fullscreen; knob press returns home.
enum AppDest: Equatable {
    case macroPage(String)     // one of the tile-grid pages, by name
    case panel(String)         // a built-in panel: "clock" | "music" | "monitor"
    case builtin(String)       // an on-device app: "settings" | "wallpaper" | "browser" (stubs for now)
    case dashboard(UUID)       // saved authenticated web dashboard
    case dropInApp(String)     // user-installed static drop-in panel app, by manifest id
}

struct Tile: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String          // SF Symbol fallback
    let tint: Color
    let action: PadAction
    var image: String? = nil    // DecoKee PNG glyph name (in bundle Icons/), used verbatim when set
    var editable: Bool = false  // false = built-in preset (Safari, Music, …) → action not editable
    var customIcon: TileIcon? = nil
    var columnSpan: Int = 1
    var rowSpan: Int = 1

    /// Bundle id when this tile launches an app — lets the tile show the real macOS app icon.
    var appBundleID: String? {
        if case let .launchApp(bid) = action { return bid }
        return nil
    }

    /// The URL when this tile opens a web page — lets the tile show the site's brand favicon.
    var openURLValue: String? {
        if case let .openURL(u) = action { return u }
        return nil
    }

    var macroStepCount: Int? {
        if case .macro(let steps) = action { return steps.count }
        return nil
    }

    var counterValue: Int? {
        if case .counter(let value) = action { return value }
        return nil
    }

    var allowsAutomaticWebIcon: Bool {
        customIcon == nil && image == nil
    }

    var normalizedColumnSpan: Int { max(1, min(PadModel.cols, columnSpan)) }
    var normalizedRowSpan: Int { max(1, min(PadModel.rows, rowSpan)) }

    var isEmpty: Bool { title.isEmpty }
}

struct PadPage: Identifiable {
    let id = UUID()
    var name: String
    var tiles: [Tile]
    var kind: PadPageKind = .grid

    func tile(at slot: Int) -> Tile? {
        guard tiles.indices.contains(slot) else { return nil }
        return tiles[slot]
    }

    func tileSpan(at owner: Int) -> (columns: Int, rows: Int) {
        guard let tile = tile(at: owner), !tile.isEmpty else { return (1, 1) }
        let col = owner % PadModel.cols
        let row = owner / PadModel.cols
        let columns = min(tile.normalizedColumnSpan, PadModel.cols - col)
        let rows = min(tile.normalizedRowSpan, PadModel.rows - row)
        return (max(1, columns), max(1, rows))
    }

    func ownerIndex(for slot: Int) -> Int? {
        guard slot >= 0, slot < PadModel.perPage else { return nil }
        let targetCol = slot % PadModel.cols
        let targetRow = slot / PadModel.cols
        for owner in 0..<min(tiles.count, PadModel.perPage) {
            guard let tile = tile(at: owner), !tile.isEmpty else { continue }
            let ownerCol = owner % PadModel.cols
            let ownerRow = owner / PadModel.cols
            let span = tileSpan(at: owner)
            guard span.columns > 1 || span.rows > 1 else { continue }
            if targetCol >= ownerCol, targetCol < ownerCol + span.columns,
               targetRow >= ownerRow, targetRow < ownerRow + span.rows {
                return owner
            }
        }
        if let tile = tile(at: slot), !tile.isEmpty { return slot }
        return nil
    }

    func isCoveredSlot(_ slot: Int) -> Bool {
        guard let owner = ownerIndex(for: slot) else { return false }
        return owner != slot
    }
}

final class PadModel: ObservableObject {
    static let cols = 8          // 8×2 on the 1920×480 panel → square cells (like DecoKee)
    static let rows = 2
    static let perPage = cols * rows

    @Published var pageIndex = 0
    @Published var pressedTileID: UUID? = nil
    @Published var lastFired: String = ""

    private unowned let input: QuakeInputReader
    private var storeSub: AnyCancellable?
    private var macroBusy = false

    /// Pages come from the shared, persisted store so the device, the settings preview, and the
    /// Tile Editor all stay in sync; edits there re-render the pad live.
    var pages: [PadPage] { PadStore.shared.pages }

    init(input: QuakeInputReader) {
        self.input = input
        storeSub = PadStore.shared.$pages.sink { [weak self] _ in self?.objectWillChange.send() }
        applyStartup()
    }

    var current: PadPage { pages[min(pageIndex, pages.count - 1)] }

    // Screens = the tile pages, then trailing "extra" widget screens (built-in panels).
    enum Extra: Equatable { case monitor, music, clock, weather }
    let extras: [Extra] = [.monitor, .music, .clock, .weather]

    var screenCount: Int { pages.count + extras.count }
    var isTilePage: Bool { pageIndex < pages.count }
    var extra: Extra? { isTilePage ? nil : extras[pageIndex - pages.count] }

    /// The kind of the current screen (grid for the trailing extras).
    var currentKind: PadPageKind { isTilePage ? current.kind : .grid }
    /// Only a grid page hit-tests tiles; web/app pages route raw touches to their screen view.
    var isGridPage: Bool { isTilePage && current.kind == .grid }
    /// True only when the open app is a macro tile-grid (so taps activate tiles). Panels and
    /// built-in apps route their touches to ScreenTouchRouter instead.
    var inMacroGrid: Bool { if case .macroPage = currentDest { return isGridPage }; return false }

    // MARK: OS navigation (springboard home + open apps)
    //
    // The device boots to a home screen of app icons. Tapping an icon opens that app fullscreen
    // (setting pageIndex so the existing renderers keep working); a knob press returns home. Which
    // screen we open at launch is a General setting (home / a specific app / last opened).

    @Published var onHome = true
    @Published var homePage = 0
    @Published var currentDest: AppDest? = nil
    @Published var recents: [AppDest] = []        // app history, most-recent LAST (rightmost in the switcher)
    private var homeStart: CGPoint?
    private var homeLast: CGPoint?
    private var switStart: CGPoint?
    private var switLast: CGPoint?
    private var switcherTimer: Timer?
    // Home edit ("jiggle") mode: hold an icon to enter, drag to rearrange, knob/tap-empty to exit.
    @Published var editMode = false
    @Published var draggingSlot: Int? = nil
    @Published var dragPoint: CGPoint? = nil
    private var longPressTimer: Timer?
    private var edgeTimer: Timer?
    private var edgeDir = 0

    func setHomePage(_ p: Int) { let n = max(1, HomeStore.shared.pages.count); homePage = min(max(0, p), n - 1) }
    private func rotateHomePage(_ delta: Int) {
        let n = max(1, HomeStore.shared.pages.count)
        homePage = (homePage + delta + n) % n
    }
    func goHome() { onHome = true; editMode = false; draggingSlot = nil; dragPoint = nil; saveLastNav() }

    func openApp(_ dest: AppDest) {
        switch dest {
        case .macroPage(let name): if let i = pages.firstIndex(where: { $0.name == name }) { pageIndex = i }
        case .panel(let id):
            let ex: Extra = id == "monitor" ? .monitor : id == "music" ? .music : id == "weather" ? .weather : .clock
            if let k = extras.firstIndex(of: ex) { pageIndex = pages.count + k }
        case .builtin, .dashboard, .dropInApp:
            break
        }
        currentDest = dest
        onHome = false
        switcherOpen = false
        editMode = false; draggingSlot = nil; dragPoint = nil
        switcherTimer?.invalidate()
        recents.removeAll { $0 == dest }            // move to most-recent (end)
        recents.append(dest)
        if recents.count > 8 { recents.removeFirst(recents.count - 8) }
        saveLastNav()
    }

    // MARK: App switcher (knob-driven recents carousel)
    private func openOrMoveSwitcher(_ d: Int) {
        guard !recents.isEmpty else { return }
        if !switcherOpen { switcherOpen = true; switcherIndex = recents.count - 1 }
        else { switcherIndex = min(max(0, switcherIndex + d), recents.count - 1) }
        resetSwitcherTimer()
    }
    private func commitSwitcher() {
        switcherTimer?.invalidate()
        guard recents.indices.contains(switcherIndex) else { switcherOpen = false; return }
        let d = recents[switcherIndex]
        switcherOpen = false
        openApp(d)
    }
    private func endSwitcherTouch() {
        defer { switStart = nil; switLast = nil }
        guard let s = switStart, let e = switLast else { return }
        let dx = e.x - s.x
        if abs(dx) > 0.12 {                          // swipe scrubs the carousel
            switcherIndex = min(max(0, switcherIndex + (dx < 0 ? 1 : -1)), recents.count - 1)
            resetSwitcherTimer()
        } else { commitSwitcher() }                  // tap opens the highlighted app
    }
    private func resetSwitcherTimer() {
        switcherTimer?.invalidate()
        switcherTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in self?.switcherOpen = false }
    }

    private func homeTouchEnded() {
        defer { homeStart = nil; homeLast = nil }
        guard let s = homeStart, let e = homeLast else { return }
        let dx = e.x - s.x
        if abs(dx) > 0.12 { setHomePage(homePage + (dx < 0 ? 1 : -1)); return }   // swipe → change page
        // Map the tap into the icon-grid region (same insets the home view lays out with).
        let M = HomeLayoutMetrics.self
        let gx = (s.x - M.sideFrac) / (1 - 2 * M.sideFrac)
        let gy = (s.y - M.topFrac) / (1 - M.topFrac - M.bottomFrac)
        guard gx >= 0, gx <= 1, gy >= 0, gy <= 1 else { return }
        let col = min(max(Int(gx * CGFloat(M.cols)), 0), M.cols - 1)
        let row = min(max(Int(gy * CGFloat(M.rows)), 0), M.rows - 1)
        if let app = HomeStore.shared.app(page: homePage, slot: row * M.cols + col) { openApp(app.dest) }
    }

    // MARK: Home edit ("jiggle") mode
    func exitEditMode() { editMode = false; draggingSlot = nil; dragPoint = nil; longPressTimer?.invalidate(); edgeTimer?.invalidate(); edgeDir = 0 }

    /// Carry the dragged icon to the adjacent page (creating one past the last page).
    private func performEdgeMove(_ dir: Int) {
        guard editMode, let from = draggingSlot else { return }
        let cur = homePage
        var target = cur + dir
        if target < 0 { edgeDir = 0; return }
        if target >= HomeStore.shared.pages.count {
            guard dir > 0 else { edgeDir = 0; return }
            HomeStore.shared.addPage(); target = HomeStore.shared.pages.count - 1
        }
        guard let app = HomeStore.shared.app(page: cur, slot: from) else { edgeDir = 0; return }
        HomeStore.shared.removeApp(page: cur, at: from)
        HomeStore.shared.addApp(app, toPage: target)
        homePage = target
        draggingSlot = max(0, HomeStore.shared.pages[target].count - 1)
        edgeDir = 0
    }

    /// Slot index under a normalized point, using the same grid insets the home view lays out with.
    private func homeSlot(at p: CGPoint) -> Int {
        let M = HomeLayoutMetrics.self
        let gx = (p.x - M.sideFrac) / (1 - 2 * M.sideFrac)
        let gy = (p.y - M.topFrac) / (1 - M.topFrac - M.bottomFrac)
        let col = min(max(Int(gx * CGFloat(M.cols)), 0), M.cols - 1)
        let row = min(max(Int(gy * CGFloat(M.rows)), 0), M.rows - 1)
        return row * M.cols + col
    }

    private func homeBegan(_ p: CGPoint) {
        homeStart = p; homeLast = p
        if editMode {
            let s = homeSlot(at: p)
            if HomeStore.shared.app(page: homePage, slot: s) != nil { draggingSlot = s; dragPoint = p }
        } else {
            longPressTimer?.invalidate()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in self?.beginEditDrag() }
        }
    }

    private func beginEditDrag() {
        guard onHome, let s = homeStart else { return }
        editMode = true
        let slot = homeSlot(at: s)
        if HomeStore.shared.app(page: homePage, slot: slot) != nil { draggingSlot = slot; dragPoint = s }
    }

    private func homeMoved(_ p: CGPoint) {
        homeLast = p
        if editMode {
            guard let cur = draggingSlot, HomeStore.shared.pages.indices.contains(homePage) else { return }
            dragPoint = p
            let n = HomeStore.shared.pages[homePage].count
            let target = min(homeSlot(at: p), max(0, n - 1))
            if target != cur { HomeStore.shared.moveApp(page: homePage, from: cur, to: target); draggingSlot = target }
            // Hold at the left/right edge → carry the icon to the adjacent page.
            if p.x < 0.05 || p.x > 0.95 {
                let dir = p.x < 0.05 ? -1 : 1
                if edgeDir != dir {
                    edgeDir = dir; edgeTimer?.invalidate()
                    edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.performEdgeMove(dir) }
                }
            } else { edgeDir = 0; edgeTimer?.invalidate() }
        } else if let s = homeStart, max(abs(p.x - s.x), abs(p.y - s.y)) > 0.03 {
            longPressTimer?.invalidate()       // moved → it's a swipe, not a hold
        }
    }

    private func homeEnded() {
        longPressTimer?.invalidate()
        edgeTimer?.invalidate(); edgeDir = 0
        if editMode {
            if draggingSlot != nil { draggingSlot = nil; dragPoint = nil }            // drop
            else if let s = homeStart, HomeStore.shared.app(page: homePage, slot: homeSlot(at: s)) == nil { exitEditMode() }  // tap empty → exit
            homeStart = nil; homeLast = nil
        } else {
            homeTouchEnded()
        }
    }

    /// Resolve the launch screen from the General "open at launch" setting.
    func applyStartup() {
        let target = UserDefaults.standard.string(forKey: "startup.target") ?? "home"
        switch target {
        case "home": onHome = true; homePage = 0
        case "last":
            if let key = UserDefaults.standard.string(forKey: "nav.last"), key != "home",
               let d = AppDest(storageKey: key) { openApp(d) } else { onHome = true }
        default:
            if let d = AppDest(storageKey: target) { openApp(d) } else { onHome = true }
        }
    }
    private func saveLastNav() {
        UserDefaults.standard.set(onHome ? "home" : (currentDest?.storageKey ?? "home"), forKey: "nav.last")
    }

    /// Names of every screen, in order, for the radial switcher.
    /// (Monitor screen is "Stats" so it doesn't collide with the "System" macro page.)
    var screenTitles: [String] { pages.map { $0.name } + ["Stats", "Music", "Clock", "Weather"] }

    /// Title of the current screen (matches `screenTitles`) — the key the reactive RGB "page theme"
    /// source uses to look up the colour the user picked for this page.
    var currentScreenTitle: String {
        if onHome { return "Home" }
        if case .dashboard(let id)? = currentDest { return DashboardStore.shared.dashboard(id: id)?.name ?? "Dashboard" }
        let t = screenTitles
        return t[min(max(0, pageIndex), t.count - 1)]
    }

    // Retained for the (currently unused) radial-switcher overlay; the knob now drives Home/app nav.
    @Published var switcherOpen = false
    @Published var switcherIndex = 0

    // MARK: Input handling (called from QuakeInputReader.onEvent, on the main run loop)
    //
    // Knob press = Home (like an iPhone home button). On Home: rotate or swipe changes home page,
    // tap opens an app. In an app: grid pages hit-test tiles; other panels route touches to their
    // screen view (scroll / clock-swipe).

    func handle(_ e: QuakeEvent) {
        switch e {
        case .knobClockwise:
            if switcherOpen { openOrMoveSwitcher(+1) }
            else if onHome { rotateHomePage(+1) }
            else { openOrMoveSwitcher(+1) }   // open / scrub the recents app switcher
        case .knobCounterClockwise:
            if switcherOpen { openOrMoveSwitcher(-1) }
            else if onHome { rotateHomePage(-1) }
            else { openOrMoveSwitcher(-1) }
        case .knobPress:
            if editMode { exitEditMode() }                  // exit jiggle mode (like iPhone home)
            else if switcherOpen { commitSwitcher() }       // open the highlighted app
            else if onHome { setHomePage(0) }
            else { goHome() }                               // home button
        case .touchBegan(let p):
            if switcherOpen { switStart = p; switLast = p }
            else if onHome { homeBegan(p) }
            else if inMacroGrid { activate(at: p) }
            else { ScreenTouchRouter.shared.onBegan?(p) }
        case .touchEnded:
            pressedTileID = nil
            if switcherOpen { endSwitcherTouch() }
            else if onHome { homeEnded() }
            else if !inMacroGrid { ScreenTouchRouter.shared.onEnded?() }
        case .touchMoved(let p):
            if switcherOpen { switLast = p }
            else if onHome { homeMoved(p) }
            else if !inMacroGrid { ScreenTouchRouter.shared.onMoved?(p) }
        }
    }

    private func activate(at p: CGPoint) {
        let col = min(max(Int(p.x * CGFloat(Self.cols)), 0), Self.cols - 1)
        let row = min(max(Int(p.y * CGFloat(Self.rows)), 0), Self.rows - 1)
        let rawIndex = row * Self.cols + col
        let idx = current.ownerIndex(for: rawIndex) ?? rawIndex
        guard idx < current.tiles.count else { return }
        let tile = current.tiles[idx]
        pressedTileID = tile.id
        lastFired = tile.title
        if case .counter = tile.action {
            let delta = Self.counterDelta(forNormalizedPoint: p, ownerIndex: idx, columnSpan: current.tileSpan(at: idx).columns)
            if let value = PadStore.shared.adjustCounter(page: pageIndex, slot: idx, delta: delta) {
                lastFired = "\(tile.title) \(value)"
            }
            releasePressedTile(tile.id)
            return
        }
        run(tile.action)
        releasePressedTile(tile.id)
    }

    private func releasePressedTile(_ tileID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            if self?.pressedTileID == tileID { self?.pressedTileID = nil }
        }
    }

    static func counterDelta(forNormalizedPoint p: CGPoint) -> Int {
        let owner = min(max(Int(p.x * CGFloat(cols)), 0), cols - 1)
        return counterDelta(forNormalizedPoint: p, ownerIndex: owner, columnSpan: 1)
    }

    static func counterDelta(forNormalizedPoint p: CGPoint, ownerIndex: Int, columnSpan: Int) -> Int {
        let span = max(1, min(cols, columnSpan))
        let ownerCol = min(max(ownerIndex % cols, 0), cols - 1)
        let scaledX = min(max(p.x * CGFloat(cols), CGFloat(ownerCol)), CGFloat(ownerCol + span).nextDown)
        let localX = scaledX - CGFloat(ownerCol)
        return localX < CGFloat(span) / 2 ? -1 : 1
    }

    // MARK: Action execution

    private func run(_ a: PadAction) {
        switch a {
        case .launchApp(let bid):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .openURL(let s):
            if let u = URL(string: s) { NSWorkspace.shared.open(u) }
        case .openPath(let path):
            let expanded = (path as NSString).expandingTildeInPath
            NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
        case .shell(let c):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", c]
            try? p.run()
        case .appleScript(let src):
            runAppleScript(src)
        case .system(let action):
            runSystemAction(action)
        case .luminance(let d):
            input.setLuminance(input.luminance + d)
        case .openPage(let name):
            if let i = pages.firstIndex(where: { $0.name == name }) { pageIndex = i }
        case .keyCombo(let combo):
            if let source = MacroKeyCombo.appleScriptSource(for: combo) { runAppleScript(source) }
        case .typeText(let text):
            runAppleScript(MacroText.appleScriptSource(for: text))
        case .pasteText(let text):
            pasteText(text)
        case .counter:
            break
        case .macro(let steps):
            runMacro(steps)
        case .none:
            break
        }
    }

    private func runAppleScript(_ source: String) {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
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

    // MARK: Default content (3 starter pages)

    static func defaultPages() -> [PadPage] {
        let apps = PadPage(name: "Apps", tiles: [
            Tile(title: "Safari",   symbol: "safari.fill",     tint: .blue,    action: .launchApp(bundleID: "com.apple.Safari")),
            Tile(title: "Mail",     symbol: "envelope.fill",   tint: .cyan,    action: .launchApp(bundleID: "com.apple.mail")),
            Tile(title: "Messages", symbol: "message.fill",    tint: .green,   action: .launchApp(bundleID: "com.apple.MobileSMS")),
            Tile(title: "Notes",    symbol: "note.text",       tint: .yellow,  action: .launchApp(bundleID: "com.apple.Notes")),
            Tile(title: "Music",    symbol: "music.note",      tint: .pink,    action: .launchApp(bundleID: "com.apple.Music")),
            Tile(title: "Calendar", symbol: "calendar",        tint: .red,     action: .launchApp(bundleID: "com.apple.iCal")),
            Tile(title: "Finder",   symbol: "folder.fill",     tint: .blue,    action: .launchApp(bundleID: "com.apple.finder")),
            Tile(title: "Terminal", symbol: "terminal.fill",   tint: .gray,    action: .launchApp(bundleID: "com.apple.Terminal")),
            Tile(title: "Photos",   symbol: "photo.fill",      tint: .orange,  action: .launchApp(bundleID: "com.apple.Photos")),
            Tile(title: "Settings", symbol: "gearshape.fill",  tint: .gray,    action: .launchApp(bundleID: "com.apple.systempreferences")),
            Tile(title: "Maps",     symbol: "map.fill",        tint: .green,   action: .launchApp(bundleID: "com.apple.Maps")),
            Tile(title: "FaceTime", symbol: "video.fill",      tint: .green,   action: .launchApp(bundleID: "com.apple.FaceTime")),
            Tile(title: "Reminders",symbol: "checklist",       tint: .orange,  action: .launchApp(bundleID: "com.apple.reminders")),
            Tile(title: "Calculator",symbol: "plusminus",      tint: .gray,    action: .launchApp(bundleID: "com.apple.calculator")),
            Tile(title: "App Store",symbol: "bag.fill",        tint: .blue,    action: .launchApp(bundleID: "com.apple.AppStore")),
            Tile(title: "Preview",  symbol: "doc.richtext",    tint: .blue,    action: .launchApp(bundleID: "com.apple.Preview")),
        ])

        // Force Quit = ⌘⌥Esc ; Spotlight = ⌘Space ; volume via AppleScript.
        let forceQuit = "tell application \"System Events\" to key code 53 using {command down, option down}"
        let spotlight = "tell application \"System Events\" to keystroke space using command down"
        let volUp = "set volume output volume ((output volume of (get volume settings)) + 12)"
        let volDown = "set volume output volume ((output volume of (get volume settings)) - 12)"
        let muteToggle = "set volume output muted (not (output muted of (get volume settings)))"

        // System page — uses DecoKee's OWN icon PNGs (image:) mapped to real macOS actions.
        let system = PadPage(name: "System", tiles: [
            Tile(title: "Screen +",   symbol: "sun.max.fill",   tint: .orange, action: .luminance(delta: 26),  image: "brightest"),
            Tile(title: "Screen –",   symbol: "sun.min.fill",   tint: .orange, action: .luminance(delta: -26), image: "darkest"),
            Tile(title: "Settings",   symbol: "gearshape.fill", tint: .gray,   action: .launchApp(bundleID: "com.apple.systempreferences"), image: "control_panel"),
            Tile(title: "Activity",   symbol: "cpu",            tint: .green,  action: .shell("open -a 'Activity Monitor'"), image: "cpu_info"),
            Tile(title: "Music",      symbol: "music.note",     tint: .pink,   action: .launchApp(bundleID: "com.apple.Music"), image: "media"),
            Tile(title: "Spotlight",  symbol: "magnifyingglass",tint: .blue,   action: .appleScript(spotlight), image: "global_search"),
            Tile(title: "Screenshot", symbol: "camera.viewfinder", tint: .teal, action: .shell("screencapture -i -c"), image: "clip_board"),
            Tile(title: "Downloads",  symbol: "folder.fill",    tint: .blue,   action: .shell("open ~/Downloads"), image: "folder"),
            Tile(title: "Force Quit", symbol: "xmark.octagon.fill", tint: .red, action: .appleScript(forceQuit), image: "force_quit"),
            Tile(title: "Sleep",      symbol: "moon.fill",      tint: .gray,   action: .shell("pmset displaysleepnow"), image: "lock_screen"),
            Tile(title: "Vol +",      symbol: "speaker.wave.3.fill", tint: .indigo, action: .appleScript(volUp)),
            Tile(title: "Vol –",      symbol: "speaker.wave.1.fill", tint: .indigo, action: .appleScript(volDown)),
            Tile(title: "Mute",       symbol: "speaker.slash.fill",  tint: .purple, action: .appleScript(muteToggle), image: "buzzer_off"),
            Tile(title: "Mission",    symbol: "rectangle.3.group.fill", tint: .teal, action: .shell("open -a 'Mission Control'")),
            Tile(title: "Buzzer",     symbol: "bell.fill",      tint: .yellow, action: .none, image: "buzzer"),
            Tile(title: "Mic",        symbol: "mic.fill",       tint: .purple, action: .none, image: "device_mic"),
        ])

        let web = PadPage(name: "Web", tiles: [
            Tile(title: "Google",  symbol: "magnifyingglass",  tint: .blue,   action: .openURL("https://www.google.com")),
            Tile(title: "YouTube", symbol: "play.rectangle.fill", tint: .red, action: .openURL("https://www.youtube.com")),
            Tile(title: "GitHub",  symbol: "chevron.left.forwardslash.chevron.right", tint: .gray, action: .openURL("https://github.com")),
            Tile(title: "Gmail",   symbol: "envelope.fill",    tint: .red,    action: .openURL("https://mail.google.com")),
            Tile(title: "ChatGPT", symbol: "bubble.left.fill", tint: .green,  action: .openURL("https://chat.openai.com"), image: "chatgpt"),
            Tile(title: "Maps",    symbol: "map.fill",         tint: .green,  action: .openURL("https://maps.google.com")),
            Tile(title: "Reddit",  symbol: "bubble.left.and.bubble.right.fill", tint: .orange, action: .openURL("https://www.reddit.com")),
            Tile(title: "X",       symbol: "xmark",            tint: .gray,   action: .openURL("https://x.com")),
            Tile(title: "Wikipedia",symbol: "book.fill",       tint: .gray,   action: .openURL("https://wikipedia.org")),
            Tile(title: "Amazon",  symbol: "cart.fill",        tint: .yellow, action: .openURL("https://www.amazon.com")),
            Tile(title: "Netflix", symbol: "play.tv.fill",     tint: .red,    action: .openURL("https://www.netflix.com")),
            Tile(title: "Spotify", symbol: "music.note",       tint: .green,  action: .openURL("https://open.spotify.com")),
            Tile(title: "Twitch",  symbol: "gamecontroller.fill", tint: .purple, action: .openURL("https://www.twitch.tv")),
            Tile(title: "LinkedIn",symbol: "person.2.fill",    tint: .blue,   action: .openURL("https://www.linkedin.com")),
            Tile(title: "Stack",   symbol: "square.stack.3d.up.fill", tint: .orange, action: .openURL("https://stackoverflow.com")),
            Tile(title: "Discord", symbol: "bubble.left.fill", tint: .indigo, action: .openURL("https://discord.com")),
        ])

        return [apps, system, web]
    }
}

// MARK: - Persisted, editable page store
//
// Single source of truth for the macro pages. The live pad (PadModel), the settings live-preview,
// and the Tile Editor all read this; edits persist to JSON in Application Support and publish live.

final class PadStore: ObservableObject {
    static let shared = PadStore()
    /// The COMMITTED pages — what the device shows and what's on disk. The Tile Editor works on a
    /// separate draft (TileEditSession) and only calls `replace` on Save, so the Quake never changes
    /// until you explicitly save.
    @Published var pages: [PadPage]
    /// Bumped on every commit so the device renderer knows to re-push.
    @Published var version = 0

    private init() {
        pages = PadStore.load() ?? PadModel.defaultPages()
        // Clock moved to a built-in panel — strip any old Clock page seeded into pages.json.
        let before = pages.count
        pages.removeAll { if case .app("clock") = $0.kind { return true }; return false }
        if pages.count != before { save() }
    }

    /// Commit a whole new set of pages (the editor's saved draft) → device + disk.
    func replace(_ newPages: [PadPage]) {
        pages = newPages
        version += 1
        save()
    }

    /// Replace the tile in a slot (nil = clear to an empty slot). Pads the row if needed.
    func setTile(page: Int, slot: Int, _ tile: Tile?) {
        guard pages.indices.contains(page), slot >= 0, slot < PadModel.perPage else { return }
        var tiles = pages[page].tiles
        while tiles.count <= slot { tiles.append(PadStore.emptyTile) }
        tiles[slot] = tile ?? PadStore.emptyTile
        pages[page].tiles = tiles
        save()
    }

    func renamePage(_ page: Int, to name: String) {
        guard pages.indices.contains(page) else { return }
        pages[page].name = name
        save()
    }

    @discardableResult
    func adjustCounter(page: Int, slot: Int, delta: Int) -> Int? {
        guard pages.indices.contains(page), slot >= 0, slot < PadModel.perPage else { return nil }
        var tiles = pages[page].tiles
        guard tiles.indices.contains(slot), case .counter(let value) = tiles[slot].action else { return nil }
        let next = value + delta
        let tile = tiles[slot]
        tiles[slot] = Tile(title: tile.title, symbol: tile.symbol, tint: tile.tint, action: .counter(value: next),
                           image: tile.image, editable: tile.editable, customIcon: tile.customIcon,
                           columnSpan: tile.columnSpan, rowSpan: tile.rowSpan)
        pages[page].tiles = tiles
        version += 1
        save()
        return next
    }

    static let emptyTile = Tile(title: "", symbol: "square.dashed", tint: .gray, action: .none)

    // MARK: Persistence (JSON in Application Support/Quake4Mac/pages.json)
    private static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
                   ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Quake4Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pages.json")
    }
    func save() {
        if let data = try? JSONEncoder().encode(pages.map(PageDTO.init)) {
            try? data.write(to: PadStore.fileURL)
        }
    }
    private static func load() -> [PadPage]? {
        guard let data = try? Data(contentsOf: fileURL),
              let dto = try? JSONDecoder().decode([PageDTO].self, from: data) else { return nil }
        return dto.map { $0.toPage() }
    }
}

// MARK: - Codable DTOs (Color → hex, PadAction flattened)

private struct ActionDTO: Codable {
    var kind: String; var s: String?; var i: Int?; var steps: [MacroStep]?
    init(_ a: PadAction) {
        switch a {
        case .launchApp(let b):   kind = "app";     s = b
        case .openURL(let u):     kind = "url";     s = u
        case .openPath(let p):    kind = "open";    s = p
        case .shell(let c):       kind = "shell";   s = c
        case .appleScript(let x): kind = "ascript"; s = x
        case .system(let action): kind = "system";  s = action.rawValue
        case .luminance(let d):   kind = "lum";     i = d
        case .openPage(let n):    kind = "page";    s = n
        case .keyCombo(let k):    kind = "key";     s = k
        case .typeText(let t):    kind = "text";    s = t
        case .pasteText(let t):   kind = "paste";   s = t
        case .counter(let value): kind = "counter"; i = value
        case .macro(let m):       kind = "macro";   steps = m
        case .none:               kind = "none"
        }
    }
    var action: PadAction {
        switch kind {
        case "app":     return .launchApp(bundleID: s ?? "")
        case "url":     return .openURL(s ?? "")
        case "open":    return .openPath(s ?? "")
        case "shell":   return .shell(s ?? "")
        case "ascript": return .appleScript(s ?? "")
        case "system":  return .system(SystemAction(rawValue: s ?? "") ?? .lockScreen)
        case "lum":     return .luminance(delta: i ?? 0)
        case "page":    return .openPage(s ?? "")
        case "key":     return .keyCombo(s ?? "")
        case "text":    return .typeText(s ?? "")
        case "paste":   return .pasteText(s ?? "")
        case "counter": return .counter(value: i ?? 0)
        case "macro":   return .macro(steps ?? [])
        default:        return .none
        }
    }
}
private struct TileDTO: Codable {
    var title: String; var symbol: String; var tintHex: String; var image: String?; var action: ActionDTO; var customIcon: TileIcon?
    var editable: Bool?     // optional → old pages.json (without it) still decodes (defaults to preset)
    var w: Int?
    var h: Int?
    init(_ t: Tile) {
        title = t.title; symbol = t.symbol; tintHex = t.tint.hexRGB; image = t.image
        action = ActionDTO(t.action); editable = t.editable; customIcon = t.customIcon
        w = t.normalizedColumnSpan > 1 ? t.normalizedColumnSpan : nil
        h = t.normalizedRowSpan > 1 ? t.normalizedRowSpan : nil
    }
    func toTile() -> Tile {
        Tile(title: title, symbol: symbol, tint: Color(hexRGB: tintHex), action: action.action,
             image: image, editable: editable ?? false, customIcon: customIcon?.nonEmpty,
             columnSpan: w ?? 1, rowSpan: h ?? 1)
    }
}
private struct PageDTO: Codable {
    var name: String; var tiles: [TileDTO]
    var kind: String?; var kindArg: String?   // optional → old pages.json decodes as .grid
    init(_ p: PadPage) {
        name = p.name; tiles = p.tiles.map(TileDTO.init)
        switch p.kind {
        case .grid:            kind = "grid"
        case .web(let url):    kind = "web";  kindArg = url
        case .app(let id):     kind = "app";  kindArg = id
        }
    }
    func toPage() -> PadPage {
        let k: PadPageKind
        switch kind {
        case "web": k = .web(url: kindArg ?? "")
        case "app": k = .app(id: kindArg ?? "")
        default:    k = .grid
        }
        return PadPage(name: name, tiles: tiles.map { $0.toTile() }, kind: k)
    }
}

// MARK: - Color <-> "#RRGGBB" (via deviceRGB)

// MARK: - Tile-editor draft session
//
// The editor edits a DRAFT copy of the pages (shown 1:1 in the live preview). The Quake and disk
// only change when the user hits Save (commit → PadStore.replace). Revert drops the draft back to
// the committed state.

final class TileEditSession: ObservableObject {
    static let shared = TileEditSession()
    @Published var draft: [PadPage]
    @Published var dirty = false
    @Published var selectedSlot: Int? = nil      // strip slot being edited in the inspector
    @Published var selectedSpec: TileSpec? = nil // library tile being inspected (read-only)

    private init() { draft = PadStore.shared.pages }

    func index(ofPage name: String) -> Int? { draft.firstIndex { $0.name == name } }

    /// Select a placed strip slot (clears any library inspection).
    func select(_ slot: Int?) { selectedSlot = slot; if slot != nil { selectedSpec = nil } }

    /// Inspect a library tile read-only (clears any strip selection).
    func inspect(_ spec: TileSpec?) { selectedSpec = spec; if spec != nil { selectedSlot = nil } }

    /// True when the inspector rail should be visible.
    var hasSelection: Bool { selectedSlot != nil || selectedSpec != nil }

    /// The non-empty tile at a slot, or nil.
    func tile(page: Int, slot: Int) -> Tile? {
        guard draft.indices.contains(page) else { return nil }
        let owner = draft[page].ownerIndex(for: slot) ?? slot
        guard draft[page].tiles.indices.contains(owner) else { return nil }
        let t = draft[page].tiles[owner]
        return t.title.isEmpty ? nil : t
    }

    func spanBounds(page: Int, slot: Int) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        guard draft.indices.contains(page), slot >= 0, slot < PadModel.perPage else {
            return (1...1, 1...1)
        }
        let owner = draft[page].ownerIndex(for: slot) ?? slot
        let column = owner % PadModel.cols
        let row = owner / PadModel.cols
        return (1...max(1, PadModel.cols - column), 1...max(1, PadModel.rows - row))
    }

    func setSpan(page: Int, slot: Int, columns: Int, rows: Int) {
        guard draft.indices.contains(page),
              let owner = normalizedOwner(page: page, slot: slot),
              let t0 = tile(page: page, slot: owner) else { return }
        let bounds = spanBounds(page: page, slot: owner)
        let columnSpan = min(max(columns, bounds.columns.lowerBound), bounds.columns.upperBound)
        let rowSpan = min(max(rows, bounds.rows.lowerBound), bounds.rows.upperBound)
        setTile(page: page, slot: owner, Tile(title: t0.title, symbol: t0.symbol, tint: t0.tint, action: t0.action,
                                             image: t0.image, editable: t0.editable, customIcon: t0.customIcon,
                                             columnSpan: columnSpan, rowSpan: rowSpan))
    }

    /// Edit a placed tile's title + action, keeping its glyph/tint.
    func setTitleAction(page: Int, slot: Int, title: String, action: PadAction) {
        guard let t0 = tile(page: page, slot: slot) else { return }
        setTile(page: page, slot: slot, Tile(title: title, symbol: t0.symbol, tint: t0.tint, action: action,
                                             image: t0.image, editable: t0.editable, customIcon: t0.customIcon,
                                             columnSpan: t0.columnSpan, rowSpan: t0.rowSpan))
    }

    func setCustomIcon(page: Int, slot: Int, customIcon: TileIcon?) {
        guard let t0 = tile(page: page, slot: slot) else { return }
        setTile(page: page, slot: slot, Tile(title: t0.title, symbol: t0.symbol, tint: t0.tint, action: t0.action,
                                             image: t0.image, editable: t0.editable, customIcon: customIcon?.nonEmpty,
                                             columnSpan: t0.columnSpan, rowSpan: t0.rowSpan))
    }

    func remove(page: Int, slot: Int) {
        setTile(page: page, slot: slot, nil)
        if selectedSlot == slot { selectedSlot = nil }
    }

    func setTile(page: Int, slot: Int, _ tile: Tile?) {
        guard draft.indices.contains(page),
              let owner = normalizedOwner(page: page, slot: slot) else { return }
        var tiles = draft[page].tiles
        while tiles.count < PadModel.perPage { tiles.append(PadStore.emptyTile) }
        let currentPage = PadPage(name: draft[page].name, tiles: tiles, kind: draft[page].kind)
        clearSpanSlots(owner: owner, span: currentPage.tileSpan(at: owner), in: &tiles)
        if let tile {
            let bounds = spanBounds(page: page, slot: owner)
            let columnSpan = min(max(tile.columnSpan, bounds.columns.lowerBound), bounds.columns.upperBound)
            let rowSpan = min(max(tile.rowSpan, bounds.rows.lowerBound), bounds.rows.upperBound)
            tiles[owner] = Tile(title: tile.title, symbol: tile.symbol, tint: tile.tint, action: tile.action,
                                image: tile.image, editable: tile.editable, customIcon: tile.customIcon,
                                columnSpan: columnSpan, rowSpan: rowSpan)
            clearSpanSlots(owner: owner, span: (columnSpan, rowSpan), in: &tiles, keepingOwner: true)
        } else {
            tiles[owner] = PadStore.emptyTile
        }
        draft[page].tiles = tiles
        if selectedSlot == slot, owner != slot { selectedSlot = owner }
        dirty = true
    }

    private func normalizedOwner(page: Int, slot: Int) -> Int? {
        guard draft.indices.contains(page), slot >= 0, slot < PadModel.perPage else { return nil }
        return draft[page].ownerIndex(for: slot) ?? slot
    }

    private func clearSpanSlots(owner: Int, span: (columns: Int, rows: Int), in tiles: inout [Tile], keepingOwner: Bool = false) {
        let ownerColumn = owner % PadModel.cols
        let ownerRow = owner / PadModel.cols
        let columns = max(1, min(span.columns, PadModel.cols - ownerColumn))
        let rows = max(1, min(span.rows, PadModel.rows - ownerRow))
        for rowOffset in 0..<rows {
            for columnOffset in 0..<columns {
                let index = owner + rowOffset * PadModel.cols + columnOffset
                guard tiles.indices.contains(index), !(keepingOwner && index == owner) else { continue }
                tiles[index] = PadStore.emptyTile
            }
        }
    }

    /// Commit the draft → device + disk.
    func save() { PadStore.shared.replace(draft); dirty = false }

    /// Throw away unsaved edits, returning to what the device currently shows.
    func revert() { draft = PadStore.shared.pages; dirty = false }
}

// MARK: - Color <-> "#RRGGBB" (via deviceRGB)

extension Color {
    var hexRGB: String {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.gray
        let r = Int((ns.redComponent   * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
    init(hexRGB: String) {
        let hex = hexRGB.hasPrefix("#") ? String(hexRGB.dropFirst()) : hexRGB
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self = Color(red:   Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8)  & 0xff) / 255,
                     blue:  Double(v & 0xff) / 255)
    }
}
