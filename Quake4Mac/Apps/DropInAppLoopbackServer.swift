import Foundation
import Network

final class DropInAppLoopbackServer: ObservableObject {
    static let shared = DropInAppLoopbackServer()

    @Published private(set) var port: UInt16?
    @Published private(set) var lastError = ""

    private let store: DropInAppStore
    private let queue = DispatchQueue(label: "quakeos.dropin.loopback")
    private var listener: NWListener?

    init(store: DropInAppStore = .shared) {
        self.store = store
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
        guard parts[0] == "GET" else { return Self.response(status: 405) }
        guard Self.hostIsLoopback(request: request, port: port) else { return Self.response(status: 403) }

        let target = String(parts[1])
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

    private static func response(status: Int, body: Data = Data(), contentType: String = "text/plain; charset=utf-8") -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Internal Server Error"
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
