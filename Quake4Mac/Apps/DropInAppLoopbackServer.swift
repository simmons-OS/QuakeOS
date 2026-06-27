import AppKit
import Foundation
import Network

struct DropInAppProxyResponse {
    let status: Int
    let contentType: String
    let body: Data
}

enum DropInAppProxyFetchError: Error {
    case timeout
    case nonHTTPResponse
    case responseTooLarge
}

private final class DropInAppProxyURLSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

struct DropInAppAPIActionRequest: Equatable {
    let action: String
    let query: [String: String]
    let url: URL?
}

struct DropInAppServerActionContext {
    let app: DropInAppRecord
    let action: String
    let query: [String: String]
    let options: [String: Any]
    let serverModuleURL: URL
}

struct DropInAppServerActionResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ object: Any, status: Int = 200) throws -> DropInAppServerActionResponse {
        DropInAppServerActionResponse(status: status,
                                      contentType: "application/json; charset=utf-8",
                                      body: try JSONSerialization.data(withJSONObject: object,
                                                                       options: [.sortedKeys]))
    }
}

typealias DropInAppServerActionHandler =
    (DropInAppServerActionContext) -> Result<DropInAppServerActionResponse, Error>?

struct DropInAppNodeRuntimeStatus: Equatable {
    let nodeURL: URL?

    var isAvailable: Bool { nodeURL != nil }
    var displayPath: String { nodeURL?.path ?? "Node runtime not found" }
}

enum DropInAppNodeServerActionError: LocalizedError, Equatable {
    case nodeUnavailable
    case launchFailed(String)
    case timedOut
    case executionFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .nodeUnavailable:
            return "Node runtime unavailable. Set QUAKEOS_NODE_PATH or install node to enable drop-in server modules."
        case .launchFailed(let message):
            return "Could not launch Node runtime: \(message)"
        case .timedOut:
            return "Drop-in server module timed out."
        case .executionFailed(let message):
            return message.isEmpty ? "Drop-in server module failed." : message
        case .invalidResponse(let message):
            return "Drop-in server module returned invalid JSON: \(message)"
        }
    }
}

final class DropInAppNodeServerActionHandler {
    typealias Runner = (_ nodeURL: URL, _ currentDirectoryURL: URL, _ input: Data, _ timeout: TimeInterval) -> Result<Data, Error>

    static let shared = DropInAppNodeServerActionHandler()
    static let defaultTimeout: TimeInterval = 12

    private let nodeURL: URL?
    private let runner: Runner
    private let timeout: TimeInterval

    init(nodeURL: URL? = DropInAppNodeServerActionHandler.resolveNodeURL(),
         timeout: TimeInterval = DropInAppNodeServerActionHandler.defaultTimeout,
         runner: @escaping Runner = { nodeURL, currentDirectoryURL, input, timeout in
             DropInAppNodeServerActionHandler.runNode(nodeURL: nodeURL,
                                                      currentDirectoryURL: currentDirectoryURL,
                                                      input: input,
                                                      timeout: timeout)
         }) {
        self.nodeURL = nodeURL
        self.timeout = timeout
        self.runner = runner
    }

    func handle(_ context: DropInAppServerActionContext) -> Result<DropInAppServerActionResponse, Error>? {
        guard let nodeURL else { return .failure(DropInAppNodeServerActionError.nodeUnavailable) }
        do {
            let input = try inputData(for: context)
            return runner(nodeURL, context.app.rootURL, input, timeout)
                .flatMap { output in Self.response(from: output) }
        } catch {
            return .failure(error)
        }
    }

