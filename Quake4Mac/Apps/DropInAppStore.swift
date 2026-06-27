import Foundation
import Security
import SwiftUI

struct DropInAppOption: Decodable, Equatable, Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let type: String
    let defaultValue: String?
    let serverOnly: Bool

    private enum CodingKeys: String, CodingKey {
        case key, label, type, defaultValue = "default", serverOnly
    }

    init(key: String, label: String, type: String, defaultValue: String? = nil, serverOnly: Bool = false) {
        self.key = key
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.serverOnly = serverOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "text"
        serverOnly = try c.decodeIfPresent(Bool.self, forKey: .serverOnly) ?? false
        if let value = try? c.decode(String.self, forKey: .defaultValue) {
            defaultValue = value
        } else if let value = try? c.decode(Bool.self, forKey: .defaultValue) {
            defaultValue = value ? "true" : "false"
        } else if let value = try? c.decode(Int.self, forKey: .defaultValue) {
            defaultValue = "\(value)"
        } else {
            defaultValue = nil
        }
    }
}

struct DropInAppProxyAllowRule: Decodable, Equatable {
    let option: String?
    let pattern: String?
}

struct DropInAppProxyConfig: Decodable, Equatable {
    let methods: [String]?
    let allow: [DropInAppProxyAllowRule]
    let verifySslOption: String?

    private enum CodingKeys: String, CodingKey {
        case methods, allow, verifySslOption
    }

    init(methods: [String]? = nil,
         allow: [DropInAppProxyAllowRule] = [],
         verifySslOption: String? = nil) {
        self.methods = methods
        self.allow = allow
        self.verifySslOption = verifySslOption
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        methods = try c.decodeIfPresent([String].self, forKey: .methods)
        allow = try c.decodeIfPresent([DropInAppProxyAllowRule].self, forKey: .allow) ?? []
        verifySslOption = try c.decodeIfPresent(String.self, forKey: .verifySslOption)
    }
}

