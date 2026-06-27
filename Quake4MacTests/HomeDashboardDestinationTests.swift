import XCTest
import AppKit
@testable import Quake4Mac

final class HomeDashboardDestinationTests: XCTestCase {
    func testDashboardDestinationRoundTripsThroughStorageKey() throws {
        let id = UUID()
        let destination = AppDest.dashboard(id)

        XCTAssertEqual(AppDest(storageKey: destination.storageKey), destination)
    }

    func testInvalidDashboardDestinationKeyFails() {
        XCTAssertNil(AppDest(storageKey: "dashboard:not-a-uuid"))
    }

    func testDropInAppDestinationRoundTripsThroughStorageKey() throws {
        let destination = AppDest.dropInApp("clock")

        XCTAssertEqual(AppDest(storageKey: destination.storageKey), destination)
    }

    func testInvalidDropInAppDestinationKeyFails() {
        XCTAssertNil(AppDest(storageKey: "dropInApp:Bad App"))
    }
}

final class MacroActionTests: XCTestCase {
    func testMacroStepDelayIsClamped() {
        let step = MacroStep(kind: .delay, value: "", intValue: 100_000)

        XCTAssertEqual(step.delayMilliseconds, MacroStep.maxDelayMs)
    }

    func testMacroStepMapsURLToPadAction() {
        let step = MacroStep(kind: .url, value: "https://example.com", intValue: 0)

        guard case .openURL(let url)? = step.padAction else {
            return XCTFail("Expected URL pad action")
        }
        XCTAssertEqual(url, "https://example.com")
    }

    func testMacroStepMapsAppToPadAction() {
        let step = MacroStep(kind: .app, value: "com.apple.Safari", intValue: 0)

        guard case .launchApp(let bundleID)? = step.padAction else {
            return XCTFail("Expected app launch action")
        }
        XCTAssertEqual(bundleID, "com.apple.Safari")
    }

    func testMacroStepMapsOpenPathToPadAction() {
        let step = MacroStep(kind: .openPath, value: "~/Downloads", intValue: 0)

        guard case .openPath(let path)? = step.padAction else {
            return XCTFail("Expected open path action")
        }
        XCTAssertEqual(path, "~/Downloads")
    }

    func testMacroStepMapsLockScreenToSystemAction() {
        let step = MacroStep(kind: .lockScreen, value: "", intValue: 0)

        guard case .system(.lockScreen)? = step.padAction else {
            return XCTFail("Expected lock screen system action")
        }
    }

    func testMacroStepMapsOpenSettingsToSystemAction() {
        let step = MacroStep(kind: .openSettings, value: "", intValue: 0)

        guard case .system(.openSettings)? = step.padAction else {
            return XCTFail("Expected open settings system action")
        }
    }

    func testMacroStepMapsPasteTextToPadAction() {
        let step = MacroStep(kind: .pasteText, value: "Status update", intValue: 0)

        guard case .pasteText(let text)? = step.padAction else {
            return XCTFail("Expected paste text action")
        }
        XCTAssertEqual(text, "Status update")
    }

    func testMacroStepJSONDefaultsMissingID() throws {
        let data = #"{"kind":"key","value":"command+p","intValue":0}"#.data(using: .utf8)!
        let step = try JSONDecoder().decode(MacroStep.self, from: data)

        XCTAssertEqual(step.kind, .key)
        XCTAssertEqual(step.value, "command+p")
    }

    func testKeyComboBuildsAppleScriptForModifiers() throws {
        let source = try XCTUnwrap(MacroKeyCombo.appleScriptSource(for: "command+shift+p"))

        XCTAssertTrue(source.contains("command down"))
        XCTAssertTrue(source.contains("shift down"))
        XCTAssertTrue(source.contains("keystroke \"p\""))
    }

    func testKeyComboBuildsAppleScriptForSpecialKeys() throws {
        let source = try XCTUnwrap(MacroKeyCombo.appleScriptSource(for: "escape"))

        XCTAssertTrue(source.contains("key code 53"))
    }

    func testMacroTextEscapesAppleScriptStrings() {
        XCTAssertEqual(MacroText.escapedAppleScriptString("a \"quote\" \\ path"), "a \\\"quote\\\" \\\\ path")
    }

