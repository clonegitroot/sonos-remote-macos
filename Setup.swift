// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import Carbon

enum ShortcutAction: String, CaseIterable, Identifiable {
    case louder, quieter, mute, toggle, previous, next
    var id: String { rawValue }
    var label: String {
        switch self {
        case .louder: "Volume up"
        case .quieter: "Volume down"
        case .mute: "Toggle mute"
        case .toggle: "Play / pause"
        case .previous: "Previous track"
        case .next: "Next track"
        }
    }
}

struct ShortcutKey: Identifiable {
    let id: Int
    let label: String
    static let choices: [ShortcutKey] = [
        .init(id: -1, label: "Off"),
        .init(id: kVK_UpArrow, label: "↑"), .init(id: kVK_DownArrow, label: "↓"),
        .init(id: kVK_LeftArrow, label: "←"), .init(id: kVK_RightArrow, label: "→"),
        .init(id: kVK_Space, label: "Space"), .init(id: kVK_ANSI_M, label: "M"),
        .init(id: kVK_ANSI_K, label: "K"), .init(id: kVK_ANSI_J, label: "J"),
        .init(id: kVK_ANSI_L, label: "L"), .init(id: kVK_ANSI_U, label: "U"),
        .init(id: kVK_ANSI_I, label: "I"), .init(id: kVK_ANSI_O, label: "O")
    ]
}

@MainActor
final class Shortcuts: ObservableObject {
    @Published private(set) var keys: [String: Int]
    @Published private(set) var modifier: Int
    @Published private(set) var error: String?
    private var registrations: [ShortcutAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let model: Controller

    init(model: Controller) {
        self.model = model
        keys = UserDefaults.standard.dictionary(forKey: "shortcutKeys") as? [String: Int] ?? [:]
        modifier = UserDefaults.standard.integer(forKey: "shortcutModifier")
    }

    func start() {
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x534F4E52 else { return OSStatus(eventNotHandledErr) }
            let index = Int(id.id)
            let shortcuts = Unmanaged<Shortcuts>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                guard ShortcutAction.allCases.indices.contains(index) else { return }
                await shortcuts.model.runWidgetAction(ShortcutAction.allCases[index].rawValue)
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { error = "macOS couldn’t start global shortcuts."; return }
        apply(keys, modifier: modifier)
    }

    func apply(_ proposed: [String: Int], modifier proposedModifier: Int) {
        guard handler != nil else { return }
        registrations.values.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
        let masks = [controlKey | optionKey, controlKey | shiftKey, controlKey | optionKey | shiftKey]
        let index = min(max(0, proposedModifier), masks.count - 1)
        var accepted: [String: Int] = [:]
        var unavailable: [String] = []
        for (offset, action) in ShortcutAction.allCases.enumerated() {
            guard let key = proposed[action.id], key >= 0,
                  ShortcutKey.choices.contains(where: { $0.id == key }) else { continue }
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x534F4E52, id: UInt32(offset))
            let status = accepted.values.contains(key) ? OSStatus(eventHotKeyExistsErr) :
                RegisterEventHotKey(UInt32(key), UInt32(masks[index]), identifier, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                registrations[action] = reference
                accepted[action.id] = key
            } else {
                unavailable.append(action.label)
            }
        }
        keys = accepted
        modifier = index
        error = unavailable.isEmpty ? nil : "Shortcut unavailable for " + unavailable.joined(separator: ", ") + "."
        UserDefaults.standard.set(accepted, forKey: "shortcutKeys")
        UserDefaults.standard.set(index, forKey: "shortcutModifier")
    }
}

struct SetupPanel: View {
    @ObservedObject var model: Controller
    @ObservedObject var shortcuts: Shortcuts
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Set up Sonos Remote", systemImage: "hifispeaker.2.fill").font(.title2.bold())
            Text("Connect your Mac to the same network as your speakers. Choose Connect, then allow Local Network access if macOS asks.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Speaker IPv4 address (optional)", text: $model.speakerIP)
                .onSubmit(connect)
            HStack {
                Button("Connect", action: connect).disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                else if !model.groups.isEmpty {
                    Label("\(model.groups.count) playback destinations found", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.secondary) }
            Divider()
            Text("Global shortcuts").font(.headline)
            Text("Optional. These target the selected room or group. They require no keyboard-monitoring permission.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Modifiers", selection: Binding(get: { shortcuts.modifier }, set: {
                shortcuts.apply(shortcuts.keys, modifier: $0)
            })) {
                Text("Control + Option").tag(0)
                Text("Control + Shift").tag(1)
                Text("Control + Option + Shift").tag(2)
            }
            ForEach(ShortcutAction.allCases) { action in
                Picker(action.label, selection: Binding(get: { shortcuts.keys[action.id] ?? -1 }, set: { key in
                    var keys = shortcuts.keys
                    keys[action.id] = key
                    shortcuts.apply(keys, modifier: shortcuts.modifier)
                })) {
                    ForEach(ShortcutKey.choices) { Text($0.label).tag($0.id) }
                }
            }
            if let error = shortcuts.error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }.padding(24).frame(width: 460)
    }

    func connect() {
        Task { await model.discover(force: true) }
    }
}
