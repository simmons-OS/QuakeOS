import Foundation

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

struct DropInAppManifest: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let entry: String
    let served: Bool
    let options: [DropInAppOption]
    let server: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, entry, file, served, options, server
    }

    init(id: String, name: String? = nil, entry: String, served: Bool = false,
         options: [DropInAppOption] = [], server: String? = nil) {
        self.id = id
        self.name = name ?? id
        self.entry = entry
        self.served = served
        self.options = options
        self.server = server
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
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource(let message):
            return message
        case .duplicateID(let id):
            return "An app with id \"\(id)\" is already installed."
        case .destinationExists(let folder):
            return "The destination folder \"\(folder)\" already exists."
        case .copyFailed(let message):
            return message
        }
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
    private static let optionValuesKey = "dropInApps.optionValues"

    init(rootURL: URL = DropInAppStore.defaultAppsDirectory(),
         fileManager: FileManager = .default,
         defaults: UserDefaults = .standard) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.defaults = defaults
        optionValuesByAppID = defaults.dictionary(forKey: Self.optionValuesKey) as? [String: [String: String]] ?? [:]
        refresh()
    }

    func app(id: String) -> DropInAppRecord? {
        apps.first { $0.id == id }
    }

    func staticLaunchURL(for app: DropInAppRecord) -> URL? {
        guard !app.manifest.served,
              var url = Self.containedURL(root: app.rootURL, relativePath: app.manifest.entry) else { return nil }
        if let fragment = Self.staticOptionsFragment(for: app.manifest.options,
                                                     values: optionValuesByAppID[app.id] ?? [:]),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedFragment = fragment
            url = components.url ?? url
        }
        return url
    }

    func optionValue(appID: String, option: DropInAppOption) -> String {
        optionValuesByAppID[appID]?[option.key] ?? option.defaultValue ?? ""
    }

    func setOptionValue(appID: String, optionKey: String, value: String) {
        var next = optionValuesByAppID
        next[appID, default: [:]][optionKey] = value
        optionValuesByAppID = next
        saveOptionValues()
    }

    func resetOptionValues(appID: String) {
        var next = optionValuesByAppID
        next[appID] = nil
        optionValuesByAppID = next
        saveOptionValues()
    }

    func importFolder(at sourceURL: URL) -> Result<DropInAppRecord, DropInAppImportError> {
        let source = sourceURL.standardizedFileURL
        switch scan(folder: source) {
        case .failure(let message):
            return .failure(.invalidSource(message))
        case .success(let record):
            refresh()
            guard !apps.contains(where: { $0.id == record.id }) else {
                return .failure(.duplicateID(record.id))
            }

            let destination = rootURL.appendingPathComponent(record.id, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path) else {
                return .failure(.destinationExists(destination.lastPathComponent))
            }

            do {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                return .failure(.copyFailed(error.localizedDescription))
            }

            refresh()
            if let imported = app(id: record.id) {
                return .success(imported)
            }
            return .failure(.invalidSource("Imported app could not be scanned."))
        }
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

    static func clientOptions(_ options: [DropInAppOption]) -> [DropInAppOption] {
        options.filter(isClientOption)
    }

    static func staticOptionsFragment(for options: [DropInAppOption],
                                      values: [String: String] = [:]) -> String? {
        let queryItems = options.compactMap { option -> URLQueryItem? in
            guard isClientOption(option), let value = values[option.key] ?? option.defaultValue else { return nil }
            return URLQueryItem(name: option.key, value: value)
        }
        guard !queryItems.isEmpty else { return nil }
        var components = URLComponents()
        components.queryItems = queryItems
        return components.percentEncodedQuery
    }

    private static func isClientOption(_ option: DropInAppOption) -> Bool {
        option.type != "secret" && !option.serverOnly
    }

    private enum ScanResult {
        case success(DropInAppRecord)
        case failure(String)
    }

    private func saveOptionValues() {
        defaults.set(optionValuesByAppID, forKey: Self.optionValuesKey)
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
            return .success(DropInAppRecord(manifest: manifest,
                                            rootURL: folder,
                                            manifestURL: manifestURL,
                                            hasHostCode: manifest.served && manifest.server != nil))
        } catch {
            return .failure("Manifest could not be parsed.")
        }
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
