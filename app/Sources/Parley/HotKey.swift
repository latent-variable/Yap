import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hot key via the Carbon hot-key API
/// (still the most reliable route for a global shortcut on macOS).
final class HotKeyManager {
    private var ref: EventHotKeyRef?
    private let id: EventHotKeyID
    var onFire: (() -> Void)?

    // Modifier-only chord state (e.g. ⌥⌘ with no letter — "Alt+Win" on a PC
    // keyboard). Carbon's RegisterEventHotKey CANNOT bind a pure modifier combo,
    // so those route through a shared flagsChanged monitor instead.
    private var chordModifiers: UInt32 = 0   // non-zero => this manager is a modifier-only chord
    private var armed = true                  // rising-edge debounce so a held chord fires once

    // One process-wide Carbon handler dispatches EVERY hot key to the right
    // manager by id. Per-instance handlers are broken: each handler must return a
    // status, and a non-matching handler returning noErr *consumes* the event so
    // the matching handler never runs. With two hot keys (read + dictation) the
    // last-installed handler ate every event — the read shortcut silently died.
    // A single handler keyed by id has no ordering hazard.
    // Weak so registering in the static map doesn't keep the manager alive
    // forever — otherwise deinit (which unregisters the system hot key) never runs.
    private struct WeakManager { weak var value: HotKeyManager? }
    private static var managers: [UInt32: WeakManager] = [:]
    private static var sharedHandler: EventHandlerRef?
    private static let lock = NSLock()

    /// `slot` distinguishes multiple hot keys in the same app (1 = read aloud,
    /// 2 = dictation). Same 'PRLY' signature, different id.
    init(slot: UInt32 = 1) {
        id = EventHotKeyID(signature: OSType(0x50524C59), id: slot)
        Self.lock.lock(); Self.managers[slot] = WeakManager(value: self); Self.lock.unlock()
        Self.installSharedHandlerOnce()
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.lock.lock(); Self.managers[id.id] = nil; Self.lock.unlock()
    }

    /// Returns false if the OS rejected the registration (e.g. the chord is
    /// already taken) — the hot key is then inactive.
    @discardableResult
    func register(_ combo: HotKeyCombo) -> Bool {
        // Tear down whichever path was active before re-binding.
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        // chordModifiers/armed are read by the shared handleFlags; mutate them
        // under the same lock so register (UI thread) and the monitor never race.
        Self.lock.lock(); chordModifiers = 0; armed = true; Self.lock.unlock()

        // Modifier-only chord: no base key, two or more modifiers held together.
        // (One modifier alone would fire on every routine ⌘/⌥ press — disallow.)
        if combo.isModifierOnly {
            Self.lock.lock(); chordModifiers = combo.modifiers; armed = true; Self.lock.unlock()
            Self.installChordMonitorOnce()
            return true
        }

        // keyCode 0 is the physical 'A' key (kVK_ANSI_A). An unset/invalid combo
        // (no base key, fewer than 2 modifiers) must NOT reach Carbon, or it would
        // silently register 'A' — or bare 'A' — and hijack that key globally.
        guard combo.keyCode != 0 else { return false }

        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &newRef)
        if status == noErr { ref = newRef; return true }
        return false
    }

    // MARK: Modifier-only chords (flagsChanged monitor)

    private static var chordMonitorGlobal: Any?
    private static var chordMonitorLocal: Any?

    /// Install the process-wide modifier monitor once. Global catches the chord
    /// while other apps are focused (needs Accessibility, which Parley has);
    /// local catches it while a Parley window is key.
    private static func installChordMonitorOnce() {
        lock.lock(); defer { lock.unlock() }
        guard chordMonitorGlobal == nil else { return }
        chordMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { ev in
            Self.handleFlags(ev)
        }
        chordMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { ev in
            Self.handleFlags(ev); return ev   // don't consume — modifiers stay live for the OS
        }
    }

    /// On every modifier change, fire any chord manager whose exact modifier set
    /// just became active (rising edge), and re-arm one whose chord was released.
    /// NSEvent monitors deliver on the main thread, but we read/write the per-
    /// manager chord state under `lock` anyway so this is race-free regardless of
    /// the delivery thread; the matched `onFire`s run on main, outside the lock.
    private static func handleFlags(_ ev: NSEvent) {
        let current = KeyName.carbonModifiers(ev.modifierFlags)
        var toFire: [() -> Void] = []
        lock.lock()
        for wm in managers.values {
            guard let mgr = wm.value, mgr.chordModifiers != 0 else { continue }
            if current == mgr.chordModifiers {
                if mgr.armed { mgr.armed = false; if let f = mgr.onFire { toFire.append(f) } }
            } else {
                mgr.armed = true
            }
        }
        lock.unlock()
        for f in toFire { DispatchQueue.main.async { f() } }
    }

    private static func installSharedHandlerOnce() {
        lock.lock(); defer { lock.unlock() }
        guard sharedHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            // Only handle our own ('PRLY') hot keys — another component could use
            // the same numeric id under a different signature.
            guard hkID.signature == OSType(0x50524C59) else { return OSStatus(eventNotHandledErr) }
            HotKeyManager.lock.lock()
            let mgr = HotKeyManager.managers[hkID.id]?.value
            HotKeyManager.lock.unlock()
            guard let mgr else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { mgr.onFire?() }
            return noErr
        }, 1, &spec, nil, &sharedHandler)
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
        // keyCode 0 = a modifier-only chord (no base key); show just the glyphs.
        if c.keyCode != 0 { s += keyLabel(c.keyCode) }
        return s.isEmpty ? "Unset" : s
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
