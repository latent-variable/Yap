import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hot key via the Carbon hot-key API
/// (still the most reliable route for a global shortcut on macOS).
final class HotKeyManager {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: EventHotKeyID
    var onFire: (() -> Void)?

    /// `slot` distinguishes multiple hot keys in the same app (1 = read aloud,
    /// 2 = dictation). Same 'PRLY' signature, different id.
    init(slot: UInt32 = 1) {
        id = EventHotKeyID(signature: OSType(0x50524C59), id: slot)
        installHandler()
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ combo: HotKeyCombo) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &newRef)
        if status == noErr { ref = newRef }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            if hkID.id == mgr.id.id {
                DispatchQueue.main.async { mgr.onFire?() }
            }
            return noErr
        }, 1, &spec, ptr, &handler)
    }
}

/// Human-readable rendering of a combo, e.g. "⌘⇧R".
enum KeyName {
    static func describe(_ c: HotKeyCombo) -> String {
        var s = ""
        let m = Int(c.modifiers)
        if m & controlKey != 0 { s += "⌃" }
        if m & optionKey != 0 { s += "⌥" }
        if m & shiftKey != 0 { s += "⇧" }
        if m & cmdKey != 0 { s += "⌘" }
        s += keyLabel(c.keyCode)
        return s
    }

    static func keyLabel(_ code: UInt32) -> String {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        ]
        return map[Int(code)] ?? "Key\(code)"
    }

    /// Convert AppKit modifier flags to a Carbon mask.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        return UInt32(m)
    }
}
