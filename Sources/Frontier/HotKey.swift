import AppKit
import Carbon.HIToolbox

/// System-wide hotkey via Carbon — needs no Accessibility permission.
final class HotKey {
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var modifiers: NSEvent.ModifierFlags = []

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().onPress?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Returns false if the combination is already taken by another app.
    @discardableResult
    func register(_ choice: HotKeyChoice) -> Bool {
        unregister()
        let key: Int
        let carbon: Int
        switch choice {
        case .optionTab: key = kVK_Tab; carbon = optionKey; modifiers = .option
        case .optionSpace: key = kVK_Space; carbon = optionKey; modifiers = .option
        case .controlOptionSpace: key = kVK_Space; carbon = optionKey | controlKey; modifiers = [.option, .control]
        }
        let id = EventHotKeyID(signature: OSType(0x46524E54), id: 1)   // 'FRNT'
        let status = RegisterEventHotKey(UInt32(key), UInt32(carbon), id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
