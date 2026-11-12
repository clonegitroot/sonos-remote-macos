// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import WidgetKit

struct RemoteEntry: TimelineEntry {
    let date: Date
    let favorites: [SonosFavorite]
}

struct RemoteTimeline: TimelineProvider {
    func placeholder(in context: Context) -> RemoteEntry { RemoteEntry(date: .now, favorites: []) }
    func getSnapshot(in context: Context, completion: @escaping (RemoteEntry) -> Void) {
        completion(RemoteEntry(date: .now, favorites: FavoriteCache.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RemoteEntry>) -> Void) {
        completion(Timeline(entries: [RemoteEntry(date: .now, favorites: FavoriteCache.read())], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct RemoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RemoteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sonos Remote", systemImage: "hifispeaker.2.fill")
                .font(family == .systemSmall ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                command("backward.fill", "Previous track", "previous")
                command("playpause.fill", "Play or pause", "toggle")
                command("forward.fill", "Next track", "next")
                if family != .systemSmall {
                    Spacer(minLength: 8)
                    volumeCommands
                }
            }
            if family == .systemSmall {
                HStack(spacing: 6) { volumeCommands }
            } else {
                Link(destination: destination("sync")) {
                    Label("Sync room volumes", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                }
            }
            if family == .systemLarge {
                Divider()
                Text("Sonos Favorites").font(.headline)
                if entry.favorites.isEmpty {
                    Text("Saved playlists and stations appear here when Sonos Remote connects.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(entry.favorites.prefix(5).enumerated()), id: \.offset) { _, favorite in
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill").foregroundStyle(.secondary)
                        Text(favorite.title).lineLimit(1).fontWeight(.medium)
                        Spacer(minLength: 4)
                        Text(favorite.detail).lineLimit(1).foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.13, green: 0.28, blue: 0.26),
                                    Color(red: 0.07, green: 0.11, blue: 0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var volumeCommands: some View {
        command("speaker.minus.fill", "Volume down", "quieter")
        command("speaker.plus.fill", "Volume up", "louder")
    }

    func command(_ symbol: String, _ label: String, _ action: String) -> some View {
        Link(destination: destination(action)) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: family == .systemSmall ? 28 : 35)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
        }.accessibilityLabel(label)
    }

    func destination(_ action: String) -> URL {
        URL(string: "sonosremote-local://widget/\(action)")!
    }
}

struct SonosDesktopWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonosRemoteDesktop", provider: RemoteTimeline()) { entry in
            RemoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Sonos Remote")
        .description("Control playback and volume for your selected Sonos room or group.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct SonosWidgetBundle: WidgetBundle {
    var body: some Widget { SonosDesktopWidget() }
}
