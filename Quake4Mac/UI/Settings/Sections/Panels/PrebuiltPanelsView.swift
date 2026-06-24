// PrebuiltPanelsView.swift — Quake4Mac settings app
//
// The per-panel settings screens for the built-in panels, reached by expanding "Prebuilt Panels"
// in the sidebar and clicking a child. Music carries real config (player style + Spotify link);
// System Monitor is fully automatic. No model changes — binds to SpotifyAuth.shared + AppStorage.

import SwiftUI

// MARK: - Music

struct MusicPanelView: View {
    @ObservedObject private var auth = SpotifyAuth.shared
    @AppStorage("music.style") private var musicStyle = "clean"
    @State private var clientField = SpotifyAuth.shared.clientID

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeader(title: "Music", subtitle: "On-screen player style and Spotify connection.")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                NeonCard("Player") {
                    NeonPickerRow(label: "On-screen style", selection: $musicStyle,
                                  options: [("clean", "Clean"), ("vinyl", "Vinyl")])
                }

                NeonCard("Spotify") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Connection").font(.system(size: 13, weight: .semibold)).foregroundColor(NeonTheme.textPrimary)
                            Spacer(minLength: 8)
                            if auth.isConnected {
                                Label("Connected", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11, weight: .medium)).foregroundColor(NeonTheme.cyan)
                            } else {
                                Text("Not connected").font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                            }
                        }
                        Text("Powers queue, playlists, and album art. Create a free app at developer.spotify.com, "
                             + "add the redirect URI below, then paste the Client ID.")
                            .font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        neonField("Client ID", text: $clientField)
                        HStack(spacing: 6) {
                            Text("Redirect URI").font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                            Text(SpotifyAuth.redirectURI)
                                .font(.system(size: 11).monospaced()).foregroundColor(NeonTheme.textSecondary)
                                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        }
                        HStack(spacing: 10) {
                            pillButton(auth.isConnected ? "Reconnect" : "Connect Spotify", NeonTheme.cyan) {
                                auth.saveClientID(clientField); auth.connect()
                            }
                            if auth.isConnected {
                                pillButton("Disconnect", NeonTheme.magenta) { auth.disconnect() }
                            }
                        }
                        if !auth.lastError.isEmpty {
                            Text(auth.lastError).font(.system(size: 11)).foregroundColor(Color(red: 1, green: 0.4, blue: 0.4))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func neonField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
    }

    private func pillButton(_ title: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(tint)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - System Monitor

struct SystemMonitorPanelView: View {
    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 16, alignment: .top)]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeader(title: "System Monitor", subtitle: "Live system stats — fully automatic.")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            NeonCard("System Monitor") {
                NeonInfoRow(label: "Setup", value: "Automatic")
                NeonDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shows").font(.system(size: 11, weight: .semibold)).foregroundColor(NeonTheme.textTertiary)
                    Text("CPU & GPU load/temp, memory, network up/down, Wi-Fi, battery, disk usage, and top processes — all live, no configuration needed.")
                        .font(.system(size: 11)).foregroundColor(NeonTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Wi-Fi network name needs Location access; everything else works out of the box.")
                        .font(.system(size: 10)).foregroundColor(NeonTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
                .padding(.vertical, 10)
            }
            }
        }
    }
}
