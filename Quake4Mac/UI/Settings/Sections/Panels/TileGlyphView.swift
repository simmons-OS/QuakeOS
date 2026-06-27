// TileGlyphView.swift — Quake4Mac settings app
//
// Shared glyph renderer for the tile library. Resolves the SAME real icon the device shows:
// DecoKee PNG (image) → real macOS app icon (launchApp) → site favicon (openURL) → SF Symbol
// fallback, behind a soft tinted glow. So the library matches the strip/device, not a lookalike.

import SwiftUI
import AppKit

struct TileGlyphView: View {
    let symbol: String          // SF Symbol fallback
    let image: String?          // DecoKee PNG name in Icons/
    let tint: Color
    var appBundleID: String? = nil   // launchApp → real app icon
    var url: String? = nil           // openURL → favicon
    var size: CGFloat = 88
    var customIcon: TileIcon? = nil

    @State private var favicon: NSImage? = nil

    /// Best real icon available synchronously (PNG or app icon); favicon arrives async into state.
    private var realIcon: NSImage? {
        if let path = customImagePath {
            let expanded = (path as NSString).expandingTildeInPath
            if let img = NSImage(contentsOfFile: expanded) { return img }
        }
        if let image, let p = DecoAssets.icon(image) { return p }
        if let bid = appBundleID, let a = DecoAssets.appIcon(bid) { return a }
        return favicon
    }

    private var customImagePath: String? {
        switch customIcon {
        case .imagePath(let path): return path
        case .imageURL(_, let cachePath): return cachePath
        case .emoji, .none: return nil
        }
    }

    private var emoji: String? {
        guard case .emoji(let value)? = customIcon else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint)
                .frame(width: size * 0.66, height: size * 0.66)
                .blur(radius: size * 0.26)
                .opacity(0.5)

            if let emoji {
                Text(emoji)
                    .font(.system(size: size * 0.46))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: size * 0.62, height: size * 0.62)
            } else if let img = realIcon {
                Image(nsImage: img)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: size * 0.62, height: size * 0.62)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: tint.opacity(0.7), radius: size * 0.07)
            }
        }
        .frame(width: size, height: size)
        .onAppear(perform: loadFaviconIfNeeded)
    }

    private func loadFaviconIfNeeded() {
        guard customIcon == nil, image == nil, appBundleID == nil, favicon == nil,
              let url, let host = URL(string: url)?.host else { return }
        if let cached = TileGlyphView.favCache[host] { favicon = cached; return }
        guard let fav = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128") else { return }
        URLSession.shared.dataTask(with: fav) { data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async { TileGlyphView.favCache[host] = img; favicon = img }
        }.resume()
    }

    private static var favCache: [String: NSImage] = [:]
}
