// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import Darwin
import MediaPlayer
import WidgetKit
import ServiceManagement

struct Room: Identifiable {
    let id: String
    let name: String
    let host: String
    let coordinator: String
    let coordinatorID: String
}

enum SonosError: LocalizedError {
    case response, noRooms, rejected(String, Int, String?)
    var errorDescription: String? {
        switch self {
        case let .rejected(action, status, code):
            return "Sonos rejected \(action) (\(code.map { "Sonos error \($0)" } ?? "HTTP \(status)"))."
        case .response: return "The speaker didn’t accept the request."
        case .noRooms: return "No Sonos rooms found. Check Wi-Fi and Local Network access, or enter a speaker IP."
        }
    }
}

enum Sonos {
    static func discover() -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 350_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &address.sin_addr)
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
        let bytes = Array(message.utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        let deadline = Date().addingTimeInterval(1.5)
        var hosts = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            for line in String(decoding: buffer.prefix(count), as: UTF8.self).components(separatedBy: "\r\n") {
                guard line.lowercased().hasPrefix("location:"),
                      let url = URL(string: line.dropFirst(9).trimmingCharacters(in: .whitespaces)),
                      url.port == 1400, let host = url.host else { continue }
                var ip = in_addr()
                if inet_pton(AF_INET, host, &ip) == 1 { hosts.insert(host) }
            }
        }
        return hosts.sorted()
    }

    static func call(_ host: String, _ service: String, _ action: String, _ arguments: String = "") async throws -> XMLDocument {
        let base: String
        switch service {
        case "ZoneGroupTopology": base = ""
        case "ContentDirectory": base = "/MediaServer"
        default: base = "/MediaRenderer"
        }
        var ip = in_addr()
        guard inet_pton(AF_INET, host, &ip) == 1,
              let url = URL(string: "http://\(host):1400\(base)/\(service)/Control") else { throw SonosError.response }
        let urn = "urn:schemas-upnp-org:service:\(service):1"
        let body = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(urn)\">\(arguments)</u:\(action)></s:Body></s:Envelope>"
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(urn)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SonosError.response }
        guard http.statusCode == 200 else {
            let fault = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
            throw SonosError.rejected(action, http.statusCode, fault.flatMap { value($0, "errorCode") })
        }
        return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    static func value(_ doc: XMLDocument, _ name: String) -> String? {
        (try? doc.nodes(forXPath: "//*[local-name()='\(name)']").first)?.stringValue
    }

    static func rooms(_ host: String) async throws -> [Room] {
        let response = try await call(host, "ZoneGroupTopology", "GetZoneGroupState")
        guard let state = value(response, "ZoneGroupState") else { throw SonosError.response }
        let topology = try XMLDocument(xmlString: state, options: [.nodeLoadExternalEntitiesNever])
        var rooms: [Room] = []
        for case let group as XMLElement in try topology.nodes(forXPath: "//ZoneGroup") {
            let members = group.elements(forName: "ZoneGroupMember")
            guard let coordinator = members.first(where: { $0.attribute(forName: "UUID")?.stringValue == group.attribute(forName: "Coordinator")?.stringValue }),
                  let coordinatorHost = hostOf(coordinator) else { continue }
            for member in members where member.attribute(forName: "Invisible")?.stringValue != "1" {
                guard let id = member.attribute(forName: "UUID")?.stringValue,
                      let name = member.attribute(forName: "ZoneName")?.stringValue,
                      let host = hostOf(member) else { continue }
                rooms.append(Room(id: id, name: name, host: host, coordinator: coordinatorHost, coordinatorID: group.attribute(forName: "Coordinator")?.stringValue ?? id))
            }
        }
        guard !rooms.isEmpty else { throw SonosError.noRooms }
        return rooms.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func hostOf(_ member: XMLElement) -> String? {
        guard let location = member.attribute(forName: "Location")?.stringValue else { return nil }
        return URL(string: location)?.host
    }

    static let instance = "<InstanceID>0</InstanceID>"
    static let channel = instance + "<Channel>Master</Channel>"
}

