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