    func testRecordedKeyComboBuildsCommandShiftLetter() {
        let combo = RecordedKeyCombo.combo(keyCode: 0, characters: "p", modifierFlags: [.command, .shift])

        XCTAssertEqual(combo, "command+shift+p")
    }

    func testRecordedKeyComboBuildsSpecialKeyName() {
        let combo = RecordedKeyCombo.combo(keyCode: 126, characters: nil, modifierFlags: [.control])

        XCTAssertEqual(combo, "control+up")
    }

    func testRecordedKeyComboBuildsFunctionKeyName() {
        let combo = RecordedKeyCombo.combo(keyCode: 122, characters: nil, modifierFlags: [.option])

        XCTAssertEqual(combo, "option+f1")
    }

    func testRecordedKeyComboIgnoresModifierOnlyKeypress() {
        let combo = RecordedKeyCombo.combo(keyCode: 0, characters: nil, modifierFlags: [.command])

        XCTAssertNil(combo)
    }

    func testCounterDeltaUsesWholeSpannedTile() {
        XCTAssertEqual(PadModel.counterDelta(forNormalizedPoint: CGPoint(x: 0.02, y: 0.1), ownerIndex: 0, columnSpan: 2), -1)
        XCTAssertEqual(PadModel.counterDelta(forNormalizedPoint: CGPoint(x: 0.20, y: 0.1), ownerIndex: 0, columnSpan: 2), 1)
    }

    func testLockScreenSystemActionUsesMacShortcut() throws {
        let source = try XCTUnwrap(SystemAction.lockScreen.appleScriptSource)

        XCTAssertTrue(source.contains("control down"))
        XCTAssertTrue(source.contains("command down"))
        XCTAssertTrue(source.contains("keystroke \"q\""))
    }

    func testOpenSettingsSystemActionMatchesOpenQuakeConfigValue() {
        XCTAssertEqual(SystemAction.openSettings.rawValue, "config")
        XCTAssertEqual(SystemAction.openSettings.title, "Open Settings")
    }
}

final class TileSpecActionTests: XCTestCase {
    func testSystemActionRoundTripsThroughTileSpecJSON() throws {
        let spec = TileSpec(title: "Lock", symbol: "lock.fill", tint: .gray,
                            category: "System", action: .system(.lockScreen))
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(TileSpec.self, from: data)

        guard case .system(.lockScreen) = decoded.action else {
            return XCTFail("Expected lock screen system action")
        }
    }

    func testOpenSettingsSystemActionRoundTripsThroughTileSpecJSON() throws {
        let spec = TileSpec(title: "Settings", symbol: "gearshape.fill", tint: .gray,
                            category: "System", action: .system(.openSettings))
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(TileSpec.self, from: data)

        guard case .system(.openSettings) = decoded.action else {
            return XCTFail("Expected open settings system action")
        }
    }

    func testTileCatalogIncludesQuakeOSSettingsAction() throws {
        let spec = try XCTUnwrap(TileCatalog.all.first { $0.title == "QuakeOS Settings" })

        guard case .system(.openSettings) = spec.action else {
            return XCTFail("Expected open settings catalog action")
        }
    }

    func testTileSpecCarriesSpanThroughJSON() throws {
        let tile = Tile(title: "Wide", symbol: "rectangle.fill", tint: .blue, action: .openURL("https://example.com"),
                        editable: true, columnSpan: 2, rowSpan: 1)
        let spec = TileSpec(from: tile, category: "Web")
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(TileSpec.self, from: data)
        let made = decoded.makeTile()

        XCTAssertEqual(made.normalizedColumnSpan, 2)
        XCTAssertEqual(made.normalizedRowSpan, 1)
    }

    func testPasteTextActionRoundTripsThroughTileSpecJSON() throws {
        let spec = TileSpec(title: "Paste", symbol: "doc.on.clipboard", tint: .green,
                            category: "Text", action: .pasteText("Status update"))
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(TileSpec.self, from: data)

        guard case .pasteText(let text) = decoded.action else {
            return XCTFail("Expected paste text action")
        }
        XCTAssertEqual(text, "Status update")
    }

