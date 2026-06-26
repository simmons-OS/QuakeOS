import Foundation
import Security

protocol DashboardSecretStoring {
    func set(_ value: String, dashboardID: UUID, field: String) throws
    func get(dashboardID: UUID, field: String) throws -> String?
    func delete(dashboardID: UUID, field: String) throws
    func deleteAll(dashboardID: UUID) throws
}

enum DashboardSecretError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): return "Keychain returned status \(status)."
        case .invalidData: return "Stored dashboard secret was not valid text."
        }
    }
}

final class DashboardSecretStore: DashboardSecretStoring {
    static let shared = DashboardSecretStore()

    private let service = "com.quake4mac.dashboard"

    private init() {}

    func set(_ value: String, dashboardID: UUID, field: String) throws {
        let data = Data(value.utf8)
        let account = accountKey(dashboardID: dashboardID, field: field)
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrGeneric as String] = dashboardID.uuidString
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw DashboardSecretError.unexpectedStatus(status) }
    }

    func get(dashboardID: UUID, field: String) throws -> String? {
        var query = baseQuery(account: accountKey(dashboardID: dashboardID, field: field))
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DashboardSecretError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw DashboardSecretError.invalidData
        }
        return value
    }

    func delete(dashboardID: UUID, field: String) throws {
        let status = SecItemDelete(baseQuery(account: accountKey(dashboardID: dashboardID, field: field)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DashboardSecretError.unexpectedStatus(status)
        }
    }

    func deleteAll(dashboardID: UUID) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        query[kSecAttrGeneric as String] = dashboardID.uuidString
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DashboardSecretError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func accountKey(dashboardID: UUID, field: String) -> String {
        "\(dashboardID.uuidString):\(field)"
    }
}