struct PlaybackGroup: Identifiable {
    let id: String
    let rooms: [Room]
    var host: String { rooms[0].coordinator }
    var grouped: Bool { rooms.count > 1 }
    var name: String { rooms.map(\.name).joined(separator: " + ") }
    var service: String { grouped ? "GroupRenderingControl" : "RenderingControl" }
    var prefix: String { grouped ? "Group" : "" }
    var arguments: String { grouped ? Sonos.instance : Sonos.channel }
}

struct AudioLevel {
    let volume: Int
    let muted: Bool
}

extension Sonos {
    static func favorites(_ host: String) async throws -> [SonosFavorite] {
        let args = "<ObjectID>FV:2</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>0</StartingIndex><RequestedCount>5</RequestedCount><SortCriteria></SortCriteria>"
        let response = try await call(host, "ContentDirectory", "Browse", args)
        guard let result = value(response, "Result") else { throw SonosError.response }
        if result.isEmpty { return [] }
        let items = try XMLDocument(xmlString: result, options: [.nodeLoadExternalEntitiesNever])
        return (items.rootElement()?.children ?? []).compactMap { item in
            guard let item = item as? XMLElement,
                  let title = item.children?.first(where: { $0.localName == "title" })?.stringValue,
                  !title.isEmpty else { return nil }
            let detail = item.children?.first(where: { $0.localName == "description" })?.stringValue ?? ""
            return SonosFavorite(title: title, detail: detail)
        }
    }

    static func state(_ host: String) async -> String? {
        guard let doc = try? await call(host, "AVTransport", "GetTransportInfo", instance) else { return nil }
        return value(doc, "CurrentTransportState")
    }

    static func level(_ host: String, _ service: String, _ prefix: String, _ arguments: String) async -> AudioLevel? {
        async let volume = try? call(host, service, "Get\(prefix)Volume", arguments)
        async let mute = try? call(host, service, "Get\(prefix)Mute", arguments)
        guard let volumeDoc = await volume, let muteDoc = await mute,
              let volumeText = value(volumeDoc, "CurrentVolume"), let number = Int(volumeText),
              let muteText = value(muteDoc, "CurrentMute") else { return nil }
        return AudioLevel(volume: min(100, max(0, number)), muted: muteText == "1" || muteText == "true")
    }

    static func nowPlaying(_ host: String) async -> (String, String, URL?) {
        guard let doc = try? await call(host, "AVTransport", "GetPositionInfo", instance) else { return ("", "", nil) }
        let uri = value(doc, "TrackURI") ?? ""
        if uri.hasPrefix("x-sonos-htastream:") { return ("TV audio", "", nil) }
        if uri.hasPrefix("x-rincon-stream:") { return ("Line in", "", nil) }
        guard let metadata = value(doc, "TrackMetaData"),
              let track = try? XMLDocument(xmlString: metadata, options: [.nodeLoadExternalEntitiesNever]) else { return ("", "", nil) }
        return (value(track, "title") ?? "", value(track, "creator") ?? value(track, "artist") ?? "", ArtworkCache.url(value(track, "albumArtURI"), host: host))
    }
}

@MainActor
final class Controller: ObservableObject {
    @Published var groups: [PlaybackGroup] = []
    @Published var selection = ""
    @Published var playingIDs: Set<String> = []
    @Published var levels: [String: AudioLevel] = [:]
    @Published var title = ""
    @Published var artist = ""
    @Published var artworkURL: URL?
    @Published var showArtwork = UserDefaults.standard.bool(forKey: "showArtwork") {
        didSet { UserDefaults.standard.set(showArtwork, forKey: "showArtwork") }
    }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var transportKnown = false
    @Published var transportActions: Set<String>?
    @Published var busy = false
    @Published var error: String?
    @Published var showSettings = false
    @Published var showGrouping = false
    @Published var speakerIP = UserDefaults.standard.string(forKey: "speakerIP") ?? ""
    private var selectedManually = false

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Couldn’t update Launch at Login: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        launchAtLogin = status == .enabled
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var group: PlaybackGroup? { groups.first { $0.id == selection } }
    var playing: Bool { playingIDs.contains(selection) }

    func discover(force: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await loadTopology(force: force)
    }

