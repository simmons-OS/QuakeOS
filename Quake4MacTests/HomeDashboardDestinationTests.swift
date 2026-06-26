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
