import AppKit
import SwiftUI

struct DropInAppsSettingsView: View {
    @ObservedObject private var store = DropInAppStore.shared
    @State private var importMessage = ""
    @State private var importError = ""
    @State private var pendingHostCodeImport: PendingHostCodeImport?
    @State private var pendingRemoval: DropInAppRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(title: "Apps",
                           subtitle: "User-installed panel apps discovered from your QuakeOS app folder.")

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    folderCard
                    serverRuntimeCard
                }
                    .frame(minWidth: 300, maxWidth: 380, alignment: .top)
                libraryCard
                    .frame(maxWidth: 680, alignment: .top)
            }
        }
        .confirmationDialog("Remove Drop-In App?",
                            isPresented: removalDialogPresented,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { removePendingApp() }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This deletes the imported app folder from QuakeOS. It does not affect the source folder you imported from.")
        }
        .confirmationDialog("Import Host-Code App?",
                            isPresented: hostCodeImportDialogPresented,
                            titleVisibility: .visible) {
            Button("Import", role: .destructive) { confirmHostCodeImport() }
            Button("Cancel", role: .cancel) { pendingHostCodeImport = nil }
        } message: {
            Text("This drop-in app contains host-side code. Only import it if you trust the source.")
        }
    }

    private var serverRuntimeCard: some View {
        let status = DropInAppNodeServerActionHandler.runtimeStatus()
        return NeonCard("Server Modules") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(status.isAvailable ? .green.opacity(0.9) : NeonTheme.magenta)
                    Text(status.isAvailable ? "Node runtime ready" : "Node runtime unavailable")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(NeonTheme.textPrimary)
                }
                Text(status.displayPath)
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(status.isAvailable ? NeonTheme.textSecondary : NeonTheme.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !status.isAvailable {
                    Text("Set QUAKEOS_NODE_PATH before launching QuakeOS.")
                        .font(.system(size: 11))
                        .foregroundColor(NeonTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var folderCard: some View {
        NeonCard("Drop-In Folder") {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.rootURL.path)
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(NeonTheme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { chooseImportFolder() } label: {
                        Label("Import Folder", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { chooseImportArchive() } label: {
                        Label("Import ZIP", systemImage: "archivebox")
                    }
                    .buttonStyle(.bordered)
                    Button { NSWorkspace.shared.open(store.rootURL) } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    Button { store.refresh() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                importStatus
            }
            .padding(.vertical, 6)
        }
    }

    private var libraryCard: some View {
        let nodeRuntimeStatus = DropInAppNodeServerActionHandler.runtimeStatus()
        return NeonCard("Discovered Apps") {
            VStack(alignment: .leading, spacing: 12) {
                if store.apps.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.apps) { app in
                            appRow(app, nodeRuntimeStatus: nodeRuntimeStatus)
                        }
                    }
                }

                if !store.issues.isEmpty {
                    issueList
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundColor(NeonTheme.textTertiary)
            Text("No drop-in apps found.")
                .font(.system(size: 13))
                .foregroundColor(NeonTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func appRow(_ app: DropInAppRecord, nodeRuntimeStatus: DropInAppNodeRuntimeStatus) -> some View {
        let options = app.manifest.options
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: app.manifest.served ? "network" : "doc.richtext")
                    .frame(width: 24)
                    .foregroundColor(app.hasHostCode ? NeonTheme.magenta : NeonTheme.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(app.manifest.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(NeonTheme.textPrimary)
                        Text(app.manifest.id)
                            .font(.system(size: 10).monospaced())
                            .foregroundColor(NeonTheme.textTertiary)
                    }
                    Text("\(runtimeLabel(for: app)) · \(app.manifest.entry)")
                        .font(.system(size: 11))
                        .foregroundColor(NeonTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if let hostCodeBadge = hostCodeBadge(for: app, nodeRuntimeStatus: nodeRuntimeStatus) {
                    Text(hostCodeBadge.title)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(hostCodeBadge.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(hostCodeBadge.color.opacity(0.12)))
                }
                if !options.isEmpty {
                    Button { store.resetOptionValues(appID: app.id) } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Reset options")
                }
                Button { exportApp(app) } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .help("Export ZIP")
                Button(role: .destructive) { pendingRemoval = app } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Remove app")
            }

            if !options.isEmpty {
                optionEditor(app: app, options: options)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func optionEditor(app: DropInAppRecord, options: [DropInAppOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                if isBooleanOption(option) {
                    Toggle(option.label, isOn: Binding(
                        get: { store.optionValue(appID: app.id, option: option) == "true" },
                        set: { store.setOptionValue(appID: app.id, option: option, value: $0 ? "true" : "false") }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 11))
                    .foregroundColor(NeonTheme.textSecondary)
                } else if option.type == "secret" {
                    HStack(spacing: 8) {
                        optionLabel(option)
                        SecureField(option.key, text: Binding(
                            get: { store.optionValue(appID: app.id, option: option) },
                            set: { store.setOptionValue(appID: app.id, option: option, value: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    }
                } else {
                    HStack(spacing: 8) {
                        optionLabel(option)
                        TextField(option.key, text: Binding(
                            get: { store.optionValue(appID: app.id, option: option) },
                            set: { store.setOptionValue(appID: app.id, option: option, value: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    }
                }
            }
        }
        .padding(.leading, 36)
    }

    private func optionLabel(_ option: DropInAppOption) -> some View {
        Text(option.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DropInAppStore.isClientOption(option) ? NeonTheme.textSecondary : NeonTheme.textTertiary)
            .frame(width: 96, alignment: .leading)
    }

    private func isBooleanOption(_ option: DropInAppOption) -> Bool {
        option.type == "bool" || option.type == "boolean"
    }

    private func runtimeLabel(for app: DropInAppRecord) -> String {
        if app.manifest.server != nil { return "Served via loopback; server module" }
        if app.hasHostCode { return "Static file; executable files detected" }
        return app.manifest.served ? "Served via loopback" : "Static file"
    }

    private func hostCodeBadge(for app: DropInAppRecord,
                               nodeRuntimeStatus: DropInAppNodeRuntimeStatus) -> (title: String, color: Color)? {
        if app.manifest.server != nil {
            return nodeRuntimeStatus.isAvailable
                ? ("SERVER MODULE READY", .green.opacity(0.9))
                : ("NODE MISSING", NeonTheme.magenta)
        }
        if app.hasHostCode {
            return ("HOST CODE", NeonTheme.magenta)
        }
        return nil
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Skipped")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NeonTheme.textSecondary)
            ForEach(store.issues) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(NeonTheme.magenta)
                    Text("\(issue.folderName): \(issue.message)")
                        .font(.system(size: 11))
                        .foregroundColor(NeonTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, store.apps.isEmpty ? 0 : 6)
    }

    @ViewBuilder private var importStatus: some View {
        if !importError.isEmpty {
            Text(importError)
                .font(.system(size: 11))
                .foregroundColor(NeonTheme.magenta)
                .fixedSize(horizontal: false, vertical: true)
        } else if !importMessage.isEmpty {
            Text(importMessage)
                .font(.system(size: 11))
                .foregroundColor(.green.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Import Drop-In App"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFolder(url, allowHostCode: false)
    }

    private func chooseImportArchive() {
        let panel = NSOpenPanel()
        panel.title = "Import Drop-In App ZIP"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.zip]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importArchive(url, allowHostCode: false)
    }

    private func importFolder(_ url: URL, allowHostCode: Bool) {
        handleImportResult(store.importFolder(at: url, allowHostCode: allowHostCode),
                           source: PendingHostCodeImport(url: url, isArchive: false))
    }

    private func importArchive(_ url: URL, allowHostCode: Bool) {
        handleImportResult(store.importArchive(at: url, allowHostCode: allowHostCode),
                           source: PendingHostCodeImport(url: url, isArchive: true))
    }

    private func handleImportResult(_ result: Result<DropInAppRecord, DropInAppImportError>,
                                    source: PendingHostCodeImport) {
        switch result {
        case .success(let app):
            importError = ""
            importMessage = "Imported \(app.manifest.name)."
            pendingHostCodeImport = nil
        case .failure(.requiresHostCodeConfirmation(let name)):
            importMessage = ""
            importError = "\"\(name)\" needs confirmation before import."
            pendingHostCodeImport = source
        case .failure(let error):
            importMessage = ""
            importError = error.errorDescription ?? "Import failed."
        }
    }

    private func exportApp(_ app: DropInAppRecord) {
        let panel = NSSavePanel()
        panel.title = "Export Drop-In App"
        panel.nameFieldStringValue = "\(app.id).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch store.exportArchive(appID: app.id, to: url) {
        case .success:
            importError = ""
            importMessage = "Exported \(app.manifest.name)."
        case .failure(let error):
            importMessage = ""
            importError = error.errorDescription ?? "Export failed."
        }
    }

    private var removalDialogPresented: Binding<Bool> {
        Binding(get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } })
    }

    private var hostCodeImportDialogPresented: Binding<Bool> {
        Binding(get: { pendingHostCodeImport != nil },
                set: { if !$0 { pendingHostCodeImport = nil } })
    }

    private func confirmHostCodeImport() {
        guard let pending = pendingHostCodeImport else { return }
        if pending.isArchive {
            importArchive(pending.url, allowHostCode: true)
        } else {
            importFolder(pending.url, allowHostCode: true)
        }
    }

    private func removePendingApp() {
        guard let app = pendingRemoval else { return }
        pendingRemoval = nil
        switch store.removeApp(id: app.id) {
        case .success:
            importError = ""
            importMessage = "Removed \(app.manifest.name)."
        case .failure(let error):
            importMessage = ""
            importError = error.errorDescription ?? "Remove failed."
        }
    }
}

private struct PendingHostCodeImport {
    let url: URL
    let isArchive: Bool
}