    private func loadTopology(force: Bool = false) async {
        error = nil
        let manual = speakerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let cached = UserDefaults.standard.string(forKey: "lastHost")
        var found: [Room]?
        if !manual.isEmpty {
            found = try? await Sonos.rooms(manual)
        } else {
            if !force, let cached { found = try? await Sonos.rooms(cached) }
            if found == nil {
                var hosts = await Task.detached(operation: Sonos.discover).value
                if let cached, !hosts.contains(cached) { hosts.append(cached) }
                for host in hosts {
                    if let rooms = try? await Sonos.rooms(host) {
                        found = rooms
                        break
                    }
                }
            }
        }
        guard let found else {
            groups = []
            levels = [:]
            transportKnown = false
            error = SonosError.noRooms.localizedDescription
            return
        }
        UserDefaults.standard.set(manual, forKey: "speakerIP")
        UserDefaults.standard.set(found[0].host, forKey: "lastHost")
        let current = Dictionary(grouping: found, by: \.coordinatorID)
            .map { PlaybackGroup(id: $0.key, rooms: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let active = await withTaskGroup(of: (String, Bool).self, returning: Set<String>.self) { tasks in
            for group in current {
                tasks.addTask { (group.id, await Sonos.state(group.host) == "PLAYING") }
            }
            var active = Set<String>()
            for await (id, playing) in tasks where playing { active.insert(id) }
            return active
        }
        let remembered = UserDefaults.standard.string(forKey: "selectedGroup")
        let preferred = current.first { $0.id == remembered }
        let firstPlaying = current.first { active.contains($0.id) }
        let currentSelection = current.first { $0.id == selection }
        let chosen = (selectedManually ? currentSelection : nil)
            ?? (preferred.flatMap { active.contains($0.id) ? $0 : nil })
            ?? firstPlaying ?? preferred ?? current[0]
        groups = current
        playingIDs = active
        selection = chosen.id
        await read()
        let favoriteHosts = [chosen.host] + found.map(\.host).filter { $0 != chosen.host }
        for host in favoriteHosts {
            guard let favorites = try? await Sonos.favorites(host) else { continue }
            if FavoriteCache.save(favorites) {
                NSLog("Updated Sonos Favorites cache with %d items", favorites.count)
                WidgetCenter.shared.reloadTimelines(ofKind: "SonosRemoteDesktop")
            }
            break
        }
    }

    func select(_ id: String) async {
        guard !busy, groups.contains(where: { $0.id == id }) else { return }
        selection = id
        selectedManually = true
        UserDefaults.standard.set(id, forKey: "selectedGroup")
        levels = [:]
        title = ""
        artist = ""
        artworkURL = nil
        transportKnown = false
        await refresh()
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await read()
    }

    private func read() async {
        guard let group else { return }
        async let audio = Sonos.level(group.host, group.service, group.prefix, group.arguments)
        async let state = Sonos.state(group.host)
        async let track = Sonos.nowPlaying(group.host)
        async let actions = try? Sonos.call(group.host, "AVTransport", "GetCurrentTransportActions", Sonos.instance)
        var updated = await withTaskGroup(of: (String, AudioLevel?).self, returning: [String: AudioLevel].self) { tasks in
            if group.grouped {
                for room in group.rooms {
                    tasks.addTask { (room.id, await Sonos.level(room.host, "RenderingControl", "", Sonos.channel)) }
                }
            }
            var result: [String: AudioLevel] = [:]
            for await (id, level) in tasks { result[id] = level }
            return result
        }
        updated["master"] = await audio
        levels = updated
        let status = await state
        transportKnown = status != nil
        transportActions = await actions.flatMap { Sonos.value($0, "Actions") }
            .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }) }
        if status == "PLAYING" { playingIDs.insert(group.id) }
        else { playingIDs.remove(group.id) }
        (title, artist, artworkURL) = await track
        let nowPlaying = MPNowPlayingInfoCenter.default()
        if let status, status == "PLAYING" || status == "PAUSED_PLAYBACK" {
            nowPlaying.nowPlayingInfo = [
                MPMediaItemPropertyTitle: title.isEmpty ? group.name : title,
                MPMediaItemPropertyArtist: artist,
                MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
            ]
            nowPlaying.playbackState = playing ? .playing : .paused
        } else {
            nowPlaying.nowPlayingInfo = nil
            nowPlaying.playbackState = .stopped
        }