    func testCounterActionRoundTripsThroughTileSpecJSON() throws {
        let spec = TileSpec(title: "Count", symbol: "number", tint: .orange,
                            category: "Utilities", action: .counter(value: 7))
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(TileSpec.self, from: data)

        guard case .counter(let value) = decoded.action else {
            return XCTFail("Expected counter action")
        }
        XCTAssertEqual(value, 7)
    }
}

final class TileSpanTests: XCTestCase {
    override func tearDown() {
        TileEditSession.shared.revert()
        TileEditSession.shared.select(nil)
        super.tearDown()
    }

    func testPadPageResolvesCoveredSlotToSpanOwner() {
        let page = PadPage(name: "Spans", tiles: [
            Tile(title: "Wide", symbol: "rectangle.fill", tint: .blue, action: .none, columnSpan: 2, rowSpan: 1),
            PadStore.emptyTile
        ])

        XCTAssertEqual(page.ownerIndex(for: 0), 0)
        XCTAssertEqual(page.ownerIndex(for: 1), 0)
        XCTAssertTrue(page.isCoveredSlot(1))
    }

    func testScreenModelEmitsSpanAndCoveredCells() throws {
        let page = PadPage(name: "Spans", tiles: [
            Tile(title: "Wide", symbol: "rectangle.fill", tint: .blue, action: .none, columnSpan: 2, rowSpan: 1),
            PadStore.emptyTile
        ])
        let encoded = try XCTUnwrap(ScreenModel.buildModelEnc(pages: [page]))
        let json = try XCTUnwrap(encoded.removingPercentEncoding)
        let data = Data(json.utf8)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let keys = try XCTUnwrap(decoded.first?["keys"] as? [Any])
        let owner = try XCTUnwrap(keys[0] as? [String: Any])
        let covered = try XCTUnwrap(keys[1] as? [String: Any])

        XCTAssertEqual(owner["title"] as? String, "Wide")
        XCTAssertEqual(owner["w"] as? Int, 2)
        XCTAssertEqual(covered["covered"] as? Bool, true)
    }

    func testTileEditSessionSetSpanClearsCoveredCells() throws {
        let session = TileEditSession.shared
        session.draft = [PadPage(name: "Spans", tiles: [
            Tile(title: "Wide", symbol: "rectangle.fill", tint: .blue, action: .none, editable: true),
            Tile(title: "Covered", symbol: "xmark", tint: .red, action: .none, editable: true)
        ])]

        session.setSpan(page: 0, slot: 0, columns: 2, rows: 1)

        XCTAssertEqual(session.draft[0].tiles[0].normalizedColumnSpan, 2)
        XCTAssertTrue(session.draft[0].tiles[1].isEmpty)
        XCTAssertEqual(session.draft[0].ownerIndex(for: 1), 0)
        XCTAssertTrue(session.dirty)
    }

    func testTileEditSessionClampsSpanAtGridEdge() throws {
        let session = TileEditSession.shared
        session.draft = [PadPage(name: "Spans", tiles: Array(repeating: PadStore.emptyTile, count: PadModel.perPage))]
        session.draft[0].tiles[7] = Tile(title: "Edge", symbol: "rectangle.fill", tint: .blue, action: .none, editable: true)

        session.setSpan(page: 0, slot: 7, columns: 3, rows: 3)

        XCTAssertEqual(session.draft[0].tiles[7].normalizedColumnSpan, 1)
        XCTAssertEqual(session.draft[0].tiles[7].normalizedRowSpan, 2)
    }
}

final class TileIconTests: XCTestCase {
    func testTileIconRoundTripsThroughJSON() throws {
        let icon = TileIcon.imageURL(url: "https://example.com/icon.png", cachePath: "/tmp/icon.png")
        let data = try JSONEncoder().encode(icon)
        let decoded = try JSONDecoder().decode(TileIcon.self, from: data)

        XCTAssertEqual(decoded, icon)
    }

    func testLocalImagePathIconStillRoundTripsThroughJSON() throws {
        let icon = TileIcon.imagePath("~/Pictures/icon.png")
        let data = try JSONEncoder().encode(icon)
        let decoded = try JSONDecoder().decode(TileIcon.self, from: data)

        XCTAssertEqual(decoded, icon)
    }

