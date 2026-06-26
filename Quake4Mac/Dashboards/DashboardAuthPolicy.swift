import Foundation

struct DashboardAuthPolicy {
    let dashboard: DashboardConfig
    let auth: DashboardResolvedAuth

    func headers(for url: URL?) -> [String: String] {
        guard matchesDashboardHost(url) else { return [:] }

        switch auth.kind {
        case .none:
            return [:]
        case .homeAssistant:
            guard let token = auth.homeAssistantToken, !token.isEmpty else { return [:] }
            return ["Authorization": "Bearer \(token)"]
        case .basic:
            guard let password = auth.basicPassword else { return [:] }
            let credential = "\(auth.username):\(password)"
            let encoded = Data(credential.utf8).base64EncodedString()
            return ["Authorization": "Basic \(encoded)"]
        case .customHeaders:
            var headers: [String: String] = [:]
            for header in auth.headers {
                headers[header.name] = header.value
            }
            return headers
        }
    }

    func requestByApplyingAuth(to request: URLRequest) -> URLRequest {
        let headers = headers(for: request.url)
        guard !headers.isEmpty else { return request }

        var next = request
        for (name, value) in headers {
            next.setValue(value, forHTTPHeaderField: name)
        }
        return next
    }

    func requestNeedsAuth(_ request: URLRequest) -> Bool {
        let headers = headers(for: request.url)
        guard !headers.isEmpty else { return false }
        for name in headers.keys where request.value(forHTTPHeaderField: name) == nil {
            return true
        }
        return false
    }

    func basicCredential(for host: String) -> URLCredential? {
        guard auth.kind == .basic,
              host.lowercased() == dashboard.host,
              let password = auth.basicPassword else { return nil }
        return URLCredential(user: auth.username, password: password, persistence: .forSession)
    }

    private func matchesDashboardHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), let dashboardHost = dashboard.host else { return false }
        return host == dashboardHost
    }
}
