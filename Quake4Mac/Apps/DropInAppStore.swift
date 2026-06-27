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

final class DropInAppStore: ObservableObject {
    static let shared = DropInAppStore()

    @Published private(set) var apps: [DropInAppRecord] = []
    @Published private(set) var issues: [DropInAppIssue] = []
    @Published private(set) var optionValuesByAppID: [String: [String: String]] = [:]

    let rootURL: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private static let optionValuesKey = "dropInApps.optionValues"
    private static let riskyHostCodeExtensions: Set<String> = [
        "exe", "dll", "com", "scr", "msi", "bat", "cmd", "ps1", "psm1", "vbs", "vbe",
        "wsf", "wsh", "jar", "sh", "cpl", "command"
    ]

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
        if let fragment = Self.clientOptionsQuery(for: app.manifest.options,
                                                  values: optionValuesByAppID[app.id] ?? [:]),
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
                                                                 values: optionValuesByAppID[app.id] ?? [:])
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

    func importFolder(at sourceURL: URL, allowHostCode: Bool = false) -> Result<DropInAppRecord, DropInAppImportError> {
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
            guard allowHostCode || !record.hasHostCode else {
                return .failure(.requiresHostCodeConfirmation(record.manifest.name))
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

    func importArchive(at archiveURL: URL, allowHostCode: Bool = false) -> Result<DropInAppRecord, DropInAppImportError> {
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
        return importFolder(at: appRoot, allowHostCode: allowHostCode)
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
        ["open": "/app-api/open?app=\(app.id)"]
    }

    static func staticOptionsFragment(for options: [DropInAppOption],
                                      values: [String: String] = [:]) -> String? {
        clientOptionsQuery(for: options, values: values)
    }

    static func clientOptionsQuery(for options: [DropInAppOption],
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

    static func resolvedClientOptionValues(for options: [DropInAppOption],
                                           values: [String: String] = [:]) -> [String: Any] {
        var resolved: [String: Any] = [:]
        for option in clientOptions(options) {
            let value = values[option.key] ?? option.defaultValue ?? ""
            resolved[option.key] = isBooleanOption(option) ? value == "true" : value
        }
        return resolved
    }

    private static func isClientOption(_ option: DropInAppOption) -> Bool {
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
