// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct SonosFavorite: Codable, Equatable {
    let title: String
    let detail: String
}

enum FavoriteCache {
    static var file: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "SonosHistoryGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("favorites.json")
    }

    static func read() -> [SonosFavorite] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([SonosFavorite].self, from: data)) ?? []
    }

    static func save(_ updated: [SonosFavorite]) -> Bool {
        guard let file else { return false }
        let old = FileManager.default.fileExists(atPath: file.path) ? read() : nil
        guard updated != old else { return false }
        do {
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            return true
        } catch {
            NSLog("Sonos Favorites cache write failed: %@", error.localizedDescription)
            return false
        }
    }
}
