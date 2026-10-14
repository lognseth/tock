import Carbon.HIToolbox

/// Global hotkey via Carbon. Needs no accessibility permission.
final class HotKey {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// Returns nil when the system refuses the combo (usually because another app owns it).
    init?(id: UInt32, combo: KeyCombo, handler: @escaping () -> Void) {
        Self.installHandler()
        self.id = id
        let hotKeyID = EventHotKeyID(signature: OSType(0x544F434B), id: id)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), UInt32(combo.modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKey.handlers[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
