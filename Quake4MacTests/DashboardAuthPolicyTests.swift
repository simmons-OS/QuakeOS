import XCTest
@testable import Quake4Mac

final class DashboardAuthPolicyTests: XCTestCase {
    func testHomeAssistantHeaderOnlyAppliesToDashboardHost() throws {
        var dashboard = DashboardConfig(name: "Home", urlString: "https://home.example/lovelace")
        dashboard.auth.kind = .homeAssistant
        let policy = DashboardAuthPolicy(
            dashboard: dashboard,
            auth: DashboardResolvedAuth(kind: .homeAssistant, homeAssistantToken: "token-1")
        )

        XCTAssertEqual(policy.headers(for: URL(string: "https://home.example/api"))["Authorization"], "Bearer token-1")
        XCTAssertTrue(policy.headers(for: URL(string: "https://other.example/api")).isEmpty)
    }

    func testBasicHeaderUsesBase64Credential() {
        var dashboard = DashboardConfig(name: "Router", urlString: "https://router.example")
        dashboard.auth.kind = .basic
        let policy = DashboardAuthPolicy(
            dashboard: dashboard,
            auth: DashboardResolvedAuth(kind: .basic, username: "admin", basicPassword: "secret")
        )

        let request = policy.requestByApplyingAuth(to: URLRequest(url: URL(string: "https://router.example")!))

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic YWRtaW46c2VjcmV0")
    }

    func testRequestNeedsAuthWhenMatchingRequestLacksConfiguredHeader() {
        var dashboard = DashboardConfig(name: "Internal", urlString: "https://internal.example")
        dashboard.auth.kind = .customHeaders
        let policy = DashboardAuthPolicy(
            dashboard: dashboard,
            auth: DashboardResolvedAuth(kind: .customHeaders, headers: [("X-Token", "abc")])
        )

        XCTAssertTrue(policy.requestNeedsAuth(URLRequest(url: URL(string: "https://internal.example")!)))
        XCTAssertFalse(policy.requestNeedsAuth(URLRequest(url: URL(string: "https://elsewhere.example")!)))
    }
}
