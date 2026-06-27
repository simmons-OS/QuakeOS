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

    func testClientConfigPayloadExcludesSecretsAndCoercesBooleans() throws {
        let root = temporaryDirectory()
        let defaults = temporaryDefaults()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,"options":[
          {"key":"theme","type":"text","default":"dark"},
          {"key":"seconds","type":"boolean","default":false},
          {"key":"token","type":"secret","default":"abc"},
          {"key":"hostToken","type":"text","default":"server","serverOnly":true}
        ]}
        """)
        let store = DropInAppStore(rootURL: root, defaults: defaults)
        let app = try XCTUnwrap(store.apps.first)
        store.setOptionValue(appID: app.id, optionKey: "seconds", value: "true")

        let payload = store.clientConfigPayload(for: app)
        let api = try XCTUnwrap(payload["api"] as? [String: String])
        let options = try XCTUnwrap(payload["options"] as? [String: Any])

        XCTAssertEqual(payload["app"] as? String, "clock")
        XCTAssertEqual(api["open"], "/app-api/open?app=clock")
        XCTAssertEqual(options["theme"] as? String, "dark")
        XCTAssertEqual(options["seconds"] as? Bool, true)
        XCTAssertNil(options["token"])
        XCTAssertNil(options["hostToken"])
    }

    func testLoopbackServerParsesServedAppRequests() {
        XCTAssertEqual(DropInAppLoopbackServer.servedAppRequest("/apps/clock/index.html")?.appID, "clock")
        XCTAssertEqual(DropInAppLoopbackServer.servedAppRequest("/apps/clock/nested%20file.html")?.relativePath,
                       "nested file.html")
        XCTAssertNil(DropInAppLoopbackServer.servedAppRequest("/app/clock/index.html"))
        XCTAssertNil(DropInAppLoopbackServer.servedAppRequest("/apps/Bad/index.html"))
    }

    func testLoopbackServerParsesAppConfigRequests() {
        XCTAssertEqual(DropInAppLoopbackServer.appConfigAppID("/app-config?app=clock"), "clock")
        XCTAssertNil(DropInAppLoopbackServer.appConfigAppID("/app-config"))
        XCTAssertNil(DropInAppLoopbackServer.appConfigAppID("/app-config?app=Bad"))
        XCTAssertNil(DropInAppLoopbackServer.appConfigAppID("/apps/clock/index.html"))
    }

    func testLoopbackServerParsesAppOpenRequests() throws {
        let target = "/app-api/open?app=clock&url=https%3A%2F%2Fexample.com%2Fpath%3Fq%3D1"
        let request = try XCTUnwrap(DropInAppLoopbackServer.appOpenRequest(target))

        XCTAssertEqual(request.appID, "clock")
        XCTAssertEqual(request.url.absoluteString, "https://example.com/path?q=1")
        XCTAssertNil(DropInAppLoopbackServer.appOpenRequest("/app-api/open?app=Bad&url=https%3A%2F%2Fexample.com"))
        XCTAssertNil(DropInAppLoopbackServer.appOpenRequest("/app-api/open?app=clock&url=file%3A%2F%2F%2Ftmp%2Fsecret"))
        XCTAssertNil(DropInAppLoopbackServer.appOpenRequest("/app-config?app=clock"))
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

    func testLoopbackSameOriginGateAcceptsFetchOriginOrReferer() {
        let fetch = "GET /app-config?app=clock HTTP/1.1\r\nSec-Fetch-Site: same-origin\r\n\r\n"
        let origin = "GET /app-config?app=clock HTTP/1.1\r\nOrigin: http://127.0.0.1:49152\r\n\r\n"
        let referer = "GET /app-config?app=clock HTTP/1.1\r\nReferer: http://127.0.0.1:49152/apps/clock/index.html\r\n\r\n"
        let cross = "GET /app-config?app=clock HTTP/1.1\r\nOrigin: http://example.com\r\n\r\n"

        XCTAssertTrue(DropInAppLoopbackServer.isSameOrigin(request: fetch, port: 49152))
        XCTAssertTrue(DropInAppLoopbackServer.isSameOrigin(request: origin, port: 49152))
        XCTAssertTrue(DropInAppLoopbackServer.isSameOrigin(request: referer, port: 49152))
        XCTAssertFalse(DropInAppLoopbackServer.isSameOrigin(request: cross, port: 49152))
        XCTAssertFalse(DropInAppLoopbackServer.isSameOrigin(request: "GET / HTTP/1.1\r\n\r\n", port: 49152))
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

    func testLoopbackServerServesSameOriginClientConfig() throws {
        let root = temporaryDirectory()
        let defaults = temporaryDefaults()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,"options":[
          {"key":"theme","type":"text","default":"dark"},
          {"key":"seconds","type":"boolean","default":false},
          {"key":"token","type":"secret","default":"abc"}
        ]}
        """)
        let store = DropInAppStore(rootURL: root, defaults: defaults)
        store.setOptionValue(appID: "clock", optionKey: "seconds", value: "true")
        let server = DropInAppLoopbackServer(store: store)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/app-config?app=clock")!)
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        let done = expectation(description: "app config response")

        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
            let api = json?["api"] as? [String: String]
            let options = json?["options"] as? [String: Any]
            XCTAssertEqual(json?["app"] as? String, "clock")
            XCTAssertEqual(api?["open"], "/app-api/open?app=clock")
            XCTAssertEqual(options?["theme"] as? String, "dark")
            XCTAssertEqual(options?["seconds"] as? Bool, true)
            XCTAssertNil(options?["token"])
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
    }

    func testLoopbackServerRejectsCrossOriginClientConfig() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true}
        """)
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root))
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        let done = expectation(description: "app config rejection")

        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/app-config?app=clock")!) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
    }

    func testLoopbackServerOpensSameOriginHTTPURL() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true}
        """)
        let recorder = URLRecorder()
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root), openURL: recorder.open)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appOpenURL(port: port,
                                                     appID: "clock",
                                                     targetURL: "https://example.com/path?q=1"))
        request.httpMethod = "POST"
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        let done = expectation(description: "app open response")

        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
            XCTAssertEqual(recorder.urls.map(\.absoluteString), ["https://example.com/path?q=1"])
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
    }

    func testLoopbackServerRejectsCrossOriginAppOpen() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true}
        """)
        let recorder = URLRecorder()
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root), openURL: recorder.open)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appOpenURL(port: port,
                                                     appID: "clock",
                                                     targetURL: "https://example.com"))
        request.httpMethod = "POST"
        let done = expectation(description: "app open rejection")

        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
            XCTAssertTrue(recorder.urls.isEmpty)
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
    }

    func testLoopbackServerRejectsStaticAppOpen() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":false}
        """)
        let recorder = URLRecorder()
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root), openURL: recorder.open)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appOpenURL(port: port,
                                                     appID: "clock",
                                                     targetURL: "https://example.com"))
        request.httpMethod = "POST"
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        let done = expectation(description: "static app open rejection")

        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            XCTAssertTrue(recorder.urls.isEmpty)
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

    func testImportFolderRequiresConfirmationForHostCode() throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        try writeApp(root: sourceRoot, folder: "source", manifest: """
        {"id":"clock","name":"Clock","entry":"index.html","served":true,"server":"server.js"}
        """, extraFiles: ["server.js": ""])
        let source = sourceRoot.appendingPathComponent("source", isDirectory: true)
        let store = DropInAppStore(rootURL: root)

        let blocked = store.importFolder(at: source)

        XCTAssertEqual(blocked, .failure(.requiresHostCodeConfirmation("Clock")))
        XCTAssertTrue(store.apps.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("clock").path))

        let confirmed = store.importFolder(at: source, allowHostCode: true)

        guard case .success(let app) = confirmed else {
            return XCTFail("Expected confirmed host-code import")
        }
        XCTAssertEqual(app.id, "clock")
        XCTAssertTrue(app.hasHostCode)
    }

    func testImportArchiveCopiesValidWrappedAppIntoRootByID() throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        try writeApp(root: sourceRoot, folder: "Clock Source", manifest: """
        {"id":"clock","name":"Clock","entry":"index.html"}
        """, extraFiles: ["assets/style.css": "body{}"])
        let archive = temporaryDirectory().appendingPathExtension("zip")
        try createZip(from: sourceRoot.appendingPathComponent("Clock Source", isDirectory: true),
                      to: archive,
                      keepParent: true)
        let store = DropInAppStore(rootURL: root)

        let result = store.importArchive(at: archive)

        guard case .success(let app) = result else {
            return XCTFail("Expected successful archive import")
        }
        XCTAssertEqual(app.id, "clock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("clock/app.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("clock/assets/style.css").path))
    }

    func testImportArchiveAcceptsManifestAtArchiveRoot() throws {
        let root = temporaryDirectory()
        let flatRoot = temporaryDirectory()
        try writeApp(root: flatRoot, folder: "flat", manifest: """
        {"id":"flat","entry":"index.html"}
        """)
        let archive = temporaryDirectory().appendingPathExtension("zip")
        try createZip(from: flatRoot.appendingPathComponent("flat", isDirectory: true),
                      to: archive,
                      keepParent: false)
        let store = DropInAppStore(rootURL: root)

        let result = store.importArchive(at: archive)

        guard case .success(let app) = result else {
            return XCTFail("Expected successful flat archive import")
        }
        XCTAssertEqual(app.id, "flat")
    }

    func testImportArchiveRequiresConfirmationForHostCode() throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        try writeApp(root: sourceRoot, folder: "source", manifest: """
        {"id":"clock","name":"Clock","entry":"index.html","served":true,"server":"server.js"}
        """, extraFiles: ["server.js": ""])
        let archive = temporaryDirectory().appendingPathExtension("zip")
        try createZip(from: sourceRoot.appendingPathComponent("source", isDirectory: true),
                      to: archive,
                      keepParent: true)
        let store = DropInAppStore(rootURL: root)

        XCTAssertEqual(store.importArchive(at: archive), .failure(.requiresHostCodeConfirmation("Clock")))
        XCTAssertTrue(store.apps.isEmpty)
    }

    func testExportArchiveWritesInstallableZip() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html"}
        """, extraFiles: ["assets/style.css": "body{}"])
        let store = DropInAppStore(rootURL: root)
        let archive = temporaryDirectory().appendingPathExtension("zip")

        let result = store.exportArchive(appID: "clock", to: archive)

        guard case .success = result else {
            return XCTFail("Expected successful archive export")
        }
        let extracted = temporaryDirectory()
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try extractZip(archive, to: extracted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("clock/app.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("clock/assets/style.css").path))
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

    func testDetectsExecutableFileHostCode() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "scripted", manifest: """
        {"id":"scripted","entry":"index.html"}
        """, extraFiles: ["scripts/install.sh": ""])

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

    private func appOpenURL(port: UInt16, appID: String, targetURL: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/app-api/open"
        components.queryItems = [
            URLQueryItem(name: "app", value: appID),
            URLQueryItem(name: "url", value: targetURL)
        ]
        return try XCTUnwrap(components.url)
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

    private func createZip(from source: URL, to destination: URL, keepParent: Bool) throws {
        var arguments = ["-c", "-k", "--sequesterRsrc"]
        if keepParent {
            arguments.append("--keepParent")
        }
        arguments.append(contentsOf: [source.path, destination.path])
        try runDitto(arguments)
    }

    private func extractZip(_ source: URL, to destination: URL) throws {
        try runDitto(["-x", "-k", source.path, destination.path])
    }

    private func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "ditto failed"
            throw NSError(domain: "DropInAppStoreTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

private final class URLRecorder {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    func open(_ url: URL) -> Bool {
        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
        return true
    }
}