enum DropInAppJSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: DropInAppJSONValue])
    case array([DropInAppJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([DropInAppJSONValue].self) {
            self = .array(value)
        } else if let value = try? c.decode([String: DropInAppJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value.")
        }
    }
}

extension DropInAppJSONValue {
    var objectValue: [String: DropInAppJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [DropInAppJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array, .null:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            guard value.rounded() == value else { return nil }
            return Int(value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool, .object, .array, .null:
            return nil
        }
    }
}

struct DropInAppGridConfig: Decodable, Equatable {
    let cols: Int
    let rows: Int
    let defaults: [DropInAppJSONValue]

    init(cols: Int, rows: Int, defaults: [DropInAppJSONValue] = []) {
        self.cols = cols
        self.rows = rows
        self.defaults = defaults
    }

    private enum CodingKeys: String, CodingKey {
        case cols, rows, defaults
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cols = try c.decode(Int.self, forKey: .cols)
        rows = try c.decode(Int.self, forKey: .rows)
        defaults = try c.decodeIfPresent([DropInAppJSONValue].self, forKey: .defaults) ?? []
    }

    var nativeTileCount: Int {
        min(PadModel.perPage, max(0, cols) * max(0, rows))
    }

    func nativeTiles() -> [Tile] {
        let count = nativeTileCount
        var tiles = defaults.prefix(count).map(DropInAppGridTileMapper.tile)
        while tiles.count < count {
            tiles.append(PadStore.emptyTile)
        }
        return tiles
    }
}

private enum DropInAppGridTileMapper {
    static func tile(from value: DropInAppJSONValue) -> Tile {
        guard let object = value.objectValue,
              let type = string("type", in: object), !type.isEmpty else {
            return PadStore.emptyTile
        }
        let title = string("label", in: object) ?? string("title", in: object) ?? ""
        let icon = string("icon", in: object)
            ?? string("iconImage", in: object)
        let action = action(type: type, object: object)
        return Tile(title: title,
                    symbol: symbol(for: type),
                    tint: tint(for: type),
                    action: action,
                    editable: true,
                    customIcon: customIcon(icon: icon, object: object),
                    columnSpan: int("w", in: object) ?? 1,
                    rowSpan: int("h", in: object) ?? 1)
    }

    private static func action(type rawType: String, object: [String: DropInAppJSONValue]) -> PadAction {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = string("value", in: object) ?? ""
        switch type {
        case "url":
            return .openURL(value)
        case "app":
            return .launchApp(bundleID: value)
        case "cmd", "shell":
            return .shell(value)
        case "open", "openPath":
            return .openPath(value)
        case "page":
            return .openPage(value)
        case "system":
            return systemAction(value: value)
        case "counter":
            return .counter(value: int("value", in: object) ?? 0)
        case "paste_text", "pasteText":
            return .pasteText(value)
        case "key":
            return .keyCombo(value)
        case "text":
            return .typeText(value)
        case "macro":
            return .macro(macroSteps(in: object))
        default:
            return .none
        }
    }

    private static func systemAction(value: String) -> PadAction {
        switch value {
        case "config":
            return .system(.openSettings)
        case "lock":
            return .system(.lockScreen)
        default:
            return .none
        }
    }

    private static func macroSteps(in object: [String: DropInAppJSONValue]) -> [MacroStep] {
        guard let steps = object["steps"]?.arrayValue else { return [] }
        return steps.compactMap { step in
            guard let object = step.objectValue,
                  let kind = string("kind", in: object) else { return nil }
            let value = string("value", in: object) ?? ""
            switch kind {
            case "key":
                return MacroStep(kind: .key, value: value, intValue: 0)
            case "text":
                return MacroStep(kind: .text, value: value, intValue: 0)
            case "paste_text", "pasteText":
                return MacroStep(kind: .pasteText, value: value, intValue: 0)
            case "delay":
                return MacroStep(kind: .delay, value: "", intValue: int("value", in: object) ?? int("intValue", in: object) ?? 250)
            case "app":
                return MacroStep(kind: .app, value: value, intValue: 0)
            case "url":
                return MacroStep(kind: .url, value: value, intValue: 0)
            case "open", "openPath":
                return MacroStep(kind: .openPath, value: value, intValue: 0)
            case "cmd", "shell":
                return MacroStep(kind: .shell, value: value, intValue: 0)
            case "page":
                return MacroStep(kind: .page, value: value, intValue: 0)
            case "system" where value == "config":
                return MacroStep(kind: .openSettings, value: "", intValue: 0)
            case "system" where value == "lock":
                return MacroStep(kind: .lockScreen, value: "", intValue: 0)
            default:
                return nil
            }
        }
    }

    private static func customIcon(icon: String?, object: [String: DropInAppJSONValue]) -> TileIcon? {
        let trimmed = icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if string("iconType", in: object) == "image" {
            return .imagePath(trimmed)
        }
        return .emoji(trimmed)
    }

    private static func string(_ key: String, in object: [String: DropInAppJSONValue]) -> String? {
        object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func int(_ key: String, in object: [String: DropInAppJSONValue]) -> Int? {
        object[key]?.intValue
    }

    private static func symbol(for type: String) -> String {
        switch type {
        case "url":
            return "globe"
        case "app":
            return "app"
        case "cmd", "shell":
            return "terminal"
        case "open", "openPath":
            return "folder"
        case "page":
            return "square.grid.2x2"
        case "system":
            return "gearshape"
        case "counter":
            return "number"
        case "paste_text", "pasteText":
            return "doc.on.clipboard"
        case "key":
            return "keyboard"
        case "text":
            return "text.cursor"
        case "macro":
            return "list.bullet.rectangle"
        default:
            return "square.dashed"
        }
    }

    private static func tint(for type: String) -> Color {
        switch type {
        case "url":
            return .blue
        case "app":
            return .purple
        case "cmd", "shell":
            return .gray
        case "open", "openPath":
            return .cyan
        case "page":
            return .teal
        case "system":
            return .orange
        case "counter":
            return .orange
        case "paste_text", "pasteText", "text":
            return .green
        case "key", "macro":
            return .indigo
        default:
            return .gray
        }
    }
}

struct DropInAppManifest: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let entry: String
    let served: Bool
    let options: [DropInAppOption]
    let server: String?
    let proxy: DropInAppProxyConfig?
    let grid: DropInAppGridConfig?

    private enum CodingKeys: String, CodingKey {
        case id, name, entry, file, served, options, server, proxy, grid
    }

    init(id: String, name: String? = nil, entry: String, served: Bool = false,
         options: [DropInAppOption] = [], server: String? = nil, proxy: DropInAppProxyConfig? = nil,
         grid: DropInAppGridConfig? = nil) {
        self.id = id
        self.name = name ?? id
        self.entry = entry
        self.served = served
        self.options = options
        self.server = server
        self.proxy = proxy
        self.grid = grid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        entry = try c.decodeIfPresent(String.self, forKey: .entry)
            ?? c.decode(String.self, forKey: .file)
        served = try c.decodeIfPresent(Bool.self, forKey: .served) ?? false
        options = try c.decodeIfPresent([DropInAppOption].self, forKey: .options) ?? []
        server = try c.decodeIfPresent(String.self, forKey: .server)
        proxy = try c.decodeIfPresent(DropInAppProxyConfig.self, forKey: .proxy)
        grid = try? c.decodeIfPresent(DropInAppGridConfig.self, forKey: .grid)
    }
}

struct DropInAppRecord: Identifiable, Equatable {
    var id: String { manifest.id }
    let manifest: DropInAppManifest
    let rootURL: URL
    let manifestURL: URL
    let hasHostCode: Bool
}

struct DropInAppIssue: Identifiable, Equatable {
    let id = UUID()
    let folderName: String
    let message: String
}

enum DropInAppImportError: LocalizedError, Equatable {
    case invalidSource(String)
    case duplicateID(String)
    case destinationExists(String)
    case requiresHostCodeConfirmation(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource(let message):
            return message
        case .duplicateID(let id):
            return "An app with id \"\(id)\" is already installed."
        case .destinationExists(let folder):
            return "The destination folder \"\(folder)\" already exists."
        case .requiresHostCodeConfirmation(let name):
            return "\"\(name)\" contains host-side code. Only import it if you trust the source."
        case .copyFailed(let message):
            return message
        }
    }
}

enum DropInAppRemovalError: LocalizedError, Equatable {
    case missing(String)
    case removeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let id):
            return "The app \"\(id)\" is no longer installed."
        case .removeFailed(let message):
            return message
        }
    }
}