        error = status == nil && updated.isEmpty ? "This group is unreachable. Refresh to reconnect." : nil
    }

    private func perform(refreshTopology: Bool = false, _ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await operation()
            if refreshTopology { await loadTopology() }
            else { await read() }
        } catch {
            await read()
            self.error = error.localizedDescription
        }
    }

    func supports(_ action: String) -> Bool {
        transportKnown && (transportActions?.contains(action.lowercased()) ?? true)
    }

    func transport(_ action: String) async {
        guard let group, supports(action) else { return }
        await perform {
            let speed = action == "Play" ? "<Speed>1</Speed>" : ""
            _ = try await Sonos.call(group.host, "AVTransport", action, Sonos.instance + speed)
        }
    }

    func adjust(_ room: Room?, volume: Int? = nil) async {
        guard let group, let level = levels[room?.id ?? "master"] else { return }
        let host = room?.host ?? group.host
        let service = room == nil ? group.service : "RenderingControl"
        let prefix = room == nil ? group.prefix : ""
        let args = room == nil ? group.arguments : Sonos.channel
        await perform {
            if let volume {
                if prefix == "Group" {
                    _ = try await Sonos.call(host, service, "SnapshotGroupVolume", args)
                }
                _ = try await Sonos.call(host, service, "Set\(prefix)Volume", args + "<DesiredVolume>\(volume)</DesiredVolume>")
            } else {
                _ = try await Sonos.call(host, service, "Set\(prefix)Mute", args + "<DesiredMute>\(level.muted ? 0 : 1)</DesiredMute>")
            }
        }
    }

    func syncVolumes() async {
        guard !busy, let group, group.grouped else { return }
        busy = true
        defer { busy = false }
        do {
            let currentRooms = try await Sonos.rooms(group.host)
                .filter { $0.coordinatorID == group.id }
            guard Set(currentRooms.map(\.id)) == Set(group.rooms.map(\.id)) else {
                await loadTopology()
                error = "Group membership changed. Check the rooms and try again."
                return
            }
            guard let level = await Sonos.level(group.host, group.service, group.prefix, group.arguments) else {
                throw SonosError.response
            }
            let args = Sonos.channel + "<DesiredVolume>\(level.volume)</DesiredVolume>"
            await withTaskGroup(of: Void.self) { tasks in
                for room in currentRooms {
                    tasks.addTask {
                        _ = try? await Sonos.call(room.host, "RenderingControl", "SetVolume", args)
                    }
                }
            }
            await read()
            let unsynced = group.rooms.filter { levels[$0.id]?.volume != level.volume }
            if !unsynced.isEmpty {
                error = "Couldn’t sync " + unsynced.map(\.name).joined(separator: ", ") + "."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runWidgetAction(_ action: String) async {
        while busy {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        if group == nil { await discover() }
        else { await refresh() }
        switch action {
        case "toggle":
            if transportKnown { await transport(playing ? "Pause" : "Play") }
        case "play": await transport("Play")
        case "pause": await transport("Pause")
        case "previous": await transport("Previous")
        case "next": await transport("Next")
        case "quieter", "louder":
            if let volume = levels["master"]?.volume {
                let change = action == "quieter" ? -5 : 5
                await adjust(nil, volume: min(100, max(0, volume + change)))
            }
        case "mute": await adjust(nil)
        case "sync": await syncVolumes()
        default: break
        }
    }

    func move(_ room: Room, into group: PlaybackGroup?) async {
        await perform(refreshTopology: true) {
            if let group {
                guard group.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) else {
                    throw SonosError.response
                }
                let args = Sonos.instance + "<CurrentURI>x-rincon:\(group.id)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
                _ = try await Sonos.call(room.host, "AVTransport", "SetAVTransportURI", args)
            } else {
                _ = try await Sonos.call(room.host, "AVTransport", "BecomeCoordinatorOfStandaloneGroup", Sonos.instance)
            }
            try await Task.sleep(for: .milliseconds(450))
        }
    }
}

struct VolumeRow: View {
    let label: String
    let level: AudioLevel
    let setVolume: (Int) -> Void
    let toggleMute: () -> Void
    @StateObject private var edit = VolumeEdit()

    var body: some View {
        HStack(spacing: 9) {
            Button(action: toggleMute) {
                Image(systemName: level.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
            }.buttonStyle(.borderless).help(level.muted ? "Unmute \(label)" : "Mute \(label)")
            Slider(value: Binding(get: { edit.value ?? Double(level.volume) }, set: { newValue in
                if edit.editing { edit.value = newValue }
                else { setVolume(Int(newValue)) }
            }), in: 0...100, step: 1) { editing in
                edit.editing = editing
                if !editing, let value = edit.value {
                    edit.value = nil
                    setVolume(Int(value))
                }
            }.accessibilityLabel("\(label) volume")
            Text("\(Int(edit.value ?? Double(level.volume)))%").monospacedDigit()
                .font(.caption).foregroundStyle(.secondary).frame(width: 33, alignment: .trailing)
        }
    }
}

final class VolumeEdit: ObservableObject {
    @Published var value: Double?
    var editing = false
}

struct CoverThumbnail: View {
    let url: URL?
    @StateObject private var cover = CoverImage()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image = cover.image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: 100, height: 100)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: url) {
            cover.image = nil
            if let url, let data = await ArtworkCache.shared.thumbnail(url), !Task.isCancelled {
                cover.image = NSImage(data: data)
            }
        }
    }
}

