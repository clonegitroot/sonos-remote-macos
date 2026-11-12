// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(updated)
            guard (try? Data(contentsOf: file)) != data else { return false }
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            NSLog("Sonos Favorites cache write failed: %@", error.localizedDescription)
            return false
        }
    }
}

actor ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSURL, NSData>()

    static func url(_ path: String?, host: String) -> URL? {
        guard let path, !path.isEmpty, let base = URL(string: "http://\(host):1400"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    func thumbnail(_ url: URL) async -> Data? {
        if let cached = cache.object(forKey: url as NSURL) { return cached as Data }
        let request = URLRequest(url: url, timeoutInterval: 4)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 8_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 144
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        cache.totalCostLimit = 2_000_000
        cache.setObject((output as Data) as NSData, forKey: url as NSURL, cost: output.length)
        return output as Data
    }
}
