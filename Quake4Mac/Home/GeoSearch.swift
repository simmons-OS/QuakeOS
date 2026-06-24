// GeoSearch.swift — Quake4Mac
//
// Shared city search via Open-Meteo's geocoding API (free, no key). Used by the Weather and Clock
// settings to look up any city/town and get its coordinates + time zone.

import Foundation

struct GeoResult: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let admin1: String?      // state / region
    let country: String?
    let lat: Double
    let lon: Double
    let timezone: String?

    var label: String {
        [name, admin1, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum GeoSearch {
    /// Look up places matching `query`. Returns [] on empty/failed search.
    static func search(_ query: String) async -> [GeoResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2,
              let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(enc)&count=10&language=en&format=json")
        else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(GeoResponse.self, from: data)
            return (decoded.results ?? []).map {
                GeoResult(name: $0.name, admin1: $0.admin1, country: $0.country,
                          lat: $0.latitude, lon: $0.longitude, timezone: $0.timezone)
            }
        } catch { return [] }
    }

    private struct GeoResponse: Codable { let results: [Row]? }
    private struct Row: Codable {
        let name: String; let admin1: String?; let country: String?
        let latitude: Double; let longitude: Double; let timezone: String?
    }
}
