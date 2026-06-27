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

    func testServedLaunchURLUsesLoopbackPathAndClientOptionQuery() throws {
        let root = temporaryDirectory()
        let defaults = temporaryDefaults()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"nested/index file?.html","served":true,"options":[
          {"key":"theme","type":"text","default":"dark"},
          {"key":"token","type":"secret","default":"abc"}
        ]}
        """, extraFiles: ["nested/index file?.html": "<html></html>"])
        let store = DropInAppStore(rootURL: root, defaults: defaults)
        let app = try XCTUnwrap(store.apps.first)

        store.setOptionValue(appID: app.id, optionKey: "theme", value: "light")
        let url = try XCTUnwrap(store.servedLaunchURL(for: app, port: 49152))

        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:49152/apps/clock/nested/index%20file%3F.html?theme=light")
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

    func testLoopbackServerParsesServedAppRequests() {
        XCTAssertEqual(DropInAppLoopbackServer.servedAppRequest("/apps/clock/index.html")?.appID, "clock")
        XCTAssertEqual(DropInAppLoopbackServer.servedAppRequest("/apps/clock/nested%20file.html")?.relativePath,
                       "nested file.html")
        XCTAssertNil(DropInAppLoopbackServer.servedAppRequest("/app/clock/index.html"))
        XCTAssertNil(DropInAppLoopbackServer.servedAppRequest("/apps/Bad/index.html"))
    }

    func testLoopbackHostCheckRequiresCurrentLoopbackPort() {
        let good = "GET /apps/clock/index.html HTTP/1.1\r\nHost: 127.0.0.1:49152\r\n\r\n"
        let local = "GET /apps/clock/index.html HTTP/1.1\r\nHost: localhost:49152\r\n\r\n"
        let badPort = "GET /apps/clock/index.html HTTP/1.1\r\nHost: 127.0.0.1:49153\r\n\r\n"
        let badHost = "GET /apps/clock/index.html HTTP/1.1\r\nHost: example.com:49152\r\n\r\n"

        XCTAssertTrue(DropInAppLoopbackServer.hostIsLoopback(request: good, port: 49152))
        XCTAssertTrue(DropInAppLoopbackServer.hostIsLoopback(request: local, port: 49152))
        XCTAssertFalse(DropInAppLoopbackServer.hostIsLoopback(request: badPort, port: 49152))
        XCTAssertFalse(DropInAppLoopbackServer.hostIsLoopback(request: badHost, port: 49152))
    }

    func testLoopbackServerServesContainedServedAppFile() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true}
        """, extraFiles: ["index.html": "<html>served</html>"])
        let store = DropInAppStore(rootURL: root)
        let app = try XCTUnwrap(store.apps.first)
        let server = DropInAppLoopbackServer(store: store)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        let url = try XCTUnwrap(store.servedLaunchURL(for: app, port: port))
        let done = expectation(description: "served app response")

        URLSession.shared.dataTask(with: url) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "<html>served</html>")
            XCTAssertNotNil((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Security-Policy"))
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
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

    func testRemoveAppDeletesFolderAndSavedOptionValues() throws {
        let root = temporaryDirectory()
        let defaults = temporaryDefaults()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","options":[{"key":"theme","type":"text","default":"dark"}]}
        """)
        let store = DropInAppStore(rootURL: root, defaults: defaults)
        store.setOptionValue(appID: "clock", optionKey: "theme", value: "light")

        let result = store.removeApp(id: "clock")

        guard case .success = result else {
            return XCTFail("Expected successful removal")
        }
        XCTAssertTrue(store.apps.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("clock").path))
        XCTAssertNil(store.optionValuesByAppID["clock"])
        let reloaded = DropInAppStore(rootURL: root, defaults: defaults)
        XCTAssertNil(reloaded.optionValuesByAppID["clock"])
    }

    func testRemoveAppRejectsMissingApp() {
        let store = DropInAppStore(rootURL: temporaryDirectory())

        guard case .failure(.missing("missing")) = store.removeApp(id: "missing") else {
            return XCTFail("Expected missing-app removal failure")
        }
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

    private func waitForPort(_ server: DropInAppLoopbackServer) throws -> UInt16 {
        let deadline = Date().addingTimeInterval(2)
        while server.port == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return try XCTUnwrap(server.port)
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
