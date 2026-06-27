import XCTest
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
        let keys = try XCTUnwrap(pages.first?["keys"] as? [[String: Any]])
        let icon = try XCTUnwrap(keys.first?["icon"] as? String)

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
        let keys = try XCTUnwrap(pages.first?["keys"] as? [[String: Any]])
        let icon = try XCTUnwrap(keys.first?["icon"] as? String)

        XCTAssertTrue(icon.hasPrefix("data:image/png;base64,"))
    }
}