@MainActor
final class CoverImage: ObservableObject {
    @Published var image: NSImage?
}

struct Controls: View {
    @ObservedObject var model: Controller
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Sonos Remote", systemImage: "hifispeaker.2.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                icon("arrow.clockwise", "Refresh speakers") { await model.discover(force: true) }
                Menu {
                    Button("Setup & Shortcuts", action: openSetup)
                    Toggle("Show Artwork", isOn: $model.showArtwork)
                    Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin },
                                                            set: { model.setLaunchAtLogin($0) }))
                    Button(model.showSettings ? "Hide Connection Settings" : "Connection Settings") {
                        model.showSettings.toggle()
                    }
                    Divider()
                    Button("Quit Sonos Remote") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }.onAppear { model.refreshLaunchAtLogin() }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().accessibilityLabel("Sonos Remote options")
            }
            if let group = model.group {
                Picker("Playback destination", selection: Binding(get: { model.selection }, set: { id in
                    Task { await model.select(id) }
                })) {
                    ForEach(model.groups) { group in
                        Label(group.name, systemImage: model.playingIDs.contains(group.id) ? "waveform" : (group.grouped ? "hifispeaker.2" : "hifispeaker"))
                            .tag(group.id)
                    }
                }.labelsHidden().disabled(model.busy)
                Group {
                    if model.showArtwork {
                        HStack(alignment: .top, spacing: 16) {
                            CoverThumbnail(url: model.artworkURL)
                            VStack(alignment: .leading, spacing: 8) {
                                trackDetails(alignment: .leading)
                                Spacer(minLength: 0)
                                playbackControls
                            }
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                            .frame(height: 100)
                        }
                    } else {
                        VStack(spacing: 16) {
                            trackDetails(alignment: .center)
                            playbackControls
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 10)
                Divider()
                if let level = model.levels["master"] {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.grouped ? "Group volume" : "Room volume").font(.caption).foregroundStyle(.secondary)
                        volume(nil, level).id(group.id)
                    }
                }
                DisclosureGroup("Rooms & Group", isExpanded: $model.showGrouping) {
                    if group.grouped {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(group.rooms) { room in
                                if let level = model.levels[room.id] {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(room.name).font(.caption).foregroundStyle(.secondary)
                                        volume(room, level)
                                    }
                                }
                            }
                            Button {
                                Task { await model.syncVolumes() }
                            } label: {
                                Label("Sync Room Volumes", systemImage: "slider.horizontal.3")
                            }.disabled(model.busy || model.levels["master"] == nil)
                                .help("Set every room to the current group volume")
                        }.padding(.vertical, 8)
                        Divider()
                    }
                    ForEach(group.rooms.filter { $0.id != group.id }) { room in
                        HStack {
                            Text(room.name)
                            Spacer()
                            Button("Remove") { Task { await model.move(room, into: nil) } }
                        }.padding(.top, 5)
                    }
                    let available = model.groups.filter { $0.id != group.id }.flatMap(\.rooms)
                        .filter { $0.id != $0.coordinatorID }
                    let standalone = model.groups.filter { $0.id != group.id && !$0.grouped }.flatMap(\.rooms)
                    let candidates = standalone + available
                    if !candidates.isEmpty {
                        Menu("Add a room") {
                            ForEach(candidates) { room in
                                Button(room.name) { Task { await model.move(room, into: group) } }
                            }
                        }.padding(.top, 5)
                    } else if !group.grouped {
                        Text("No other rooms available.").foregroundStyle(.secondary).padding(.top, 5)
                    }
                }.disabled(model.busy)
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.secondary) }
            if model.showSettings || (model.groups.isEmpty && model.error != nil) {
                TextField("Speaker IP (optional)", text: $model.speakerIP)
                    .onSubmit { Task { await model.discover(force: true) } }
                Button("Connect") { Task { await model.discover(force: true) } }.disabled(model.busy)
            }
        }
        .padding(16).frame(width: 330)
        .task {
            await model.discover()
        }
    }

    private func trackDetails(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(model.title.isEmpty ? (model.playing ? "Playing" : "No track information") : model.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
            if !model.artist.isEmpty {
                Text(model.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 24) {
            icon("backward.fill", "Previous track") { await model.transport("Previous") }
                .disabled(!model.supports("Previous"))
            icon(model.playing ? "pause.circle.fill" : "play.circle.fill", model.playing ? "Pause" : "Play") {
                await model.transport(model.playing ? "Pause" : "Play")
            }.font(.system(size: 35)).disabled(!model.supports(model.playing ? "Pause" : "Play"))
            icon("forward.fill", "Next track") { await model.transport("Next") }
                .disabled(!model.supports("Next"))
        }.font(.title3).disabled(!model.transportKnown)
    }

    func icon(_ symbol: String, _ title: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol).frame(minWidth: 24, minHeight: 24)
        }.buttonStyle(.borderless).help(title).accessibilityLabel(title).disabled(model.busy)
    }

    func volume(_ room: Room?, _ level: AudioLevel) -> some View {
        VolumeRow(label: room?.name ?? "Playback destination", level: level) { value in
            Task { await model.adjust(room, volume: value) }
        } toggleMute: {
            Task { await model.adjust(room) }
        }.disabled(model.busy)
    }
}