    func testTileIconCacheSniffsSupportedImages() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)

        XCTAssertEqual(TileIconCache.imageInfo(from: png)?.fileExtension, "png")
        XCTAssertEqual(TileIconCache.imageInfo(from: jpg)?.mimeType, "image/jpeg")
        XCTAssertEqual(TileIconCache.imageInfo(from: svg)?.fileExtension, "svg")
        XCTAssertNil(TileIconCache.imageInfo(from: Data("not an image".utf8)))
    }

    func testTileIconCacheFilenameIsDeterministic() {
        let first = TileIconCache.cacheFilename(for: "https://example.com/icon.png", fileExtension: "png")
        let second = TileIconCache.cacheFilename(for: "https://example.com/icon.png", fileExtension: "png")

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasSuffix(".png"))
    }

    func testCustomIconDisablesAutomaticWebIcon() {
        let automatic = Tile(title: "Docs", symbol: "globe", tint: .blue, action: .openURL("https://example.com"))
        let custom = Tile(title: "Docs", symbol: "globe", tint: .blue, action: .openURL("https://example.com"),
                          customIcon: .imageURL(url: "https://example.com/icon.png", cachePath: "/tmp/icon.png"))

        XCTAssertTrue(automatic.allowsAutomaticWebIcon)
        XCTAssertFalse(custom.allowsAutomaticWebIcon)
    }

    func testEmojiIconRendersIntoScreenModel() throws {
        let tile = Tile(title: "Docs", symbol: "globe", tint: .blue, action: .none, customIcon: .emoji("📘"))
        let encoded = try XCTUnwrap(ScreenModel.buildModelEnc(pages: [PadPage(name: "Test", tiles: [tile])]))
        let json = try XCTUnwrap(encoded.removingPercentEncoding)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let pages = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let keys = try XCTUnwrap(pages.first?["keys"] as? [Any])
        let first = try XCTUnwrap(keys.first as? [String: Any])
        let icon = try XCTUnwrap(first["icon"] as? String)

        XCTAssertTrue(icon.hasPrefix("data:image/png;base64,"))
    }

    func testCachedURLIconRendersIntoScreenModel() throws {
        let data = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/l3Wk8QAAAABJRU5ErkJggg=="))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tile = Tile(title: "Docs", symbol: "globe", tint: .blue, action: .none,
                        customIcon: .imageURL(url: "https://example.com/icon.png", cachePath: url.path))
        let encoded = try XCTUnwrap(ScreenModel.buildModelEnc(pages: [PadPage(name: "Test", tiles: [tile])]))
        let json = try XCTUnwrap(encoded.removingPercentEncoding)
        let dataJSON = try XCTUnwrap(json.data(using: .utf8))
        let pages = try XCTUnwrap(JSONSerialization.jsonObject(with: dataJSON) as? [[String: Any]])
        let keys = try XCTUnwrap(pages.first?["keys"] as? [Any])
        let first = try XCTUnwrap(keys.first as? [String: Any])
        let icon = try XCTUnwrap(first["icon"] as? String)

        XCTAssertTrue(icon.hasPrefix("data:image/png;base64,"))
    }

    func testCounterValueRendersIntoScreenModel() throws {
        let tile = Tile(title: "Count", symbol: "number", tint: .orange, action: .counter(value: 7))
        let encoded = try XCTUnwrap(ScreenModel.buildModelEnc(pages: [PadPage(name: "Test", tiles: [tile])]))
        let json = try XCTUnwrap(encoded.removingPercentEncoding)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let pages = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let keys = try XCTUnwrap(pages.first?["keys"] as? [Any])
        let first = try XCTUnwrap(keys.first as? [String: Any])
        let counter = try XCTUnwrap(first["counter"] as? Int)

        XCTAssertEqual(counter, 7)
    }
}

final class CounterTileTests: XCTestCase {
    func testCounterDeltaUsesTileHalves() {
        XCTAssertEqual(PadModel.counterDelta(forNormalizedPoint: CGPoint(x: 0.01, y: 0.25)), -1)
        XCTAssertEqual(PadModel.counterDelta(forNormalizedPoint: CGPoint(x: 0.07, y: 0.25)), 1)
        XCTAssertEqual(PadModel.counterDelta(forNormalizedPoint: CGPoint(x: 1, y: 0.25)), 1)
    }
}
