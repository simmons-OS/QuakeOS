import Combine
import Foundation
import SwiftUI

enum DashboardAuthKind: String, Codable, CaseIterable, Identifiable {
    case none
    case homeAssistant
    case basic
    case customHeaders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .homeAssistant: return "Home Assistant"
        case .basic: return "HTTP Basic"
        case .customHeaders: return "Custom Headers"
        }
    }
}

struct DashboardHeader: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
}

struct DashboardAuthConfig: Codable, Equatable {
    var kind: DashboardAuthKind = .none
    var username: String = ""
    var headers: [DashboardHeader] = []
}

enum DashboardActionStripSide: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum DashboardSideActionKind: String, Codable, CaseIterable, Identifiable {
    case reload
    case back
    case forward
    case home
    case openURL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reload: return "Reload"
        case .back: return "Back"
        case .forward: return "Forward"
        case .home: return "Home"
        case .openURL: return "Open URL"
        }
    }

    var defaultSymbol: String {
        switch self {
        case .reload: return "arrow.clockwise"
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .home: return "house.fill"
        case .openURL: return "link"
        }
    }
}

struct DashboardSideAction: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var symbol: String
    var kind: DashboardSideActionKind
    var urlString: String = ""

    var url: URL? { URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) }

    static func defaultAction(kind: DashboardSideActionKind = .reload) -> DashboardSideAction {
        DashboardSideAction(title: kind.title, symbol: kind.defaultSymbol, kind: kind)
    }
}

struct DashboardActionStrip: Codable, Equatable {
    var isEnabled: Bool = false
    var side: DashboardActionStripSide = .right
    var actions: [DashboardSideAction] = []

    static let maxActions = 6
}

struct DashboardBrowserOptions: Codable, Equatable {
    var openLinksExternally: Bool = false
    var useDesktopUserAgent: Bool = true
}