enum DropInAppExportError: LocalizedError, Equatable {
    case missing(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let id):
            return "The app \"\(id)\" is no longer installed."
        case .exportFailed(let message):
            return message
        }
    }
}

protocol DropInAppSecretStoring {
    func set(_ value: String, appID: String, field: String) throws
    func get(appID: String, field: String) throws -> String?
    func delete(appID: String, field: String) throws
    func deleteAll(appID: String) throws
}

enum DropInAppSecretError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): return "Keychain returned status \(status)."
        case .invalidData: return "Stored drop-in app secret was not valid text."
        }
    }
}

final class DropInAppSecretStore: DropInAppSecretStoring {
    static let shared = DropInAppSecretStore()

    private let service = "com.quake4mac.dropin-app"

    private init() {}

    func set(_ value: String, appID: String, field: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: accountKey(appID: appID, field: field))
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrGeneric as String] = appID
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw DropInAppSecretError.unexpectedStatus(status) }
    }

    func get(appID: String, field: String) throws -> String? {
        var query = baseQuery(account: accountKey(appID: appID, field: field))
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DropInAppSecretError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw DropInAppSecretError.invalidData
        }
        return value
    }

    func delete(appID: String, field: String) throws {
        let status = SecItemDelete(baseQuery(account: accountKey(appID: appID, field: field)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DropInAppSecretError.unexpectedStatus(status)
        }
    }

    func deleteAll(appID: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        query[kSecAttrGeneric as String] = appID
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DropInAppSecretError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func accountKey(appID: String, field: String) -> String {
        "\(appID):\(field)"
    }
}

final class DropInAppStore: ObservableObject {
    static let shared = DropInAppStore()

    @Published private(set) var apps: [DropInAppRecord] = []
    @Published private(set) var issues: [DropInAppIssue] = []
    @Published private(set) var optionValuesByAppID: [String: [String: String]] = [:]

    let rootURL: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let secretStore: DropInAppSecretStoring
    private static let optionValuesKey = "dropInApps.optionValues"
    private static let riskyHostCodeExtensions: Set<String> = [
        "exe", "dll", "com", "scr", "msi", "bat", "cmd", "ps1", "psm1", "vbs", "vbe",
        "wsf", "wsh", "jar", "sh", "cpl", "command"
    ]

    init(rootURL: URL = DropInAppStore.defaultAppsDirectory(),
         fileManager: FileManager = .default,
         defaults: UserDefaults = .standard,
         secretStore: DropInAppSecretStoring = DropInAppSecretStore.shared) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.defaults = defaults
        self.secretStore = secretStore
        optionValuesByAppID = defaults.dictionary(forKey: Self.optionValuesKey) as? [String: [String: String]] ?? [:]
        refresh()
    }

    func app(id: String) -> DropInAppRecord? {
        apps.first { $0.id == id }
    }

    func staticLaunchURL(for app: DropInAppRecord) -> URL? {
        guard !app.manifest.served,
              var url = Self.containedURL(root: app.rootURL, relativePath: app.manifest.entry) else { return nil }
        if let fragment = Self.clientOptionsQuery(for: app.manifest.options,
                                                  values: optionValuesByAppID[app.id] ?? [:],
                                                  includeGridHint: Self.hasVisibleGrid(for: app)),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedFragment = fragment
            url = components.url ?? url
        }
        return url
    }

    func servedLaunchURL(for app: DropInAppRecord, port: UInt16) -> URL? {
        guard app.manifest.served,
              Self.containedURL(root: app.rootURL, relativePath: app.manifest.entry) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.percentEncodedPath = "/apps/\(app.id)/\(Self.percentEncodedPath(app.manifest.entry))"
        components.percentEncodedQuery = Self.clientOptionsQuery(for: app.manifest.options,
                                                                 values: optionValuesByAppID[app.id] ?? [:],
                                                                 includeGridHint: Self.hasVisibleGrid(for: app))
        return components.url
    }

    func clientConfigPayload(for app: DropInAppRecord) -> [String: Any] {
        [
            "app": app.id,
            "api": Self.clientAPIPaths(for: app),
            "options": Self.resolvedClientOptionValues(for: app.manifest.options,
                                                       values: optionValuesByAppID[app.id] ?? [:])
        ]
    }

    func proxyConfigPayload(for app: DropInAppRecord) -> [String: Any] {
        [
            "app": app.id,
            "api": Self.clientAPIPaths(for: app),
            "options": resolvedOptionValues(for: app)
        ]
    }

    func optionValue(appID: String, option: DropInAppOption) -> String {
        guard Self.isClientOption(option) else {
            return (try? secretStore.get(appID: appID, field: option.key)) ?? option.defaultValue ?? ""
        }
        return optionValuesByAppID[appID]?[option.key] ?? option.defaultValue ?? ""
    }

    func setOptionValue(appID: String, optionKey: String, value: String) {
        var next = optionValuesByAppID
        next[appID, default: [:]][optionKey] = value
        optionValuesByAppID = next
        saveOptionValues()
    }

    func setOptionValue(appID: String, option: DropInAppOption, value: String) {
        guard Self.isClientOption(option) else {
            try? secretStore.set(value, appID: appID, field: option.key)
            objectWillChange.send()
            return
        }
        setOptionValue(appID: appID, optionKey: option.key, value: value)
    }

    func resetOptionValues(appID: String) {
        var next = optionValuesByAppID
        next[appID] = nil
        optionValuesByAppID = next
        try? secretStore.deleteAll(appID: appID)
        saveOptionValues()
    }

    func importFolder(at sourceURL: URL,
                      allowHostCode: Bool = false,
                      forceID: String? = nil) -> Result<DropInAppRecord, DropInAppImportError> {
        if let forceID, !Self.isValidAppID(forceID) {
            return .failure(.invalidSource("Invalid app id \"\(forceID)\"."))
        }

        let source = sourceURL.standardizedFileURL
        switch scan(folder: source) {
        case .failure(let message):
            return .failure(.invalidSource(message))
        case .success(let record):
            let importID = forceID ?? record.id
            refresh()
            guard !apps.contains(where: { $0.id == importID }) else {
                return .failure(.duplicateID(importID))
            }

            let destination = rootURL.appendingPathComponent(importID, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path) else {
                return .failure(.destinationExists(destination.lastPathComponent))
            }
            guard allowHostCode || !record.hasHostCode else {
                return .failure(.requiresHostCodeConfirmation(record.manifest.name))
            }

            do {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                if importID != record.id {
                    try rewriteManifestID(at: destination.appendingPathComponent(record.manifestURL.lastPathComponent),
                                          id: importID)
                }
            } catch {
                try? fileManager.removeItem(at: destination)
                return .failure(.copyFailed(error.localizedDescription))
            }

            refresh()
            if let imported = app(id: importID) {
                return .success(imported)
            }
            return .failure(.invalidSource("Imported app could not be scanned."))
        }
    }

    func importArchive(at archiveURL: URL,
                       allowHostCode: Bool = false,
                       forceID: String? = nil) -> Result<DropInAppRecord, DropInAppImportError> {
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("QuakeOSDropInImport-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        } catch {
            return .failure(.copyFailed(error.localizedDescription))
        }
        defer { try? fileManager.removeItem(at: tempRoot) }

        if let error = runDitto(arguments: ["-x", "-k", archiveURL.standardizedFileURL.path, tempRoot.path]) {
            return .failure(.invalidSource("Archive could not be extracted: \(error)"))
        }
        guard let appRoot = archiveAppRoot(in: tempRoot) else {
            return .failure(.invalidSource("Archive does not contain a valid drop-in app."))
        }
        return importFolder(at: appRoot, allowHostCode: allowHostCode, forceID: forceID)
    }

    func exportArchive(appID: String, to destinationURL: URL) -> Result<Void, DropInAppExportError> {
        guard let app = app(id: appID) else { return .failure(.missing(appID)) }
        guard Self.url(app.rootURL, isContainedIn: rootURL) else {
            return .failure(.exportFailed("App folder is outside the drop-in folder."))
        }

        let destination = destinationURL.standardizedFileURL
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
        } catch {
            return .failure(.exportFailed(error.localizedDescription))
        }

        if let error = runDitto(arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", app.rootURL.path, destination.path]) {
            return .failure(.exportFailed(error))
        }
        return .success(())
    }

    func removeApp(id: String) -> Result<Void, DropInAppRemovalError> {
        guard let app = app(id: id) else { return .failure(.missing(id)) }

        do {
            try fileManager.removeItem(at: app.rootURL)
        } catch {
            return .failure(.removeFailed(error.localizedDescription))
        }

        var next = optionValuesByAppID
        next[id] = nil
        optionValuesByAppID = next
        try? secretStore.deleteAll(appID: id)
        saveOptionValues()
        refresh()
        return .success(())
    }

    func refresh() {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let children = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var seen = Set<String>()
            var nextApps: [DropInAppRecord] = []
            var nextIssues: [DropInAppIssue] = []

            for folder in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard folder.isDirectory else { continue }
                switch scan(folder: folder) {
                case .success(let app):
                    if seen.contains(app.id) {
                        nextIssues.append(DropInAppIssue(folderName: folder.lastPathComponent,
                                                         message: "Duplicate app id \"\(app.id)\"."))
                    } else {
                        seen.insert(app.id)
                        nextApps.append(app)
                    }
                case .failure(let message):
                    nextIssues.append(DropInAppIssue(folderName: folder.lastPathComponent, message: message))
                }
            }

            apps = nextApps
            issues = nextIssues
        } catch {
            apps = []
            issues = [DropInAppIssue(folderName: rootURL.lastPathComponent, message: error.localizedDescription)]
        }
    }

    static func defaultAppsDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("QuakeOS", isDirectory: true)
            .appendingPathComponent("DropInApps", isDirectory: true)
    }

    static func isValidAppID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              normalized.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
                               options: .regularExpression) == nil else { return false }
        return !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    static func containedURL(root: URL, relativePath: String) -> URL? {
        guard isSafeRelativePath(relativePath) else { return nil }
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let rootPath = root.standardizedFileURL.path
        let resolved = root.appendingPathComponent(normalized).standardizedFileURL
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else { return nil }
        return resolved
    }

    static func url(_ url: URL, isContainedIn root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    static func clientOptions(_ options: [DropInAppOption]) -> [DropInAppOption] {
        options.filter(isClientOption)
    }

    static func clientAPIPaths(for app: DropInAppRecord) -> [String: String] {
        var paths = ["open": app.manifest.served ? "/app-api/open" : "/app-api/open?app=\(app.id)"]
        if app.manifest.served {
            paths["config"] = "/app-proxy/config"
        }
        if app.manifest.proxy != nil {
            paths["proxy"] = "/app-proxy"
        }
        return paths
    }

    static func staticOptionsFragment(for options: [DropInAppOption],
                                      values: [String: String] = [:]) -> String? {
        clientOptionsQuery(for: options, values: values)
    }

    static func clientOptionsQuery(for options: [DropInAppOption],
                                   values: [String: String] = [:],
                                   includeGridHint: Bool = false) -> String? {
        var queryItems = options.compactMap { option -> URLQueryItem? in
            guard isClientOption(option), let value = values[option.key] ?? option.defaultValue else { return nil }
            return URLQueryItem(name: option.key, value: value)
        }
        if includeGridHint {
            queryItems.append(URLQueryItem(name: "_grid", value: "1"))
        }
        guard !queryItems.isEmpty else { return nil }
        var components = URLComponents()
        components.queryItems = queryItems
        return components.percentEncodedQuery
    }

    private static func hasVisibleGrid(for app: DropInAppRecord) -> Bool {
        app.manifest.grid?.nativeTiles().contains(where: { !$0.isEmpty }) == true
    }

    static func resolvedClientOptionValues(for options: [DropInAppOption],
                                           values: [String: String] = [:]) -> [String: Any] {
        var resolved: [String: Any] = [:]
        for option in clientOptions(options) {
            let value = values[option.key] ?? option.defaultValue ?? ""
            resolved[option.key] = isBooleanOption(option) ? value == "true" : value
        }
        return resolved
    }

    static func isClientOption(_ option: DropInAppOption) -> Bool {
        option.type != "secret" && !option.serverOnly
    }

    private static func isBooleanOption(_ option: DropInAppOption) -> Bool {
        option.type == "bool" || option.type == "boolean"
    }

    static func percentEncodedPath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(component)
            }
            .joined(separator: "/")
    }

    private enum ScanResult {
        case success(DropInAppRecord)
        case failure(String)
    }

    private func resolvedOptionValues(for app: DropInAppRecord) -> [String: Any] {
        var resolved: [String: Any] = [:]
        for option in app.manifest.options {
            let value = optionValue(appID: app.id, option: option)
            resolved[option.key] = Self.isBooleanOption(option) ? value == "true" : value
        }
        return resolved
    }

    private func saveOptionValues() {
        defaults.set(optionValuesByAppID, forKey: Self.optionValuesKey)
    }

    private func rewriteManifestID(at manifestURL: URL, id: String) throws {
        let data = try Data(contentsOf: manifestURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard var manifest = object as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        manifest["id"] = id
        let rewritten = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try rewritten.write(to: manifestURL, options: .atomic)
    }

    private func scan(folder: URL) -> ScanResult {
        let candidates = ["app.json", "manifest.json"].map { folder.appendingPathComponent($0) }
        guard let manifestURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return .failure("Missing app.json or manifest.json.")
        }

        do {
            let manifest = try JSONDecoder().decode(DropInAppManifest.self, from: Data(contentsOf: manifestURL))
            guard Self.isValidAppID(manifest.id) else { return .failure("Invalid app id \"\(manifest.id)\".") }
            guard Self.containedURL(root: folder, relativePath: manifest.entry) != nil else {
                return .failure("Entry path escapes the app folder.")
            }
            if let server = manifest.server, Self.containedURL(root: folder, relativePath: server) == nil {
                return .failure("Server path escapes the app folder.")
            }
            let hasServerModule = manifest.served && manifest.server != nil
            return .success(DropInAppRecord(manifest: manifest,
                                            rootURL: folder,
                                            manifestURL: manifestURL,
                                            hasHostCode: hasServerModule || folderContainsExecutableCode(folder)))
        } catch {
            return .failure("Manifest could not be parsed.")
        }
    }

    private func archiveAppRoot(in folder: URL) -> URL? {
        if case .success = scan(folder: folder) {
            return folder
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let directories = children.filter(\.isDirectory)
        guard directories.count == 1, case .success = scan(folder: directories[0]) else { return nil }
        return directories[0]
    }

    private func folderContainsExecutableCode(_ folder: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(at: folder,
                                                     includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return false }
        for case let file as URL in enumerator {
            guard Self.riskyHostCodeExtensions.contains(file.pathExtension.lowercased()),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            return true
        }
        return false
    }

    private func runDitto(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard process.terminationStatus != 0 else { return nil }
            return message.isEmpty ? "ditto exited with status \(process.terminationStatus)" : message
        } catch {
            return error.localizedDescription
        }
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
