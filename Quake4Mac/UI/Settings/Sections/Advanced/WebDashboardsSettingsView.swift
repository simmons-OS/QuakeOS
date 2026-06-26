import SwiftUI

struct WebDashboardsSettingsView: View {
    @ObservedObject private var store = DashboardStore.shared
    @State private var selectedID: UUID?
    @State private var draft = DashboardConfig(name: "", urlString: "https://")
    @State private var secrets = DashboardSecretValues.empty
    @State private var errors: [DashboardValidationError] = []
    @State private var saveMessage = ""

    private var isEditingExisting: Bool {
        store.dashboard(id: draft.id) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(title: "Web Dashboards",
                           subtitle: "Named authenticated dashboards for the panel.")

            HStack(alignment: .top, spacing: 16) {
                libraryCard
                    .frame(minWidth: 280, maxWidth: 360, alignment: .top)
                editorCard
                    .frame(maxWidth: 620, alignment: .top)
            }
        }
        .onAppear {
            if selectedID == nil, let first = store.dashboards.first {
                select(first)
            }
        }
    }

    private var libraryCard: some View {
        NeonCard("Library") {
            VStack(alignment: .leading, spacing: 0) {
                if store.dashboards.isEmpty {
                    Text("No dashboards")
                        .font(.system(size: 13))
                        .foregroundColor(NeonTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    ForEach(store.dashboards) { dashboard in
                        Button { select(dashboard) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: dashboardIcon(for: dashboard))
                                    .frame(width: 22)
                                    .foregroundColor(selectedID == dashboard.id ? .cyan : NeonTheme.textSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dashboard.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(NeonTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(dashboard.host ?? dashboard.urlString)
                                        .font(.system(size: 11))
                                        .foregroundColor(NeonTheme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 9)
                            .padding(.horizontal, 8)
                            .background(selectedID == dashboard.id ? Color.cyan.opacity(0.12) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    Button { newDashboard() } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Button { duplicateSelected() } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedID == nil)

                    Button(role: .destructive) { deleteSelected() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedID == nil)
                }
                .padding(.top, 12)
            }
            .padding(.vertical, 6)
        }
    }

    private var editorCard: some View {
        NeonCard(isEditingExisting ? "Edit Dashboard" : "New Dashboard") {
            VStack(alignment: .leading, spacing: 0) {
                labeledTextField("Name", text: $draft.name, prompt: "Home Assistant")
                NeonDivider()
                labeledTextField("URL", text: $draft.urlString, prompt: "https://home.local:8123")
                NeonDivider()
                authPicker
                authFields

                if !errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errors, id: \.self) { error in
                            Text(error.errorDescription ?? "Invalid dashboard")
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.9))
                        }
                    }
                    .padding(.top, 10)
                } else if !saveMessage.isEmpty {
                    Text(saveMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.green.opacity(0.9))
                        .padding(.top, 10)
                }

                HStack {
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 12)
            }
            .padding(.vertical, 6)
        }
    }

    private var authPicker: some View {
        HStack {
            Text("Auth")
                .font(.system(size: 13))
                .foregroundColor(NeonTheme.textPrimary)
            Spacer(minLength: 16)
            Picker("", selection: $draft.auth.kind) {
                ForEach(DashboardAuthKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 220)
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder private var authFields: some View {
        switch draft.auth.kind {
        case .none:
            EmptyView()
        case .homeAssistant:
            NeonDivider()
            secureRow("Token", text: $secrets.homeAssistantToken)
        case .basic:
            NeonDivider()
            labeledTextField("Username", text: $draft.auth.username, prompt: "admin")
            NeonDivider()
            secureRow("Password", text: $secrets.basicPassword)
        case .customHeaders:
            NeonDivider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach($draft.auth.headers) { $header in
                    HStack(spacing: 8) {
                        TextField("Header", text: $header.name)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Value", text: headerValueBinding(id: header.id))
                            .textFieldStyle(.roundedBorder)
                        Button { removeHeader(header.id) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red.opacity(0.85))
                    }
                }
                Button { addHeader() } label: {
                    Label("Header", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 9)
        }
    }

    private func labeledTextField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(NeonTheme.textPrimary)
                .frame(width: 82, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 9)
    }

    private func secureRow(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(NeonTheme.textPrimary)
                .frame(width: 82, alignment: .leading)
            SecureField(isEditingExisting ? "Leave blank to keep current value" : "Required", text: text)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 9)
    }

    private func select(_ dashboard: DashboardConfig) {
        selectedID = dashboard.id
        draft = dashboard
        secrets = .empty
        errors = []
        saveMessage = ""
    }

    private func newDashboard() {
        selectedID = nil
        draft = DashboardConfig(name: "", urlString: "https://")
        secrets = .empty
        errors = []
        saveMessage = ""
    }

    private func duplicateSelected() {
        guard let id = selectedID, let dashboard = store.dashboard(id: id),
              let copy = try? store.duplicate(dashboard) else { return }
        select(copy)
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        store.delete(id: id)
        if let first = store.dashboards.first { select(first) } else { newDashboard() }
    }

    private func save() {
        let requireSecrets = !isEditingExisting
        do {
            let saved = try store.save(draft, secrets: secrets, requireSecrets: requireSecrets)
            select(saved)
            saveMessage = "Saved"
        } catch DashboardStoreError.validation(let validation) {
            errors = validation
            saveMessage = ""
        } catch {
            errors = []
            saveMessage = error.localizedDescription
        }
    }

    private func addHeader() {
        draft.auth.headers.append(DashboardHeader(name: ""))
    }

    private func removeHeader(_ id: UUID) {
        draft.auth.headers.removeAll { $0.id == id }
        secrets.headerValues[id] = nil
    }

    private func headerValueBinding(id: UUID) -> Binding<String> {
        Binding(
            get: { secrets.headerValues[id] ?? "" },
            set: { secrets.headerValues[id] = $0 }
        )
    }

    private func dashboardIcon(for dashboard: DashboardConfig) -> String {
        dashboard.auth.kind == .homeAssistant ? "house.and.flag" : "globe"
    }
}
