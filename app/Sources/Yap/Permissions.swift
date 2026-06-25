import AppKit
import ApplicationServices

/// Accessibility permission helpers.
enum Permissions {
    /// Is the app trusted for the Accessibility API?
    static var axTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user (system dialog) to grant Accessibility access.
    static func requestAX() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    static func openAXSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