struct DashboardConfig: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var urlString: String
    var auth: DashboardAuthConfig = DashboardAuthConfig()
    var actionStrip: DashboardActionStrip = DashboardActionStrip()
    var browser: DashboardBrowserOptions = DashboardBrowserOptions()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var url: URL? { URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var host: String? {
        url?.host?.lowercased()
    }

    init(id: UUID = UUID(),
         name: String,
         urlString: String,
         auth: DashboardAuthConfig = DashboardAuthConfig(),
         actionStrip: DashboardActionStrip = DashboardActionStrip(),
         browser: DashboardBrowserOptions = DashboardBrowserOptions(),
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.auth = auth
        self.actionStrip = actionStrip
        self.browser = browser
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, urlString, auth, actionStrip, browser, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        urlString = try container.decode(String.self, forKey: .urlString)
        auth = try container.decodeIfPresent(DashboardAuthConfig.self, forKey: .auth) ?? DashboardAuthConfig()
        actionStrip = try container.decodeIfPresent(DashboardActionStrip.self, forKey: .actionStrip) ?? DashboardActionStrip()
        browser = try container.decodeIfPresent(DashboardBrowserOptions.self, forKey: .browser) ?? DashboardBrowserOptions()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

struct DashboardSecretValues: Equatable {
    var homeAssistantToken: String = ""
    var basicPassword: String = ""
    var headerValues: [UUID: String] = [:]

    static let empty = DashboardSecretValues()
}

struct DashboardResolvedAuth {
    var kind: DashboardAuthKind
    var username: String = ""
    var homeAssistantToken: String?
    var basicPassword: String?
    var headers: [(name: String, value: String)] = []
}

enum DashboardValidationError: LocalizedError, Hashable {
    case missingName
    case invalidURL
    case missingHomeAssistantToken
    case missingBasicUsername
    case missingBasicPassword
    case missingHeader
    case missingHeaderName
    case missingHeaderValue(String)
    case missingSideAction
    case tooManyActions
    case missingActionTitle
    case invalidActionURL(String)

    var errorDescription: String? {
        switch self {
        case .missingName: return "Name is required."
        case .invalidURL: return "Enter a valid http or https URL."
        case .missingHomeAssistantToken: return "Home Assistant token is required."
        case .missingBasicUsername: return "Username is required."
        case .missingBasicPassword: return "Password is required."
        case .missingHeader: return "At least one header is required."
        case .missingHeaderName: return "Header name is required."
        case .missingHeaderValue(let name): return "\(name) value is required."
        case .missingSideAction: return "At least one side action is required."
        case .tooManyActions: return "Side actions are limited to six buttons."
        case .missingActionTitle: return "Action title is required."
        case .invalidActionURL(let title): return "\(title) needs a valid http or https URL."
        }
    }
}

enum DashboardStoreError: LocalizedError {
    case validation([DashboardValidationError])
    case missingSecret(String)

    var errorDescription: String? {
        switch self {
        case .validation(let errors): return errors.compactMap(\.errorDescription).joined(separator: "\n")
        case .missingSecret(let field): return "Missing dashboard secret: \(field)."
        }
    }
}

final class DashboardStore: ObservableObject {
    static let shared = DashboardStore()

    @Published private(set) var dashboards: [DashboardConfig]

    private let secretStore: DashboardSecretStoring
    private let fileURL: URL

    convenience init() {
        self.init(secretStore: DashboardSecretStore.shared, fileURL: DashboardStore.defaultFileURL)
    }

    init(secretStore: DashboardSecretStoring, fileURL: URL) {
        self.secretStore = secretStore
        self.fileURL = fileURL
        dashboards = DashboardStore.load(from: fileURL) ?? []
    }

    func dashboard(id: UUID) -> DashboardConfig? {
        dashboards.first { $0.id == id }
    }

    @discardableResult
    func save(_ dashboard: DashboardConfig, secrets: DashboardSecretValues = .empty, requireSecrets: Bool) throws -> DashboardConfig {
        var validation = Self.validate(dashboard, secrets: secrets, requireSecrets: requireSecrets)
        if !requireSecrets {
            validation.append(contentsOf: try existingSecretValidationErrors(for: dashboard, values: secrets))
        }
        guard validation.isEmpty else { throw DashboardStoreError.validation(validation) }

        var next = dashboard
        next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.urlString = next.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        next.actionStrip.actions = next.actionStrip.actions.map { action in
            var copy = action
            copy.title = copy.title.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.symbol = copy.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.urlString = copy.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
        next.updatedAt = Date()

        try cleanupSecretsBeforeSave(existing: self.dashboard(id: next.id), next: next)
        try writeSecrets(for: next, values: secrets)

        if let index = dashboards.firstIndex(where: { $0.id == next.id }) {
            dashboards[index] = next
        } else {
            dashboards.append(next)
        }
        persist()
        return next
    }

    @discardableResult
    func duplicate(_ dashboard: DashboardConfig) throws -> DashboardConfig {
        var copy = dashboard
        copy.id = UUID()
        copy.name = "\(dashboard.name) Copy"
        copy.createdAt = Date()
        copy.updatedAt = copy.createdAt
        dashboards.append(copy)
        persist()
        return copy
    }

    func delete(id: UUID) {
        dashboards.removeAll { $0.id == id }
        try? secretStore.deleteAll(dashboardID: id)
        HomeStore.shared.removeDashboardReferences(id: id)
        persist()
    }

    func resolvedAuth(for dashboard: DashboardConfig) throws -> DashboardResolvedAuth {
        switch dashboard.auth.kind {
        case .none:
            return DashboardResolvedAuth(kind: .none)
        case .homeAssistant:
            guard let token = try secretStore.get(dashboardID: dashboard.id, field: Self.homeAssistantTokenField),
                  !token.isEmpty else { throw DashboardStoreError.missingSecret("Home Assistant token") }
            return DashboardResolvedAuth(kind: .homeAssistant, homeAssistantToken: token)
        case .basic:
            guard let password = try secretStore.get(dashboardID: dashboard.id, field: Self.basicPasswordField),
                  !password.isEmpty else { throw DashboardStoreError.missingSecret("Basic password") }
            return DashboardResolvedAuth(kind: .basic, username: dashboard.auth.username, basicPassword: password)
        case .customHeaders:
            let headers: [(String, String)] = try dashboard.auth.headers.map { header in
                guard let value = try secretStore.get(dashboardID: dashboard.id, field: Self.customHeaderField(header.id)),
                      !value.isEmpty else { throw DashboardStoreError.missingSecret(header.name) }
                return (header.name, value)
            }
            return DashboardResolvedAuth(kind: .customHeaders, headers: headers)
        }
    }

    func hasRequiredSecrets(for dashboard: DashboardConfig) -> Bool {
        do {
            switch dashboard.auth.kind {
            case .none:
                return true
            case .homeAssistant:
                return try secretStore.get(dashboardID: dashboard.id, field: Self.homeAssistantTokenField)?.isEmpty == false
            case .basic:
                return try secretStore.get(dashboardID: dashboard.id, field: Self.basicPasswordField)?.isEmpty == false
            case .customHeaders:
                for header in dashboard.auth.headers {
                    if try secretStore.get(dashboardID: dashboard.id, field: Self.customHeaderField(header.id))?.isEmpty != false {
                        return false
                    }
                }
                return true
            }
        } catch {
            return false
        }
    }

    static func validate(_ dashboard: DashboardConfig, secrets: DashboardSecretValues, requireSecrets: Bool) -> [DashboardValidationError] {
        var errors: [DashboardValidationError] = []
        if dashboard.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.missingName) }

        let url = dashboard.url
        let scheme = url?.scheme?.lowercased()
        if url?.host == nil || !(scheme == "http" || scheme == "https") {
            errors.append(.invalidURL)
        }

        switch dashboard.auth.kind {
        case .none:
            break
        case .homeAssistant:
            if requireSecrets && secrets.homeAssistantToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.missingHomeAssistantToken)
            }
        case .basic:
            if dashboard.auth.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.missingBasicUsername)
            }
            if requireSecrets && secrets.basicPassword.isEmpty {
                errors.append(.missingBasicPassword)
            }
        case .customHeaders:
            if dashboard.auth.headers.isEmpty {
                errors.append(.missingHeader)
            }
            for header in dashboard.auth.headers {
                let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty {
                    errors.append(.missingHeaderName)
                } else if requireSecrets && (secrets.headerValues[header.id] ?? "").isEmpty {
                    errors.append(.missingHeaderValue(name))
                }
            }
        }

        if dashboard.actionStrip.isEnabled {
            if dashboard.actionStrip.actions.isEmpty {
                errors.append(.missingSideAction)
            } else if dashboard.actionStrip.actions.count > DashboardActionStrip.maxActions {
                errors.append(.tooManyActions)
            }
            for action in dashboard.actionStrip.actions {
                let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty {
                    errors.append(.missingActionTitle)
                }
                if action.kind == .openURL {
                    let url = action.url
                    let scheme = url?.scheme?.lowercased()
                    if url?.host == nil || !(scheme == "http" || scheme == "https") {
                        errors.append(.invalidActionURL(title.isEmpty ? action.kind.title : title))
                    }
                }
            }
        }

        return errors
    }

    static let homeAssistantTokenField = "homeAssistant.token"
    static let basicPasswordField = "basic.password"

    static func customHeaderField(_ id: UUID) -> String {
        "customHeader.\(id.uuidString)"
    }

    private func writeSecrets(for dashboard: DashboardConfig, values: DashboardSecretValues) throws {
        switch dashboard.auth.kind {
        case .none:
            break
        case .homeAssistant:
            let value = values.homeAssistantToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { try secretStore.set(value, dashboardID: dashboard.id, field: Self.homeAssistantTokenField) }
        case .basic:
            if !values.basicPassword.isEmpty { try secretStore.set(values.basicPassword, dashboardID: dashboard.id, field: Self.basicPasswordField) }
        case .customHeaders:
            for header in dashboard.auth.headers {
                let value = values.headerValues[header.id] ?? ""
                if !value.isEmpty { try secretStore.set(value, dashboardID: dashboard.id, field: Self.customHeaderField(header.id)) }
            }
        }
    }

    private func existingSecretValidationErrors(for dashboard: DashboardConfig, values: DashboardSecretValues) throws -> [DashboardValidationError] {
        switch dashboard.auth.kind {
        case .none:
            return []
        case .homeAssistant:
            if try secretIsMissing(dashboardID: dashboard.id,
                                   field: Self.homeAssistantTokenField,
                                   replacementValue: values.homeAssistantToken) {
                return [.missingHomeAssistantToken]
            }
        case .basic:
            if try secretIsMissing(dashboardID: dashboard.id,
                                   field: Self.basicPasswordField,
                                   replacementValue: values.basicPassword) {
                return [.missingBasicPassword]
            }
        case .customHeaders:
            var errors: [DashboardValidationError] = []
            for header in dashboard.auth.headers {
                let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty {
                    continue
                }
                if try secretIsMissing(dashboardID: dashboard.id,
                                       field: Self.customHeaderField(header.id),
                                       replacementValue: values.headerValues[header.id] ?? "") {
                    errors.append(.missingHeaderValue(name))
                }
            }
            return errors
        }
        return []
    }

    private func secretIsMissing(dashboardID: UUID, field: String, replacementValue: String) throws -> Bool {
        if !replacementValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return try secretStore.get(dashboardID: dashboardID, field: field)?.isEmpty != false
    }

    private func cleanupSecretsBeforeSave(existing: DashboardConfig?, next: DashboardConfig) throws {
        guard let existing else { return }

        if existing.auth.kind != next.auth.kind || next.auth.kind == .none {
            try secretStore.deleteAll(dashboardID: next.id)
            return
        }

        if next.auth.kind == .customHeaders {
            let remaining = Set(next.auth.headers.map(\.id))
            for header in existing.auth.headers where !remaining.contains(header.id) {
                try secretStore.delete(dashboardID: next.id, field: Self.customHeaderField(header.id))
            }
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.dashboard.encode(dashboards) {
            try? data.write(to: fileURL)
        }
    }

    private static func load(from url: URL) -> [DashboardConfig]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.dashboard.decode([DashboardConfig].self, from: data)
    }

    private static var defaultFileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Quake4Mac", isDirectory: true).appendingPathComponent("dashboards.json")
    }
}

private extension JSONEncoder {
    static var dashboard: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var dashboard: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
