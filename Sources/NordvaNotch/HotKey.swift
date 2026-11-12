import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's hot keys. Unlike a global key monitor it needs no
/// Accessibility permission, and the key press does not reach other apps.
final class HotKey {
    enum Shortcut: String, CaseIterable, Identifiable {
        case off
        case optionCommandL
        case controlCommandL
        case commandL

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .optionCommandL: return "⌥⌘L"
            case .controlCommandL: return "⌃⌘L"
            case .commandL: return "⌘L (takes it from every app)"
            }
        }

        var modifiers: UInt32? {
            switch self {
            case .off: return nil
            case .optionCommandL: return UInt32(cmdKey | optionKey)
            case .controlCommandL: return UInt32(cmdKey | controlKey)
            case .commandL: return UInt32(cmdKey)
            }
        }
    }

    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?
    private let id: UInt32
    private var ref: EventHotKeyRef?

    init?(_ shortcut: Shortcut, id: UInt32 = 1, action: @escaping () -> Void) {
        guard let modifiers = shortcut.modifiers, Self.installHandler() else { return nil }
        self.id = id
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4E_4F54), id: id) // "NNOT"
        guard RegisterEventHotKey(UInt32(kVK_ANSI_L), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil
        }
        Self.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    /// One handler for every hot key of the app; the C callback cannot capture, so it looks the action up.
    private static func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            DispatchQueue.main.async { HotKey.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
        return status == noErr
    }
}
