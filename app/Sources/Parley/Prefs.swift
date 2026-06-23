import Foundation
import Carbon.HIToolbox

/// Capture strategy preference.
enum CaptureMode: String, CaseIterable, Identifiable {
    case auto, accessibility, clipboard
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (AX, fallback clipboard)"
        case .accessibility: return "Accessibility only"
        case .clipboard: return "Clipboard only"
        }
    }
}

/// What the read action targets.
enum ReadSource: String, CaseIterable, Identifiable {
    case selection, clipboard
    var id: String { rawValue }
    var label: String { self == .selection ? "Selected text" : "Clipboard" }
}

/// Preprocessing profile presets.
enum Profile: String, CaseIterable, Identifiable, Codable {
    case general, markdown, code, blog, llm
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "General"
        case .markdown: return "Markdown"
        case .code: return "Code / Terminal"
        case .blog: return "Blog / Article"
        case .llm: return "LLM Output"
        }
    }
}

/// A persisted hot-key combo (Carbon key code + modifier flags).
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask

    static let defaultCombo = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(cmdKey | shiftKey)
    )
}

/// App-wide preferences, UserDefaults backed, observable for SwiftUI.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var engine: String { didSet { d.set(engine, forKey: "engine") } }   // "kokoro" | "chatterbox"
    @Published var voice: String { didSet { d.set(voice, forKey: "voice") } }
    @Published var hdVoice: String { didSet { d.set(hdVoice, forKey: "hdVoice") } } // chatterbox reference id
    @Published var speed: Double { didSet { d.set(speed, forKey: "speed") } }
    @Published var pitch: Double { didSet { d.set(pitch, forKey: "pitch") } }    // cents
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume") } }
    @Published var pauseScale: Double { didSet { d.set(pauseScale, forKey: "pauseScale") } }  // pause length multiplier
    @Published var profile: Profile { didSet { d.set(profile.rawValue, forKey: "profile") } }
    @Published var captureMode: CaptureMode { didSet { d.set(captureMode.rawValue, forKey: "captureMode") } }
    @Published var readSource: ReadSource { didSet { d.set(readSource.rawValue, forKey: "readSource") } }
    @Published var stopOnNewTrigger: Bool { didSet { d.set(stopOnNewTrigger, forKey: "stopOnNewTrigger") } }
    @Published var keepWarm: Bool { didSet { d.set(keepWarm, forKey: "keepWarm") } }
    // Pre-load the HD model at launch so the first HD read isn't a cold ~10s
    // wait. Only acts when the HD engine is installed (so it's a no-op — "off" —
    // for the default Kokoro-only setup).
    @Published var autoLoadHD: Bool { didSet { d.set(autoLoadHD, forKey: "autoLoadHD") } }
    @Published var providerMode: String { didSet { d.set(providerMode, forKey: "providerMode") } }  // auto|cpu|coreml
    @Published var showMiniPlayer: Bool { didSet { d.set(showMiniPlayer, forKey: "showMiniPlayer") } }
    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }
    @Published var customRules: [CleanRule] { didSet { saveRules() } }
    @Published var hotKey: HotKeyCombo { didSet { saveHotKey() } }

    private init() {
        engine = d.string(forKey: "engine") ?? "kokoro"
        voice = d.string(forKey: "voice") ?? "am_puck"
        hdVoice = d.string(forKey: "hdVoice") ?? ""
        speed = d.object(forKey: "speed") as? Double ?? 1.0
        pitch = d.object(forKey: "pitch") as? Double ?? 0.0
        volume = d.object(forKey: "volume") as? Double ?? 1.0
        pauseScale = d.object(forKey: "pauseScale") as? Double ?? 1.0
        profile = Profile(rawValue: d.string(forKey: "profile") ?? "") ?? .general
        captureMode = CaptureMode(rawValue: d.string(forKey: "captureMode") ?? "") ?? .clipboard
        readSource = ReadSource(rawValue: d.string(forKey: "readSource") ?? "") ?? .selection
        stopOnNewTrigger = d.object(forKey: "stopOnNewTrigger") as? Bool ?? true
        keepWarm = d.object(forKey: "keepWarm") as? Bool ?? true
        autoLoadHD = d.object(forKey: "autoLoadHD") as? Bool ?? true
        providerMode = d.string(forKey: "providerMode") ?? "auto"
        showMiniPlayer = d.object(forKey: "showMiniPlayer") as? Bool ?? true
        launchAtLogin = d.object(forKey: "launchAtLogin") as? Bool ?? false
        if let data = d.data(forKey: "customRules"),
           let r = try? JSONDecoder().decode([CleanRule].self, from: data) {
            customRules = r
        } else {
            customRules = []
        }
        if let data = d.data(forKey: "hotKey"),
           let h = try? JSONDecoder().decode(HotKeyCombo.self, from: data) {
            hotKey = h
        } else {
            hotKey = .defaultCombo
        }
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(customRules) { d.set(data, forKey: "customRules") }
    }
    private func saveHotKey() {
        if let data = try? JSONEncoder().encode(hotKey) { d.set(data, forKey: "hotKey") }
    }
}