@MainActor
final class RemoteDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = Controller()
    private var monitor: Task<Void, Never>?
    private lazy var shortcuts = Shortcuts(model: model)
    private var setupWindow: NSWindow?

    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow()
            window.styleMask = [.titled, .closable]
            window.title = "Sonos Remote Setup"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SetupPanel(model: model, shortcuts: shortcuts) { [weak self] in
                UserDefaults.standard.set(true, forKey: "completedSetup")
                self?.setupWindow?.close()
                self?.startMonitor()
            })
            window.center()
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = MPRemoteCommandCenter.shared()
        let actions: [(MPRemoteCommand, String)] = [
            (center.togglePlayPauseCommand, "toggle"), (center.playCommand, "play"),
            (center.pauseCommand, "pause"), (center.nextTrackCommand, "next"),
            (center.previousTrackCommand, "previous")
        ]
        for (command, action) in actions {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                Task { @MainActor in await self?.model.runWidgetAction(action) }
                return .success
            }
        }
        shortcuts.start()
        if UserDefaults.standard.bool(forKey: "completedSetup") {
            startMonitor()
        } else {
            showSetup()
        }
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = Task { [model] in
            await model.discover()
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(12)) } catch { break }
                ticks += 1
                if model.group == nil || ticks.isMultiple(of: 5) { await model.discover() }
                else { await model.refresh() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.cancel()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let actions = urls.filter { $0.scheme == "sonosremote-local" && $0.host == "widget" }
            .map { $0.lastPathComponent }
        Task {
            for action in actions { await model.runWidgetAction(action) }
        }
    }
}

@main
struct SonosRemote: App {
    @NSApplicationDelegateAdaptor(RemoteDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("Sonos Remote", systemImage: "hifispeaker.2.fill") {
            Controls(model: delegate.model, openSetup: delegate.showSetup)
        }.menuBarExtraStyle(.window)
    }
}
