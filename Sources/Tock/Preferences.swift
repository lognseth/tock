import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int  // Carbon modifier mask
    var label: String

    static let defaultOpen = KeyCombo(keyCode: kVK_Space, modifiers: controlKey | optionKey, label: "Space")
    static let defaultQuickAdd = KeyCombo(keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey, label: "N")

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + label
    }

    init(keyCode: Int, modifiers: Int, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// Builds a combo from a key event. Needs ⌃, ⌥ or ⌘ (or an F-key) so plain typing can't be captured.
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = 0
        if f.contains(.control) { mods |= controlKey }
        if f.contains(.option) { mods |= optionKey }
        if f.contains(.shift) { mods |= shiftKey }
        if f.contains(.command) { mods |= cmdKey }
        let code = Int(event.keyCode)
        let special = Self.specialKeys[code]
        let isFKey = special?.hasPrefix("F") ?? false
        guard mods & (controlKey | optionKey | cmdKey) != 0 || isFKey else { return nil }
        let label = special ?? (event.charactersIgnoringModifiers?.uppercased() ?? "")
        guard !label.isEmpty else { return nil }
        self.init(keyCode: code, modifiers: mods, label: label)
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    @Published var filePath: String? { didSet { defaults.set(filePath, forKey: "filePath"); onChange?() } }
    @Published var openHotKey: KeyCombo { didSet { save(openHotKey, "openHotKey"); onChange?() } }
    @Published var quickAddHotKey: KeyCombo { didSet { save(quickAddHotKey, "quickAddHotKey"); onChange?() } }
    @Published var showBadge: Bool { didSet { defaults.set(showBadge, forKey: "showBadge"); onChange?() } }
    @Published var stampDone: Bool { didSet { defaults.set(stampDone, forKey: "stampDone") } }
    @Published var showDoneByDefault: Bool { didSet { defaults.set(showDoneByDefault, forKey: "showDoneByDefault") } }
    @Published var newTaskHeading: String { didSet { defaults.set(newTaskHeading, forKey: "newTaskHeading") } }
    @Published var openInWindow: Bool { didSet { defaults.set(openInWindow, forKey: "openInWindow") } }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock"); onChange?() } }
    @Published var obsidianEnabled: Bool { didSet { defaults.set(obsidianEnabled, forKey: "obsidianEnabled") } }
    @Published var hotKeyError: String?
    @Published var loginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        filePath = defaults.string(forKey: "filePath")
        openHotKey = Self.load("openHotKey", from: defaults) ?? .defaultOpen
        quickAddHotKey = Self.load("quickAddHotKey", from: defaults) ?? .defaultQuickAdd
        showBadge = defaults.object(forKey: "showBadge") as? Bool ?? true
        stampDone = defaults.object(forKey: "stampDone") as? Bool ?? false
        showDoneByDefault = defaults.object(forKey: "showDoneByDefault") as? Bool ?? true
        newTaskHeading = defaults.string(forKey: "newTaskHeading") ?? ""
        openInWindow = defaults.object(forKey: "openInWindow") as? Bool ?? false
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? false
        obsidianEnabled = defaults.object(forKey: "obsidianEnabled") as? Bool ?? false
    }

    private func save(_ combo: KeyCombo, _ key: String) {
        defaults.set(try? JSONEncoder().encode(combo), forKey: key)
    }

    private static func load(_ key: String, from defaults: UserDefaults) -> KeyCombo? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }
}
