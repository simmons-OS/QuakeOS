import SwiftUI

struct DropInAppsSettingsView: View {
    @ObservedObject private var store = DropInAppStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(title: "Apps",
                           subtitle: "User-installed panel apps discovered from your QuakeOS app folder.")

            HStack(alignment: .top, spacing: 16) {
                folderCard
                    .frame(minWidth: 300, maxWidth: 380, alignment: .top)
                libraryCard
                    .frame(maxWidth: 680, alignment: .top)
            }
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
                    Button { NSWorkspace.shared.open(store.rootURL) } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    Button { store.refresh() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var libraryCard: some View {
        NeonCard("Discovered Apps") {
            VStack(alignment: .leading, spacing: 12) {
                if store.apps.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.apps) { app in
                            appRow(app)
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

    private func appRow(_ app: DropInAppRecord) -> some View {
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
                Text("\(app.manifest.served ? "Served" : "Static") · \(app.manifest.entry)")
                    .font(.system(size: 11))
                    .foregroundColor(NeonTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if app.hasHostCode {
                Text("HOST CODE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(NeonTheme.magenta)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(NeonTheme.magenta.opacity(0.12)))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
}
