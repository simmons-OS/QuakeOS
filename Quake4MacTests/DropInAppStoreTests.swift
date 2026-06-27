import XCTest
@testable import Quake4Mac

final class DropInAppStoreTests: XCTestCase {
    func testScansValidStaticManifest() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","name":"Clock","entry":"index.html","served":false}
        """)

        let store = DropInAppStore(rootURL: root)

        XCTAssertEqual(store.apps.map(\.id), ["clock"])
        XCTAssertEqual(store.apps.first?.manifest.name, "Clock")
        XCTAssertTrue(store.issues.isEmpty)
    }

    func testManifestFileAliasIsAccepted() throws {
        let data = Data(#"{"id":"alias","file":"index.html"}"#.utf8)
        let manifest = try JSONDecoder().decode(DropInAppManifest.self, from: data)

        XCTAssertEqual(manifest.entry, "index.html")
        XCTAssertEqual(manifest.name, "alias")
    }

    func testRejectsUnsafeEntryPath() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "bad", manifest: """
        {"id":"bad","entry":"../secrets.html"}
        """)

        let store = DropInAppStore(rootURL: root)

        XCTAssertTrue(store.apps.isEmpty)
        XCTAssertEqual(store.issues.first?.folderName, "bad")
    }

    func testRejectsInvalidAppID() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "bad", manifest: """
        {"id":"Bad App","entry":"index.html"}
        """)

        let store = DropInAppStore(rootURL: root)

        XCTAssertTrue(store.apps.isEmpty)
        XCTAssertEqual(store.issues.first?.folderName, "bad")
    }

    func testDetectsServedAppHostCode() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "served", manifest: """
        {"id":"served","entry":"index.html","served":true,"server":"server.js"}
        """, extraFiles: ["server.js": ""])

        let store = DropInAppStore(rootURL: root)

        XCTAssertEqual(store.apps.first?.hasHostCode, true)
    }

    func testSafePathRejectsSchemesAndAbsolutePaths() {
        XCTAssertFalse(DropInAppStore.isSafeRelativePath("file:///tmp/index.html"))
        XCTAssertFalse(DropInAppStore.isSafeRelativePath("/tmp/index.html"))
        XCTAssertFalse(DropInAppStore.isSafeRelativePath("..\\secrets.html"))
        XCTAssertTrue(DropInAppStore.isSafeRelativePath("nested/index.html"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeApp(root: URL, folder: String, manifest: String, extraFiles: [String: String] = [:]) throws {
        let app = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: app.appendingPathComponent("app.json"))
        try Data("<html></html>".utf8).write(to: app.appendingPathComponent("index.html"))
        for (path, content) in extraFiles {
            try Data(content.utf8).write(to: app.appendingPathComponent(path))
        }
    }
}
