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

    func testSecretAndServerOnlyOptionValuesPersistOutsideDefaults() throws {
        let root = temporaryDirectory()
        let defaults = temporaryDefaults()
        let secretStore = MemoryDropInAppSecretStore()
        let theme = DropInAppOption(key: "theme", label: "Theme", type: "text")
        let token = DropInAppOption(key: "token", label: "Token", type: "secret")
        let hostToken = DropInAppOption(key: "hostToken", label: "Host Token", type: "text", serverOnly: true)
        let store = DropInAppStore(rootURL: root, defaults: defaults, secretStore: secretStore)

        store.setOptionValue(appID: "clock", option: theme, value: "light")
        store.setOptionValue(appID: "clock", option: token, value: "abc123")
        store.setOptionValue(appID: "clock", option: hostToken, value: "server456")
        let reloaded = DropInAppStore(rootURL: root, defaults: defaults, secretStore: secretStore)

        XCTAssertEqual(store.optionValuesByAppID["clock"], ["theme": "light"])
        XCTAssertEqual(reloaded.optionValue(appID: "clock", option: theme), "light")
        XCTAssertEqual(reloaded.optionValue(appID: "clock", option: token), "abc123")
        XCTAssertEqual(reloaded.optionValue(appID: "clock", option: hostToken), "server456")
        XCTAssertEqual(try secretStore.get(appID: "clock", field: "token"), "abc123")
        XCTAssertEqual(try secretStore.get(appID: "clock", field: "hostToken"), "server456")
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
        for option in app.manifest.options {
            if option.key == "token" || option.key == "hostToken" {
                store.setOptionValue(appID: app.id, option: option, value: "stored-secret")
            }
        }

        let payload = store.clientConfigPayload(for: app)
        let api = try XCTUnwrap(payload["api"] as? [String: String])
        let options = try XCTUnwrap(payload["options"] as? [String: Any])

        XCTAssertEqual(payload["app"] as? String, "clock")
        XCTAssertEqual(api["open"], "/app-api/open")
        XCTAssertEqual(options["theme"] as? String, "dark")
        XCTAssertEqual(options["seconds"] as? Bool, true)
        XCTAssertNil(options["token"])
        XCTAssertNil(options["hostToken"])
    }

    func testProxyConfigPayloadIncludesSecretAndServerOnlyOptions() throws {
        let root = temporaryDirectory()
        let defaults = temporaryDefaults()
        let secretStore = MemoryDropInAppSecretStore()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,"options":[
          {"key":"theme","type":"text","default":"dark"},
          {"key":"seconds","type":"boolean","default":false},
          {"key":"token","type":"secret","default":"abc"},
          {"key":"hostToken","type":"text","default":"server","serverOnly":true}
        ],"proxy":{"allow":[{"option":"host"}]}}
        """)
        let store = DropInAppStore(rootURL: root, defaults: defaults, secretStore: secretStore)
        let app = try XCTUnwrap(store.apps.first)
        store.setOptionValue(appID: app.id, optionKey: "theme", value: "light")
        store.setOptionValue(appID: app.id, optionKey: "seconds", value: "true")
        for option in app.manifest.options {
            if option.key == "token" {
                store.setOptionValue(appID: app.id, option: option, value: "stored-secret")
            } else if option.key == "hostToken" {
                store.setOptionValue(appID: app.id, option: option, value: "server-secret")
            }
        }

        let payload = store.proxyConfigPayload(for: app)
        let api = try XCTUnwrap(payload["api"] as? [String: String])
        let options = try XCTUnwrap(payload["options"] as? [String: Any])

        XCTAssertEqual(payload["app"] as? String, "clock")
        XCTAssertEqual(api["config"], "/app-proxy/config")
        XCTAssertEqual(api["proxy"], "/app-proxy")
        XCTAssertEqual(options["theme"] as? String, "light")
        XCTAssertEqual(options["seconds"] as? Bool, true)
        XCTAssertEqual(options["token"] as? String, "stored-secret")
        XCTAssertEqual(options["hostToken"] as? String, "server-secret")
    }

    func testManifestDecodesProxyAllowRules() throws {
        let data = Data("""
        {"id":"proxy","entry":"index.html","served":true,
         "proxy":{"methods":["GET"],"verifySslOption":"verifySsl","allow":[
           {"option":"host"},
           {"pattern":"^https://api\\\\.example\\\\.com/"}
         ]}}
        """.utf8)

        let manifest = try JSONDecoder().decode(DropInAppManifest.self, from: data)

        XCTAssertEqual(manifest.proxy?.methods, ["GET"])
        XCTAssertEqual(manifest.proxy?.verifySslOption, "verifySsl")
        XCTAssertEqual(manifest.proxy?.allow.count, 2)
        XCTAssertEqual(manifest.proxy?.allow.first?.option, "host")
        XCTAssertEqual(manifest.proxy?.allow.last?.pattern, #"^https://api\.example\.com/"#)
    }

    func testManifestDecodesGridMetadata() throws {
        let data = Data("""
        {"id":"agenda","entry":"agenda.html","served":true,
         "grid":{"cols":3,"rows":2,"defaults":[
           {"title":"Open","action":{"kind":"url","url":"https://example.com"}}
         ]}}
        """.utf8)

        let manifest = try JSONDecoder().decode(DropInAppManifest.self, from: data)
        let grid = try XCTUnwrap(manifest.grid)

        XCTAssertEqual(grid.cols, 3)
        XCTAssertEqual(grid.rows, 2)
        XCTAssertEqual(grid.defaults.count, 1)
        XCTAssertEqual(grid.defaults.first, .object([
            "title": .string("Open"),
            "action": .object([
                "kind": .string("url"),
                "url": .string("https://example.com")
            ])
        ]))
    }

    func testGridMetadataBuildsNativeTilesFromDefaults() throws {
        let data = Data("""
        {"id":"agenda","entry":"agenda.html","served":true,
         "grid":{"cols":3,"rows":2,"defaults":[
           {"label":"Docs","icon":"🌐","type":"url","value":"https://example.com","w":2},
           {"label":"Count","type":"counter","value":"4"},
           {"label":"Image","iconType":"image","iconImage":"~/icon.png","type":"text","value":"hello","h":1.5}
         ]}}
        """.utf8)
        let manifest = try JSONDecoder().decode(DropInAppManifest.self, from: data)
        let tiles = try XCTUnwrap(manifest.grid?.nativeTiles())

        XCTAssertEqual(tiles.count, 6)
        XCTAssertEqual(tiles[0].title, "Docs")
        XCTAssertEqual(tiles[0].normalizedColumnSpan, 2)
        XCTAssertEqual(tiles[0].customIcon, .emoji("🌐"))
        guard case .openURL(let url) = tiles[0].action else {
            return XCTFail("Expected URL action")
        }
        XCTAssertEqual(url, "https://example.com")

        XCTAssertEqual(tiles[1].title, "Count")
        guard case .counter(let value) = tiles[1].action else {
            return XCTFail("Expected counter action")
        }
        XCTAssertEqual(value, 4)

        XCTAssertEqual(tiles[2].customIcon, .imagePath("~/icon.png"))
        XCTAssertEqual(tiles[2].normalizedRowSpan, 1)
        XCTAssertTrue(tiles[5].isEmpty)
    }

    func testGridMetadataCapsNativeTileCount() throws {
        let data = Data("""
        {"id":"agenda","entry":"agenda.html","served":true,
         "grid":{"cols":20,"rows":20,"defaults":[]}}
        """.utf8)
        let manifest = try JSONDecoder().decode(DropInAppManifest.self, from: data)

        XCTAssertEqual(manifest.grid?.nativeTileCount, PadModel.perPage)
        XCTAssertEqual(manifest.grid?.nativeTiles().count, PadModel.perPage)
    }

    func testGridMetadataBuildsNativeMacroTile() throws {
        let data = Data("""
        {"id":"agenda","entry":"agenda.html","served":true,
         "grid":{"cols":1,"rows":1,"defaults":[
           {"label":"Prep","type":"macro","steps":[
             {"kind":"key","value":"command+k"},
             {"kind":"delay","value":"500"},
             {"kind":"system","value":"config"},
             {"kind":"cmd","value":"say ready"}
           ]}
         ]}}
        """.utf8)
        let manifest = try JSONDecoder().decode(DropInAppManifest.self, from: data)
        let tile = try XCTUnwrap(manifest.grid?.nativeTiles().first)

        guard case .macro(let steps) = tile.action else {
            return XCTFail("Expected macro action")
        }
        XCTAssertEqual(steps.map(\.kind), [.key, .delay, .openSettings, .shell])
        XCTAssertEqual(steps[0].value, "command+k")
        XCTAssertEqual(steps[1].delayMilliseconds, 500)
        XCTAssertEqual(steps[3].value, "say ready")
    }

    func testManifestIgnoresMalformedGridMetadata() throws {
        let data = Data("""
        {"id":"agenda","entry":"agenda.html","served":true,
         "grid":{"cols":"three","rows":2,"defaults":[]}}
        """.utf8)

        let manifest = try JSONDecoder().decode(DropInAppManifest.self, from: data)

        XCTAssertNil(manifest.grid)
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

    func testLoopbackServerParsesAppAPIActionRequests() throws {
        let target = "/app-api/open?url=https%3A%2F%2Fexample.com%2Fpath%3Fq%3D1"
        let request = try XCTUnwrap(DropInAppLoopbackServer.appAPIActionRequest(target))

        XCTAssertEqual(request.action, "open")
        XCTAssertEqual(request.query["url"], "https://example.com/path?q=1")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/path?q=1")
        XCTAssertEqual(DropInAppLoopbackServer.appAPIActionRequest("/app-api/feed")?.action, "feed")
        XCTAssertNil(DropInAppLoopbackServer.appAPIActionRequest("/app-api/Bad"))
        XCTAssertNil(DropInAppLoopbackServer.appAPIActionRequest("/app-api/open/extra"))
        XCTAssertNil(DropInAppLoopbackServer.appAPIActionRequest("/app-api/open?url=file%3A%2F%2F%2Ftmp%2Fsecret")?.url)
        XCTAssertNil(DropInAppLoopbackServer.appAPIActionRequest("/app-config?app=clock"))
    }

    func testLoopbackServerParsesAppProxyTarget() throws {
        let target = "/app-proxy?url=https%3A%2F%2Fapi.example.com%2Fdata%3Fq%3D1"
        let request = try XCTUnwrap(DropInAppLoopbackServer.appProxyTarget(target))

        XCTAssertEqual(request.absoluteString, "https://api.example.com/data?q=1")
        XCTAssertNil(DropInAppLoopbackServer.appProxyTarget("/app-proxy"))
        XCTAssertNil(DropInAppLoopbackServer.appProxyTarget("/app-proxy?url=file%3A%2F%2F%2Ftmp%2Fsecret"))
        XCTAssertNil(DropInAppLoopbackServer.appProxyTarget("/app-api/open?url=https%3A%2F%2Fapi.example.com"))
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

    func testLoopbackRequestingAppIDRequiresServedAppReferer() {
        let request = """
        GET /app-proxy?url=https%3A%2F%2Fapi.example.com HTTP/1.1\r
        Referer: http://127.0.0.1:49152/apps/clock/index.html\r
        \r

        """
        XCTAssertEqual(DropInAppLoopbackServer.requestingAppID(request: request, port: 49152), "clock")
        XCTAssertNil(DropInAppLoopbackServer.requestingAppID(request: request, port: 49153))
        XCTAssertNil(DropInAppLoopbackServer.requestingAppID(request: "GET / HTTP/1.1\r\n\r\n", port: 49152))
    }

    func testProxyAllowRulesMatchOptionBaseAndPublicPatternsOnly() throws {
        XCTAssertTrue(DropInAppLoopbackServer.proxyOptionRuleAllows(
            baseValue: "http://192.168.1.10/api",
            target: try XCTUnwrap(URL(string: "http://192.168.1.10/api/state"))
        ))
        XCTAssertFalse(DropInAppLoopbackServer.proxyOptionRuleAllows(
            baseValue: "http://192.168.1.10/api",
            target: try XCTUnwrap(URL(string: "http://192.168.1.10/other"))
        ))
        XCTAssertTrue(DropInAppLoopbackServer.proxyPatternRuleAllows(
            pattern: #"^https://api\.example\.com/"#,
            target: try XCTUnwrap(URL(string: "https://api.example.com/data"))
        ))
        XCTAssertFalse(DropInAppLoopbackServer.proxyPatternRuleAllows(
            pattern: #".*"#,
            target: try XCTUnwrap(URL(string: "http://127.0.0.1:8000/private"))
        ))
        XCTAssertFalse(DropInAppLoopbackServer.proxyPatternRuleAllows(
            pattern: #".*"#,
            target: try XCTUnwrap(URL(string: "http://192.168.1.10/private"))
        ))
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
            XCTAssertEqual(api?["open"], "/app-api/open")
            XCTAssertEqual(options?["theme"] as? String, "dark")
            XCTAssertEqual(options?["seconds"] as? Bool, true)
            XCTAssertNil(options?["token"])
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
    }

    func testLoopbackServerServesSameOriginProxyConfigWithSecrets() throws {
        let root = temporaryDirectory()
        let defaults = temporaryDefaults()
        let secretStore = MemoryDropInAppSecretStore()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,"options":[
          {"key":"theme","type":"text","default":"dark"},
          {"key":"token","type":"secret"},
          {"key":"hostToken","type":"text","serverOnly":true}
        ]}
        """)
        let store = DropInAppStore(rootURL: root, defaults: defaults, secretStore: secretStore)
        let app = try XCTUnwrap(store.apps.first)
        store.setOptionValue(appID: "clock", optionKey: "theme", value: "light")
        for option in app.manifest.options {
            if option.key == "token" {
                store.setOptionValue(appID: "clock", option: option, value: "stored-secret")
            } else if option.key == "hostToken" {
                store.setOptionValue(appID: "clock", option: option, value: "server-secret")
            }
        }
        let server = DropInAppLoopbackServer(store: store)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appProxyConfigURL(port: port))
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("http://127.0.0.1:\(port)/apps/clock/index.html", forHTTPHeaderField: "Referer")
        let done = expectation(description: "app proxy config response")

        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
            let api = json?["api"] as? [String: String]
            let options = json?["options"] as? [String: Any]
            XCTAssertEqual(json?["app"] as? String, "clock")
            XCTAssertEqual(api?["config"], "/app-proxy/config")
            XCTAssertEqual(options?["theme"] as? String, "light")
            XCTAssertEqual(options?["token"] as? String, "stored-secret")
            XCTAssertEqual(options?["hostToken"] as? String, "server-secret")
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
    }

    func testLoopbackServerRejectsProxyConfigWithoutRequestingAppReferer() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true}
        """)
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root))
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appProxyConfigURL(port: port))
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        let done = expectation(description: "app proxy config rejection")

        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
    }

    func testLoopbackServerProxiesAllowedSameOriginAppRequest() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,
         "proxy":{"methods":["GET"],"allow":[{"pattern":"^https://api\\\\.example\\\\.com/"}]}}
        """)
        let fetcher = ProxyFetchRecorder(response: DropInAppProxyResponse(
            status: 200,
            contentType: "application/json",
            body: Data(#"{"ok":true}"#.utf8)
        ))
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root),
                                             fetchProxyURL: fetcher.fetch)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appProxyURL(port: port, targetURL: "https://api.example.com/data"))
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("http://127.0.0.1:\(port)/apps/clock/index.html", forHTTPHeaderField: "Referer")
        let done = expectation(description: "app proxy response")

        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
                           "application/json")
            XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), #"{"ok":true}"#)
            XCTAssertEqual(fetcher.urls.map(\.absoluteString), ["https://api.example.com/data"])
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
    }

    func testLoopbackServerRejectsDisallowedProxyRequest() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,
         "proxy":{"methods":["GET"],"allow":[{"pattern":"^https://api\\\\.example\\\\.com/"}]}}
        """)
        let fetcher = ProxyFetchRecorder(response: DropInAppProxyResponse(
            status: 200,
            contentType: "text/plain",
            body: Data("ok".utf8)
        ))
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root),
                                             fetchProxyURL: fetcher.fetch)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appProxyURL(port: port, targetURL: "https://evil.example.com/data"))
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("http://127.0.0.1:\(port)/apps/clock/index.html", forHTTPHeaderField: "Referer")
        let done = expectation(description: "app proxy rejection")

        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
            XCTAssertTrue(fetcher.urls.isEmpty)
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

    func testLoopbackServerOpensActionStyleSameOriginHTTPURL() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true}
        """)
        let recorder = URLRecorder()
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root), openURL: recorder.open)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appAPIActionURL(port: port,
                                                          action: "open",
                                                          targetURL: "https://example.com/path?q=1"))
        request.httpMethod = "POST"
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("http://127.0.0.1:\(port)/apps/clock/index.html", forHTTPHeaderField: "Referer")
        let done = expectation(description: "action-style app open response")

        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
            XCTAssertEqual(recorder.urls.map(\.absoluteString), ["https://example.com/path?q=1"])
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
    }

    func testLoopbackServerDispatchesServerActionWithContext() throws {
        let root = temporaryDirectory()
        let secretStore = MemoryDropInAppSecretStore()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,"server":"server.js","options":[
          {"key":"host","type":"text","default":"https://default.example"},
          {"key":"enabled","type":"bool","default":false},
          {"key":"token","type":"secret"},
          {"key":"hostToken","type":"text","serverOnly":true}
        ]}
        """, extraFiles: ["server.js": ""])
        let store = DropInAppStore(rootURL: root, secretStore: secretStore)
        let app = try XCTUnwrap(store.app(id: "clock"))
        for option in app.manifest.options {
            switch option.key {
            case "host":
                store.setOptionValue(appID: app.id, option: option, value: "https://configured.example")
            case "enabled":
                store.setOptionValue(appID: app.id, option: option, value: "true")
            case "token":
                store.setOptionValue(appID: app.id, option: option, value: "secret-token")
            case "hostToken":
                store.setOptionValue(appID: app.id, option: option, value: "server-token")
            default:
                break
            }
        }
        let recorder = ServerActionRecorder(response: try .json(["ok": true, "count": 2]))
        let server = DropInAppLoopbackServer(store: store, handleServerAction: recorder.handle)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appAPIActionURL(port: port,
                                                          action: "feed",
                                                          queryItems: [
                                                            URLQueryItem(name: "limit", value: "5"),
                                                            URLQueryItem(name: "empty", value: nil)
                                                          ]))
        request.httpMethod = "POST"
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("http://127.0.0.1:\(port)/apps/clock/index.html", forHTTPHeaderField: "Referer")
        let done = expectation(description: "server action response")

        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let json = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            XCTAssertEqual(json?["ok"] as? Bool, true)
            XCTAssertEqual(json?["count"] as? Int, 2)
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
        let context = try XCTUnwrap(recorder.contexts.first)
        XCTAssertEqual(context.app.id, "clock")
        XCTAssertEqual(context.action, "feed")
        XCTAssertEqual(context.query["limit"], "5")
        XCTAssertEqual(context.query["empty"], "")
        XCTAssertEqual(context.options["host"] as? String, "https://configured.example")
        XCTAssertEqual(context.options["enabled"] as? Bool, true)
        XCTAssertEqual(context.options["token"] as? String, "secret-token")
        XCTAssertEqual(context.options["hostToken"] as? String, "server-token")
        XCTAssertEqual(context.serverModuleURL.lastPathComponent, "server.js")
    }

    func testLoopbackServerDoesNotDispatchServerActionWithoutServerModule() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true}
        """)
        let recorder = ServerActionRecorder(response: try .json(["ok": true]))
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root),
                                             handleServerAction: recorder.handle)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appAPIActionURL(port: port, action: "feed"))
        request.httpMethod = "POST"
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("http://127.0.0.1:\(port)/apps/clock/index.html", forHTTPHeaderField: "Referer")
        let done = expectation(description: "missing server action response")

        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
        XCTAssertTrue(recorder.contexts.isEmpty)
    }

    func testLoopbackServerReturnsJSONErrorWhenServerActionFails() throws {
        struct TestServerActionError: LocalizedError {
            var errorDescription: String? { "boom" }
        }

        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,"server":"server.js"}
        """, extraFiles: ["server.js": ""])
        let recorder = ServerActionRecorder(error: TestServerActionError())
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root),
                                             handleServerAction: recorder.handle)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appAPIActionURL(port: port, action: "feed"))
        request.httpMethod = "POST"
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("http://127.0.0.1:\(port)/apps/clock/index.html", forHTTPHeaderField: "Referer")
        let done = expectation(description: "failed server action response")

        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 500)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
                           "application/json; charset=utf-8")
            let json = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            XCTAssertEqual(json?["ok"] as? Bool, false)
            XCTAssertEqual(json?["error"] as? String, "boom")
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
        XCTAssertEqual(recorder.contexts.map(\.action), ["feed"])
    }

    func testNodeServerActionHandlerSendsContextToNodeRunner() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,"server":"server.js"}
        """, extraFiles: ["server.js": ""])
        let store = DropInAppStore(rootURL: root)
        let app = try XCTUnwrap(store.app(id: "clock"))
        let node = URL(fileURLWithPath: "/tmp/fake-node")
        let runner = NodeRunnerRecorder(output: Data(#"{"ok":true,"items":[1,2]}"#.utf8))
        let handler = DropInAppNodeServerActionHandler(nodeURL: node,
                                                       timeout: 3,
                                                       runner: runner.run)
        let context = DropInAppServerActionContext(app: app,
                                                   action: "feed",
                                                   query: ["limit": "5"],
                                                   options: ["enabled": true, "token": "secret"],
                                                   serverModuleURL: app.rootURL.appendingPathComponent("server.js"))

        let result = try XCTUnwrap(handler.handle(context))

        guard case .success(let response) = result else {
            return XCTFail("Expected successful Node response")
        }
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.contentType, "application/json; charset=utf-8")
        let responseJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(responseJSON["ok"] as? Bool, true)
        XCTAssertEqual(responseJSON["items"] as? [Int], [1, 2])

        XCTAssertEqual(runner.nodeURL, node)
        XCTAssertEqual(runner.currentDirectoryURL, app.rootURL)
        XCTAssertEqual(runner.timeout, 3)
        let input = try XCTUnwrap(runner.inputJSON)
        XCTAssertEqual(input["appId"] as? String, "clock")
        XCTAssertEqual(input["action"] as? String, "feed")
        XCTAssertEqual((input["query"] as? [String: String])?["limit"], "5")
        let options = try XCTUnwrap(input["options"] as? [String: Any])
        XCTAssertEqual(options["enabled"] as? Bool, true)
        XCTAssertEqual(options["token"] as? String, "secret")
        XCTAssertEqual(input["serverModule"] as? String, app.rootURL.appendingPathComponent("server.js").path)
    }

    func testNodeServerActionHandlerMapsOkFalseToBadRequest() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,"server":"server.js"}
        """, extraFiles: ["server.js": ""])
        let app = try XCTUnwrap(DropInAppStore(rootURL: root).app(id: "clock"))
        let runner = NodeRunnerRecorder(output: Data(#"{"ok":false,"error":"unknown action"}"#.utf8))
        let handler = DropInAppNodeServerActionHandler(nodeURL: URL(fileURLWithPath: "/tmp/fake-node"),
                                                       runner: runner.run)
        let context = DropInAppServerActionContext(app: app,
                                                   action: "feed",
                                                   query: [:],
                                                   options: [:],
                                                   serverModuleURL: app.rootURL.appendingPathComponent("server.js"))

        let result = try XCTUnwrap(handler.handle(context))

        guard case .success(let response) = result else {
            return XCTFail("Expected handled Node response")
        }
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), #"{"ok":false,"error":"unknown action"}"#)
    }

    func testNodeServerActionHandlerReturnsFailureWhenNodeIsUnavailable() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true,"server":"server.js"}
        """, extraFiles: ["server.js": ""])
        let app = try XCTUnwrap(DropInAppStore(rootURL: root).app(id: "clock"))
        let handler = DropInAppNodeServerActionHandler(nodeURL: nil)
        let context = DropInAppServerActionContext(app: app,
                                                   action: "feed",
                                                   query: [:],
                                                   options: [:],
                                                   serverModuleURL: app.rootURL.appendingPathComponent("server.js"))

        let result = try XCTUnwrap(handler.handle(context))

        guard case .failure(let error) = result else {
            return XCTFail("Expected missing Node failure")
        }
        XCTAssertEqual(error as? DropInAppNodeServerActionError, .nodeUnavailable)
    }

    func testNodeRuntimeStatusResolvesExplicitNodePath() throws {
        let node = try temporaryExecutable(named: "custom-node")

        let status = DropInAppNodeServerActionHandler.runtimeStatus(
            environment: ["QUAKEOS_NODE_PATH": node.path, "PATH": ""],
            standardCandidatePaths: []
        )

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.nodeURL, node)
        XCTAssertEqual(status.displayPath, node.path)
    }

    func testNodeRuntimeStatusResolvesPathNode() throws {
        let bin = temporaryDirectory()
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = try temporaryExecutable(named: "node", in: bin)

        let status = DropInAppNodeServerActionHandler.runtimeStatus(
            environment: ["PATH": bin.path],
            standardCandidatePaths: []
        )

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.nodeURL, node)
    }

    func testNodeRuntimeStatusReportsMissingNode() {
        let status = DropInAppNodeServerActionHandler.runtimeStatus(
            environment: ["PATH": ""],
            standardCandidatePaths: []
        )

        XCTAssertFalse(status.isAvailable)
        XCTAssertNil(status.nodeURL)
        XCTAssertEqual(status.displayPath, "Node runtime not found")
    }

    func testLoopbackServerRejectsActionStyleOpenWithoutRequestingAppReferer() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true}
        """)
        let recorder = URLRecorder()
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root), openURL: recorder.open)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appAPIActionURL(port: port,
                                                          action: "open",
                                                          targetURL: "https://example.com"))
        request.httpMethod = "POST"
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        let done = expectation(description: "action-style app open rejection")

        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
            XCTAssertTrue(recorder.urls.isEmpty)
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 3)
    }

    func testLoopbackServerRejectsUnknownAppAPIAction() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","served":true}
        """)
        let recorder = URLRecorder()
        let server = DropInAppLoopbackServer(store: DropInAppStore(rootURL: root), openURL: recorder.open)
        defer { server.stop() }

        server.start()
        let port = try waitForPort(server)
        var request = URLRequest(url: try appAPIActionURL(port: port,
                                                          action: "feed",
                                                          targetURL: "https://example.com"))
        request.httpMethod = "POST"
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("http://127.0.0.1:\(port)/apps/clock/index.html", forHTTPHeaderField: "Referer")
        let done = expectation(description: "unknown app action rejection")

        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            XCTAssertTrue(recorder.urls.isEmpty)
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

    func testImportFolderCanForceIDForDuplicateApp() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "installed", manifest: """
        {"id":"clock","entry":"index.html"}
        """)
        let sourceRoot = temporaryDirectory()
        try writeApp(root: sourceRoot, folder: "source", manifest: """
        {"id":"clock","name":"Clock","entry":"index.html"}
        """, extraFiles: ["assets/style.css": "body{}"])
        let source = sourceRoot.appendingPathComponent("source", isDirectory: true)
        let store = DropInAppStore(rootURL: root)

        let result = store.importFolder(at: source, forceID: "clock-copy")

        guard case .success(let app) = result else {
            return XCTFail("Expected forced-ID import")
        }
        XCTAssertEqual(app.id, "clock-copy")
        XCTAssertEqual(store.apps.map(\.id), ["clock-copy", "clock"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("clock-copy/assets/style.css").path))
        XCTAssertEqual(try readManifestID(at: root.appendingPathComponent("clock-copy/app.json")), "clock-copy")
        XCTAssertEqual(try readManifestID(at: source.appendingPathComponent("app.json")), "clock")
    }

    func testImportFolderRejectsInvalidForcedID() throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        try writeApp(root: sourceRoot, folder: "source", manifest: """
        {"id":"clock","entry":"index.html"}
        """)
        let store = DropInAppStore(rootURL: root)

        let result = store.importFolder(at: sourceRoot.appendingPathComponent("source", isDirectory: true),
                                        forceID: "Bad App")

        XCTAssertEqual(result, .failure(.invalidSource("Invalid app id \"Bad App\".")))
        XCTAssertTrue(store.apps.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Bad App").path))
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

    func testImportArchiveCanForceIDForDuplicateApp() throws {
        let root = temporaryDirectory()
        try writeApp(root: root, folder: "installed", manifest: """
        {"id":"clock","entry":"index.html"}
        """)
        let sourceRoot = temporaryDirectory()
        try writeApp(root: sourceRoot, folder: "Clock Source", manifest: """
        {"id":"clock","name":"Clock","entry":"index.html"}
        """)
        let archive = temporaryDirectory().appendingPathExtension("zip")
        try createZip(from: sourceRoot.appendingPathComponent("Clock Source", isDirectory: true),
                      to: archive,
                      keepParent: true)
        let store = DropInAppStore(rootURL: root)

        let result = store.importArchive(at: archive, forceID: "clock-copy")

        guard case .success(let app) = result else {
            return XCTFail("Expected forced-ID archive import")
        }
        XCTAssertEqual(app.id, "clock-copy")
        XCTAssertEqual(try readManifestID(at: root.appendingPathComponent("clock-copy/app.json")), "clock-copy")
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
        let secretStore = MemoryDropInAppSecretStore()
        try writeApp(root: root, folder: "clock", manifest: """
        {"id":"clock","entry":"index.html","options":[
          {"key":"theme","type":"text","default":"dark"},
          {"key":"token","type":"secret"}
        ]}
        """)
        let store = DropInAppStore(rootURL: root, defaults: defaults, secretStore: secretStore)
        let app = try XCTUnwrap(store.apps.first)
        let token = try XCTUnwrap(app.manifest.options.first { $0.key == "token" })
        store.setOptionValue(appID: "clock", optionKey: "theme", value: "light")
        store.setOptionValue(appID: "clock", option: token, value: "abc123")

        let result = store.removeApp(id: "clock")

        guard case .success = result else {
            return XCTFail("Expected successful removal")
        }
        XCTAssertTrue(store.apps.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("clock").path))
        XCTAssertNil(store.optionValuesByAppID["clock"])
        XCTAssertNil(try secretStore.get(appID: "clock", field: "token"))
        let reloaded = DropInAppStore(rootURL: root, defaults: defaults, secretStore: secretStore)
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

    private func temporaryExecutable(named name: String, in directory: URL? = nil) throws -> URL {
        let root = directory ?? temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
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

    private func appAPIActionURL(port: UInt16, action: String, targetURL: String) throws -> URL {
        try appAPIActionURL(port: port,
                            action: action,
                            queryItems: [URLQueryItem(name: "url", value: targetURL)])
    }

    private func appAPIActionURL(port: UInt16,
                                 action: String,
                                 queryItems: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/app-api/\(action)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return try XCTUnwrap(components.url)
    }

    private func appProxyConfigURL(port: UInt16) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/app-proxy/config"
        return try XCTUnwrap(components.url)
    }

    private func appProxyURL(port: UInt16, targetURL: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/app-proxy"
        components.queryItems = [
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

    private func readManifestID(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(DropInAppManifest.self, from: data)
        return manifest.id
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

private final class ProxyFetchRecorder {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []
    private let response: DropInAppProxyResponse

    init(response: DropInAppProxyResponse) {
        self.response = response
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    func fetch(_ url: URL) -> Result<DropInAppProxyResponse, Error> {
        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
        return .success(response)
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

private final class ServerActionRecorder {
    private let lock = NSLock()
    private var recordedContexts: [DropInAppServerActionContext] = []
    private let response: DropInAppServerActionResponse?
    private let error: Error?

    init(response: DropInAppServerActionResponse? = nil, error: Error? = nil) {
        self.response = response
        self.error = error
    }

    var contexts: [DropInAppServerActionContext] {
        lock.lock()
        defer { lock.unlock() }
        return recordedContexts
    }

    func handle(_ context: DropInAppServerActionContext) -> Result<DropInAppServerActionResponse, Error>? {
        lock.lock()
        recordedContexts.append(context)
        lock.unlock()
        if let error {
            return .failure(error)
        }
        guard let response else { return nil }
        return .success(response)
    }
}

private final class NodeRunnerRecorder {
    private(set) var nodeURL: URL?
    private(set) var currentDirectoryURL: URL?
    private(set) var input: Data?
    private(set) var timeout: TimeInterval?
    private let output: Data

    init(output: Data) {
        self.output = output
    }

    var inputJSON: [String: Any]? {
        guard let input else { return nil }
        return try? JSONSerialization.jsonObject(with: input) as? [String: Any]
    }

    func run(nodeURL: URL,
             currentDirectoryURL: URL,
             input: Data,
             timeout: TimeInterval) -> Result<Data, Error> {
        self.nodeURL = nodeURL
        self.currentDirectoryURL = currentDirectoryURL
        self.input = input
        self.timeout = timeout
        return .success(output)
    }
}

private final class MemoryDropInAppSecretStore: DropInAppSecretStoring {
    private var values: [String: String] = [:]

    func set(_ value: String, appID: String, field: String) throws {
        values[key(appID: appID, field: field)] = value
    }

    func get(appID: String, field: String) throws -> String? {
        values[key(appID: appID, field: field)]
    }

    func delete(appID: String, field: String) throws {
        values[key(appID: appID, field: field)] = nil
    }

    func deleteAll(appID: String) throws {
        values = values.filter { !$0.key.hasPrefix("\(appID):") }
    }

    private func key(appID: String, field: String) -> String {
        "\(appID):\(field)"
    }
}
