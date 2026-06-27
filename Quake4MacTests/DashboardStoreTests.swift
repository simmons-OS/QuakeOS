import XCTest
@testable import Quake4Mac

final class DashboardStoreTests: XCTestCase {
    func testCreateHomeAssistantDashboardPersistsWithoutPlaintextSecret() throws {
        let secretStore = MemoryDashboardSecretStore()
        let file = temporaryFile()
        let store = DashboardStore(secretStore: secretStore, fileURL: file)
        var dashboard = DashboardConfig(name: "Home Assistant", urlString: "https://home.example")
        dashboard.auth.kind = .homeAssistant

        let saved = try store.save(dashboard,
                                   secrets: DashboardSecretValues(homeAssistantToken: "abc123"),
                                   requireSecrets: true)

        XCTAssertEqual(store.dashboards.count, 1)
        XCTAssertEqual(saved.name, "Home Assistant")
        let data = try Data(contentsOf: file)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("abc123"))
        XCTAssertEqual(try secretStore.get(dashboardID: saved.id, field: DashboardStore.homeAssistantTokenField), "abc123")
    }

    func testBasicAuthValidationRequiresUsernameAndPassword() {
        var dashboard = DashboardConfig(name: "Router", urlString: "https://router.example")
        dashboard.auth.kind = .basic

        let errors = DashboardStore.validate(dashboard, secrets: .empty, requireSecrets: true)

        XCTAssertTrue(errors.contains(.missingBasicUsername))
        XCTAssertTrue(errors.contains(.missingBasicPassword))
    }

    func testCustomHeaderValidationRequiresHeaderRow() {
        var dashboard = DashboardConfig(name: "Internal", urlString: "https://internal.example")
        dashboard.auth.kind = .customHeaders

        let errors = DashboardStore.validate(dashboard, secrets: .empty, requireSecrets: true)

        XCTAssertTrue(errors.contains(.missingHeader))
    }

    func testEditingCustomHeadersAllowsExistingSecretsAndRequiresNewOnes() throws {
        let store = DashboardStore(secretStore: MemoryDashboardSecretStore(), fileURL: temporaryFile())
        let existingHeader = DashboardHeader(name: "X-Token")
        var dashboard = DashboardConfig(name: "Internal", urlString: "https://internal.example")
        dashboard.auth.kind = .customHeaders
        dashboard.auth.headers = [existingHeader]
        let saved = try store.save(
            dashboard,
            secrets: DashboardSecretValues(headerValues: [existingHeader.id: "abc"]),
            requireSecrets: true
        )

        var edited = saved
        let newHeader = DashboardHeader(name: "X-New")
        edited.auth.headers.append(newHeader)

        XCTAssertThrowsError(try store.save(edited, secrets: .empty, requireSecrets: false)) { error in
            guard case DashboardStoreError.validation(let errors) = error else {
                return XCTFail("Expected validation error, got \(error)")
            }
            XCTAssertEqual(errors, [.missingHeaderValue("X-New")])
        }
    }

    func testDuplicateAssignsNewIdentity() throws {
        let store = DashboardStore(secretStore: MemoryDashboardSecretStore(), fileURL: temporaryFile())
        let dashboard = try store.save(DashboardConfig(name: "Grafana", urlString: "https://grafana.example"),
                                       secrets: .empty,
                                       requireSecrets: false)

        let copy = try store.duplicate(dashboard)

        XCTAssertNotEqual(copy.id, dashboard.id)
        XCTAssertEqual(copy.name, "Grafana Copy")
        XCTAssertEqual(store.dashboards.count, 2)
    }

    func testSideActionValidationRequiresURLForURLActions() {
        var dashboard = DashboardConfig(name: "Home", urlString: "https://home.example")
        dashboard.actionStrip.isEnabled = true
        dashboard.actionStrip.actions = [
            DashboardSideAction(title: "Scene", symbol: "bolt.fill", kind: .openURL, urlString: "not-a-url")
        ]

        let errors = DashboardStore.validate(dashboard, secrets: .empty, requireSecrets: false)

        XCTAssertTrue(errors.contains(.invalidActionURL("Scene")))
    }

    func testSideActionValidationRequiresAtLeastOneActionWhenEnabled() {
        var dashboard = DashboardConfig(name: "Home", urlString: "https://home.example")
        dashboard.actionStrip.isEnabled = true

        let errors = DashboardStore.validate(dashboard, secrets: .empty, requireSecrets: false)

        XCTAssertTrue(errors.contains(.missingSideAction))
    }

    func testSideActionValidationAllowsDashboardControlsWithoutURLs() {
        var dashboard = DashboardConfig(name: "Home", urlString: "https://home.example")
        dashboard.actionStrip.isEnabled = true
        dashboard.actionStrip.actions = [
            .defaultAction(kind: .reload),
            .defaultAction(kind: .home)
        ]

        let errors = DashboardStore.validate(dashboard, secrets: .empty, requireSecrets: false)

        XCTAssertFalse(errors.contains(.invalidActionURL("Reload")))
        XCTAssertTrue(errors.isEmpty)
    }

    func testLegacyDashboardJSONLoadsWithoutActionStrip() throws {
        let id = UUID()
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        [
          {
            "id": "\(id.uuidString)",
            "name": "Legacy",
            "urlString": "https://legacy.example",
            "auth": { "kind": "none", "username": "", "headers": [] },
            "createdAt": "2026-06-26T12:00:00Z",
            "updatedAt": "2026-06-26T12:00:00Z"
          }
        ]
        """
        try Data(json.utf8).write(to: file)

        let store = DashboardStore(secretStore: MemoryDashboardSecretStore(), fileURL: file)

        XCTAssertEqual(store.dashboards.count, 1)
        XCTAssertFalse(store.dashboards[0].actionStrip.isEnabled)
    }

    func testLegacyDashboardJSONLoadsWithDesktopIdentityAndNoExternalLinks() throws {
        let id = UUID()
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        [
          {
            "id": "\(id.uuidString)",
            "name": "Legacy",
            "urlString": "https://legacy.example",
            "auth": { "kind": "none", "username": "", "headers": [] },
            "createdAt": "2026-06-26T12:00:00Z",
            "updatedAt": "2026-06-26T12:00:00Z"
          }
        ]
        """
        try Data(json.utf8).write(to: file)

        let store = DashboardStore(secretStore: MemoryDashboardSecretStore(), fileURL: file)

        XCTAssertEqual(store.dashboards.count, 1)
        XCTAssertTrue(store.dashboards[0].browser.useDesktopUserAgent)
        XCTAssertFalse(store.dashboards[0].browser.openLinksExternally)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("dashboards.json")
    }
}

final class MemoryDashboardSecretStore: DashboardSecretStoring {
    private var values: [String: String] = [:]

    func set(_ value: String, dashboardID: UUID, field: String) throws {
        values[key(dashboardID, field)] = value
    }

    func get(dashboardID: UUID, field: String) throws -> String? {
        values[key(dashboardID, field)]
    }

    func delete(dashboardID: UUID, field: String) throws {
        values[key(dashboardID, field)] = nil
    }

    func deleteAll(dashboardID: UUID) throws {
        values = values.filter { !$0.key.hasPrefix(dashboardID.uuidString + ":") }
    }

    private func key(_ dashboardID: UUID, _ field: String) -> String {
        "\(dashboardID.uuidString):\(field)"
    }
}
