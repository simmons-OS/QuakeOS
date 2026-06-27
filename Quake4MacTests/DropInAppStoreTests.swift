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

    func testStaticLaunchURLIncludesNonSecretDefaultOptionsInFragment() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","options":[
          {"key":"theme","type":"text","default":"dark"},
          {"key":"token","type":"secret","default":"abc"},
          {"key":"serverToken","type":"text","default":"server","serverOnly":true}
        ]}
        """)
        let store = DropInAppStore(rootURL: root)
        let app = try XCTUnwrap(store.apps.first)

        let url = try XCTUnwrap(store.staticLaunchURL(for: app))

        XCTAssertEqual(url.fragment, "theme=dark")
    }

    func testStaticLaunchURLUsesSavedClientOptionValues() throws {
        let root = temporaryDirectory()
        let defaults = temporaryDefaults()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","options":[
          {"key":"theme","type":"text","default":"dark"},
          {"key":"enabled","type":"boolean","default":true}
        ]}
        """)
        let store = DropInAppStore(rootURL: root, defaults: defaults)
        let app = try XCTUnwrap(store.apps.first)

        store.setOptionValue(appID: app.id, optionKey: "theme", value: "light")
        store.setOptionValue(appID: app.id, optionKey: "enabled", value: "false")
        let url = try XCTUnwrap(store.staticLaunchURL(for: app))

        XCTAssertEqual(url.fragment, "theme=light&enabled=false")
    }

    func testOptionValuesPersistByAppID() throws {
        let root = temporaryDirectory()
        let defaults = temporaryDefaults()
        let option = DropInAppOption(key: "theme", label: "Theme", type: "text", defaultValue: "dark")
        let store = DropInAppStore(rootURL: root, defaults: defaults)

        store.setOptionValue(appID: "clock", optionKey: "theme", value: "light")
        let reloaded = DropInAppStore(rootURL: root, defaults: defaults)

        XCTAssertEqual(reloaded.optionValue(appID: "clock", option: option), "light")
    }

    func testClientOptionsExcludeSecretsAndServerOnlyValues() {
        let options = [
            DropInAppOption(key: "theme", label: "Theme", type: "text"),
            DropInAppOption(key: "token", label: "Token", type: "secret"),
            DropInAppOption(key: "hostToken", label: "Host Token", type: "text", serverOnly: true)
        ]

        XCTAssertEqual(DropInAppStore.clientOptions(options).map(\.key), ["theme"])
    }

    func testHomeCatalogIncludesStaticDropInAppsOnly() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "static", manifest: """
        {"id":"static","name":"Static App","entry":"index.html"}
        """)
        try writeApp(root: root, folder: "served", manifest: """
        {"id":"served","name":"Served App","entry":"index.html","served":true}
        """)
        let store = DropInAppStore(rootURL: root)

        let catalog = HomeStore.dropInCatalogApps(store.apps)

        XCTAssertEqual(catalog.map(\.title), ["Static App"])
        XCTAssertEqual(catalog.first?.dest, .dropInApp("static"))
    }

    func testImportFolderCopiesValidAppIntoRootByID() throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        try writeApp(root: sourceRoot, folder: "Source Folder", manifest: """
        {"id":"clock","name":"Clock","entry":"index.html"}
        """, extraFiles: ["assets/style.css": "body{}"])
        let source = sourceRoot.appendingPathComponent("Source Folder", isDirectory: true)
        let store = DropInAppStore(rootURL: root)

        let result = store.importFolder(at: source)

        guard case .success(let app) = result else {
            return XCTFail("Expected successful import")
        }
        XCTAssertEqual(app.id, "clock")
        XCTAssertEqual(store.apps.map(\.id), ["clock"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("clock/app.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("clock/assets/style.css").path))
    }

    func testImportFolderRejectsDuplicateAppID() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "installed", manifest: """
        {"id":"clock","entry":"index.html"}
        """)
        let sourceRoot = temporaryDirectory()
        try writeApp(root: sourceRoot, folder: "source", manifest: """
        {"id":"clock","entry":"index.html"}
        """)
        let store = DropInAppStore(rootURL: root)

        let result = store.importFolder(at: sourceRoot.appendingPathComponent("source", isDirectory: true))

        XCTAssertEqual(result, .failure(.duplicateID("clock")))
        XCTAssertEqual(store.apps.map(\.id), ["clock"])
    }

    func testImportFolderRejectsInvalidSource() throws {
        let root = temporaryDirectory()
        let source = temporaryDirectory()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = DropInAppStore(rootURL: root)

        let result = store.importFolder(at: source)

        XCTAssertEqual(result, .failure(.invalidSource("Missing app.json or manifest.json.")))
        XCTAssertTrue(store.apps.isEmpty)
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

    private func temporaryDefaults() -> UserDefaults {
        let suiteName = "QuakeOS.DropInAppStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func writeApp(root: URL, folder: String, manifest: String, extraFiles: [String: String] = [:]) throws {
        let app = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: app.appendingPathComponent("app.json"))
        try Data("<html></html>".utf8).write(to: app.appendingPathComponent("index.html"))
        for (path, content) in extraFiles {
            let url = app.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
    }
}