    static func resolveNodeURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                               standardCandidatePaths: [String] = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"],
                               fileManager: FileManager = .default) -> URL? {
        var candidates: [String] = []
        if let explicit = environment["QUAKEOS_NODE_PATH"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        candidates.append(contentsOf: standardCandidatePaths)
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/node" })
        }

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func runtimeStatus(environment: [String: String] = ProcessInfo.processInfo.environment,
                              standardCandidatePaths: [String] = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"],
                              fileManager: FileManager = .default) -> DropInAppNodeRuntimeStatus {
        DropInAppNodeRuntimeStatus(nodeURL: resolveNodeURL(environment: environment,
                                                           standardCandidatePaths: standardCandidatePaths,
                                                           fileManager: fileManager))
    }

    private func inputData(for context: DropInAppServerActionContext) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "appId": context.app.id,
            "action": context.action,
            "query": context.query,
            "options": context.options,
            "serverModule": context.serverModuleURL.path
        ], options: [.sortedKeys])
    }

    private static func response(from output: Data) -> Result<DropInAppServerActionResponse, Error> {
        let body = output.isEmpty ? Data("null".utf8) : output
        do {
            let object = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
            let status = (object as? [String: Any])?["ok"] as? Bool == false ? 400 : 200
            return .success(DropInAppServerActionResponse(status: status,
                                                          contentType: "application/json; charset=utf-8",
                                                          body: body))
        } catch {
            return .failure(DropInAppNodeServerActionError.invalidResponse(error.localizedDescription))
        }
    }

    private static func runNode(nodeURL: URL,
                                currentDirectoryURL: URL,
                                input: Data,
                                timeout: TimeInterval) -> Result<Data, Error> {
        let process = Process()
        process.executableURL = nodeURL
        process.currentDirectoryURL = currentDirectoryURL
        process.arguments = ["-e", bootstrapSource]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        } catch {
            return .failure(DropInAppNodeServerActionError.launchFailed(error.localizedDescription))
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .failure(DropInAppNodeServerActionError.timedOut)
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            return .failure(DropInAppNodeServerActionError.executionFailed(message))
        }
        return .success(output)
    }

    private static let bootstrapSource = #"""
    const fs = require('fs');

    (async () => {
      const input = JSON.parse(fs.readFileSync(0, 'utf8'));
      const mod = require(input.serverModule);
      if (!mod || typeof mod.handle !== 'function') {
        throw new Error('server module must export handle(action, context)');
      }
      const result = await mod.handle(input.action, {
        appId: input.appId,
        query: input.query || {},
        options: input.options || {}
      });
      process.stdout.write(JSON.stringify(result === undefined ? null : result));
    })().catch((error) => {
      process.stderr.write(error && error.stack ? error.stack : String(error));
      process.exit(1);
    });
    """#
}

final class DropInAppLoopbackServer: ObservableObject {
    static let shared = DropInAppLoopbackServer(handleServerAction: DropInAppNodeServerActionHandler.shared.handle)
    static let maxProxyResponseSize = 5 * 1024 * 1024

    @Published private(set) var port: UInt16?
    @Published private(set) var lastError = ""

    private let store: DropInAppStore
    private let openURL: (URL) -> Bool
    private let fetchProxyURL: (URL, Bool) -> Result<DropInAppProxyResponse, Error>
    private let handleServerAction: DropInAppServerActionHandler
    private let queue = DispatchQueue(label: "quakeos.dropin.loopback")
    private var listener: NWListener?

    init(store: DropInAppStore = .shared,
         openURL: @escaping (URL) -> Bool = DropInAppLoopbackServer.openExternally,
         fetchProxyURL: @escaping (URL, Bool) -> Result<DropInAppProxyResponse, Error> = DropInAppLoopbackServer.fetchProxyURL,
         handleServerAction: @escaping DropInAppServerActionHandler = { _ in nil }) {
        self.store = store
        self.openURL = openURL
        self.fetchProxyURL = fetchProxyURL
        self.handleServerAction = handleServerAction
    }

    func start() {
        if listener != nil { return }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                           port: NWEndpoint.Port(rawValue: 0)!)
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.lastError = ""
                        self?.port = listener?.port?.rawValue
                    case .failed(let error):
                        self?.lastError = error.localizedDescription
                        self?.port = nil
                        self?.listener?.cancel()
                        self?.listener = nil
                    case .cancelled:
                        self?.port = nil
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            lastError = error.localizedDescription
            port = nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let response = self.response(for: data ?? Data())
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for requestData: Data) -> Data {
        guard let request = String(data: requestData, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            return Self.response(status: 400)
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return Self.response(status: 400) }
        let method = String(parts[0])
        guard Self.hostIsLoopback(request: request, port: port) else { return Self.response(status: 403) }

        let target = String(parts[1])
        if let openRequest = Self.appOpenRequest(target) {
            guard method == "POST" else { return Self.response(status: 405) }
            return appOpenResponse(appID: openRequest.appID, url: openRequest.url, request: request)
        }

        if let apiRequest = Self.appAPIActionRequest(target) {
            guard method == "POST" else { return Self.response(status: 405) }
            return appAPIActionResponse(apiRequest, request: request)
        }

        if Self.isAppProxyConfigRequest(target) {
            guard method == "GET" else { return Self.response(status: 405) }
            return appProxyConfigResponse(request: request)
        }

        if let proxyTarget = Self.appProxyTarget(target) {
            guard method == "GET" else { return Self.response(status: 405) }
            return appProxyResponse(target: proxyTarget, request: request)
        }

        guard method == "GET" else { return Self.response(status: 405) }
        if let appID = Self.appConfigAppID(target) {
            return appConfigResponse(appID: appID, request: request)
        }

        guard let request = Self.servedAppRequest(target) else { return Self.response(status: 404) }
        guard let app = store.app(id: request.appID), app.manifest.served else { return Self.response(status: 404) }
        guard let fileURL = DropInAppStore.containedURL(root: app.rootURL, relativePath: request.relativePath) else {
            return Self.response(status: 403)
        }

        do {
            let body = try Data(contentsOf: fileURL)
            return Self.response(status: 200, body: body, contentType: Self.mimeType(for: fileURL))
        } catch {
            return Self.response(status: (error as NSError).code == NSFileReadNoSuchFileError ? 404 : 500)
        }
    }

    private func appAPIActionResponse(_ apiRequest: DropInAppAPIActionRequest, request: String) -> Data {
        guard Self.isSameOrigin(request: request, port: port),
              let appID = Self.requestingAppID(request: request, port: port) else { return Self.response(status: 403) }
        guard let app = store.app(id: appID), app.manifest.served else { return Self.response(status: 404) }

        if let context = serverActionContext(app: app, request: apiRequest),
           let result = handleServerAction(context) {
            switch result {
            case .success(let response):
                return Self.response(status: response.status,
                                     body: response.body,
                                     contentType: response.contentType)
            case .failure(let error):
                return Self.response(status: 500,
                                     body: Self.appAPIErrorBody(error.localizedDescription),
                                     contentType: "application/json; charset=utf-8")
            }
        }

        switch apiRequest.action {
        case "open":
            guard let url = apiRequest.url else { return Self.response(status: 400) }
            return openURL(url) ? Self.response(status: 204) : Self.response(status: 500)
        default:
            return Self.response(status: 404)
        }
    }

    private func serverActionContext(app: DropInAppRecord,
                                     request: DropInAppAPIActionRequest) -> DropInAppServerActionContext? {
        guard let serverPath = app.manifest.server,
              let serverURL = DropInAppStore.containedURL(root: app.rootURL, relativePath: serverPath) else {
            return nil
        }
        return DropInAppServerActionContext(app: app,
                                            action: request.action,
                                            query: request.query,
                                            options: store.proxyConfigPayload(for: app)["options"] as? [String: Any] ?? [:],
                                            serverModuleURL: serverURL)
    }

    private func appProxyConfigResponse(request: String) -> Data {
        guard Self.isSameOrigin(request: request, port: port),
              let appID = Self.requestingAppID(request: request, port: port) else { return Self.response(status: 403) }
        guard let app = store.app(id: appID), app.manifest.served else { return Self.response(status: 404) }
        do {
            let body = try JSONSerialization.data(withJSONObject: store.proxyConfigPayload(for: app),
                                                  options: [.sortedKeys])
            return Self.response(status: 200, body: body, contentType: "application/json; charset=utf-8")
        } catch {
            return Self.response(status: 500)
        }
    }

    private func appProxyResponse(target: URL, request: String) -> Data {
        guard Self.isSameOrigin(request: request, port: port),
              let appID = Self.requestingAppID(request: request, port: port) else { return Self.response(status: 403) }
        guard let app = store.app(id: appID), app.manifest.served else { return Self.response(status: 404) }
        guard proxyAllows(app: app, target: target) else { return Self.response(status: 403) }

        switch fetchProxyURL(target, verifySSL(for: app)) {
        case .success(let upstream):
            guard upstream.body.count <= Self.maxProxyResponseSize else { return Self.response(status: 502) }
            return Self.response(status: upstream.status,
                                 body: upstream.body,
                                 contentType: upstream.contentType)
        case .failure:
            return Self.response(status: 502)
        }
    }

    private func verifySSL(for app: DropInAppRecord) -> Bool {
        guard let optionKey = app.manifest.proxy?.verifySslOption,
              let option = app.manifest.options.first(where: { $0.key == optionKey }) else { return true }
        return store.optionValue(appID: app.id, option: option)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() != "false"
    }

    private func appOpenResponse(appID: String, url: URL, request: String) -> Data {
        guard Self.isSameOrigin(request: request, port: port) else { return Self.response(status: 403) }
        guard let app = store.app(id: appID), app.manifest.served else { return Self.response(status: 404) }
        return openURL(url) ? Self.response(status: 204) : Self.response(status: 500)
    }

    private func appConfigResponse(appID: String, request: String) -> Data {
        guard Self.isSameOrigin(request: request, port: port) else { return Self.response(status: 403) }
        guard let app = store.app(id: appID), app.manifest.served else { return Self.response(status: 404) }
        do {
            let body = try JSONSerialization.data(withJSONObject: store.clientConfigPayload(for: app),
                                                  options: [.sortedKeys])
            return Self.response(status: 200, body: body, contentType: "application/json; charset=utf-8")
        } catch {
            return Self.response(status: 500)
        }
    }

    private func proxyAllows(app: DropInAppRecord, target: URL) -> Bool {
        guard let proxy = app.manifest.proxy,
              Self.proxyAllowsGET(proxy),
              !proxy.allow.isEmpty else { return false }

        return proxy.allow.contains { rule in
            if let optionKey = rule.option,
               let option = app.manifest.options.first(where: { $0.key == optionKey }) {
                return Self.proxyOptionRuleAllows(baseValue: store.optionValue(appID: app.id, option: option),
                                                  target: target)
            }

            if let pattern = rule.pattern {
                return Self.proxyPatternRuleAllows(pattern: pattern, target: target)
            }

            return false
        }
    }

    static func appConfigAppID(_ target: String) -> String? {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              components.path == "/app-config",
              let appID = components.queryItems?.first(where: { $0.name == "app" })?.value,
              DropInAppStore.isValidAppID(appID) else { return nil }
        return appID
    }

    static func appAPIActionRequest(_ target: String) -> DropInAppAPIActionRequest? {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else { return nil }
        let prefix = "/app-api/"
        guard components.path.hasPrefix(prefix) else { return nil }
        let action = String(components.path.dropFirst(prefix.count))
        guard action.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil else { return nil }
        return DropInAppAPIActionRequest(action: action,
                                         query: appAPIQueryValues(from: components.queryItems),
                                         url: appAPIURLValue(from: components.queryItems))
    }

    static func isAppProxyConfigRequest(_ target: String) -> Bool {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else { return false }
        return components.path == "/app-proxy/config"
    }

    static func appProxyTarget(_ target: String) -> URL? {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              components.path == "/app-proxy",
              let target = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: target),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else { return nil }
        return url
    }

    static func appOpenRequest(_ target: String) -> (appID: String, url: URL)? {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              components.path == "/app-api/open",
              let appID = components.queryItems?.first(where: { $0.name == "app" })?.value,
              DropInAppStore.isValidAppID(appID),
              let url = appAPIURLValue(from: components.queryItems) else { return nil }
        return (appID, url)
    }

    private static func appAPIURLValue(from queryItems: [URLQueryItem]?) -> URL? {
        guard let target = queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: target),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else { return nil }
        return url
    }

    private static func appAPIQueryValues(from queryItems: [URLQueryItem]?) -> [String: String] {
        var values: [String: String] = [:]
        for item in queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        return values
    }

    static func servedAppRequest(_ target: String) -> (appID: String, relativePath: String)? {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else { return nil }
        let path = components.percentEncodedPath
        let prefix = "/apps/"
        guard path.hasPrefix(prefix) else { return nil }
        let remainder = String(path.dropFirst(prefix.count))
        let split = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard split.count == 2,
              let appID = split.first.map(String.init),
              DropInAppStore.isValidAppID(appID),
              let encodedRelativePath = split.last.map(String.init),
              let relativePath = encodedRelativePath.removingPercentEncoding,
              !relativePath.isEmpty else { return nil }
        return (appID, relativePath)
    }

    static func requestingAppID(request: String, port: UInt16?) -> String? {
        guard let port,
              let referer = headerValue("Referer", in: request.components(separatedBy: "\r\n")),
              isLoopbackURL(referer, port: port),
              let url = URL(string: referer),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let appRequest = servedAppRequest(path) else { return nil }
        return appRequest.appID
    }

    static func hostIsLoopback(request: String, port: UInt16?) -> Bool {
        guard let port else { return false }
        let expected = ["127.0.0.1:\(port)", "localhost:\(port)"]
        return request.components(separatedBy: "\r\n").contains { line in
            let lower = line.lowercased()
            guard lower.hasPrefix("host:") else { return false }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return expected.contains(value)
        }
    }

    static func isSameOrigin(request: String, port: UInt16?) -> Bool {
        guard let port else { return false }
        let lines = request.components(separatedBy: "\r\n")
        if let site = headerValue("Sec-Fetch-Site", in: lines) {
            return site == "same-origin"
        }
        if let origin = headerValue("Origin", in: lines) {
            return isLoopbackURL(origin, port: port)
        }
        if let referer = headerValue("Referer", in: lines) {
            return isLoopbackURL(referer, port: port)
        }
        return false
    }

    static func proxyOptionRuleAllows(baseValue: String, target: URL) -> Bool {
        guard !baseValue.isEmpty,
              let base = URL(string: normalizedBaseURLString(baseValue)),
              sameOrigin(base, target),
              pathIsUnderBase(base: base, target: target) else { return false }
        return true
    }

    static func proxyPatternRuleAllows(pattern: String, target: URL) -> Bool {
        guard let host = target.host, !privateHost(host) else { return false }
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(target.absoluteString.startIndex..<target.absoluteString.endIndex,
                                in: target.absoluteString)
            return regex.firstMatch(in: target.absoluteString, range: range) != nil
        } catch {
            return false
        }
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        default: return "application/octet-stream"
        }
    }

    private static func openExternally(_ url: URL) -> Bool {
        if Thread.isMainThread {
            return NSWorkspace.shared.open(url)
        }
        var didOpen = false
        DispatchQueue.main.sync {
            didOpen = NSWorkspace.shared.open(url)
        }
        return didOpen
    }

    private static func fetchProxyURL(_ url: URL, verifySSL: Bool = true) -> Result<DropInAppProxyResponse, Error> {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("QuakeOS/DropInAppProxy", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/xml, text/xml, text/html, */*",
                         forHTTPHeaderField: "Accept")
        let session = proxyURLSession(verifySSL: verifySSL)
        defer { session.invalidateAndCancel() }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<DropInAppProxyResponse, Error>?
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let response = response as? HTTPURLResponse else {
                result = .failure(DropInAppProxyFetchError.nonHTTPResponse)
                return
            }
            let body = data ?? Data()
            guard body.count <= maxProxyResponseSize else {
                result = .failure(DropInAppProxyFetchError.responseTooLarge)
                return
            }
            result = .success(DropInAppProxyResponse(status: response.statusCode,
                                                     contentType: response.value(forHTTPHeaderField: "Content-Type")
                                                        ?? "application/octet-stream",
                                                     body: body))
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + 13) == .success else {
            task.cancel()
            return .failure(DropInAppProxyFetchError.timeout)
        }
        return result ?? .failure(DropInAppProxyFetchError.timeout)
    }

    private static func proxyURLSession(verifySSL: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        guard !verifySSL else { return URLSession(configuration: configuration) }
        return URLSession(configuration: configuration,
                          delegate: DropInAppProxyURLSessionDelegate(),
                          delegateQueue: nil)
    }

    private static func headerValue(_ name: String, in lines: [String]) -> String? {
        let prefix = "\(name.lowercased()):"
        return lines.first { $0.lowercased().hasPrefix(prefix) }?
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isLoopbackURL(_ value: String, port: UInt16) -> Bool {
        guard let url = URL(string: value),
              url.scheme == "http",
              let host = url.host?.lowercased(),
              (host == "127.0.0.1" || host == "localhost"),
              url.port == Int(port) else { return false }
        return true
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && normalizedPort(lhs) == normalizedPort(rhs)
    }

    private static func proxyAllowsGET(_ proxy: DropInAppProxyConfig) -> Bool {
        guard let methods = proxy.methods else { return true }
        return methods.contains { $0.uppercased() == "GET" }
    }

    private static func normalizedBaseURLString(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized + "/"
    }

    private static func normalizedPort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }

    private static func pathIsUnderBase(base: URL, target: URL) -> Bool {
        let basePath = base.path == "/" || base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard basePath != "/" else { return true }
        let baseWithoutSlash = String(basePath.dropLast())
        return target.path == baseWithoutSlash || target.path.hasPrefix(basePath)
    }

    private static func appAPIErrorBody(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message],
                                     options: [.sortedKeys])) ?? Data()
    }

    private static func privateHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if lower == "localhost" || lower == "::1" || lower.hasSuffix(".local") { return true }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("fe80") { return true }
        let parts = lower.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || parts[0] == 127 || parts[0] == 0 || parts[0] == 169 && parts[1] == 254 {
            return true
        }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }

    private static func response(status: Int, body: Data = Data(), contentType: String = "text/plain; charset=utf-8") -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 500: reason = "Internal Server Error"
        case 502: reason = "Bad Gateway"
        default: reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }

        let headers = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Content-Security-Policy: default-src 'self' http: https: file: data: blob:; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: file: http: https:; font-src 'self' data:; connect-src 'self' http: https:; media-src 'self' blob: data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r
        Connection: close\r
        \r

        """
        var data = Data(headers.utf8)
        data.append(body)
        return data
    }
}
