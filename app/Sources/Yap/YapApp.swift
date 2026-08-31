import SwiftUI

/// Real entry point.
///
/// The probes that park the main thread on `dispatchMain()` (`--pipetest`,
/// `--backpressure`) must run BEFORE SwiftUI installs its scene. Run from
/// `applicationDidFinishLaunching` they abort with
/// `NSViewIsCurrentlyBuildingLayerTreeForDisplay != currentlyBuildingLayerTree`
/// (SIGTRAP): the MenuBarExtra's layer tree is mid-build, and parking main
/// re-enters AppKit while it is. The flags that just print and `exit(0)` are
/// unaffected and stay in the delegate.
@main
enum YapMain {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--pipetest") {
            let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
            let prof = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : nil
            CLITest.run(path: path, profileName: prof)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--backpressure") {
            let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
            let secs = CommandLine.arguments.count > i + 2 ? Double(CommandLine.arguments[i + 2]) : nil
            CLITest.runBackpressure(path: path, seconds: secs ?? 25)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--tailtest") {
            let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
            let cap = CommandLine.arguments.count > i + 2 ? Int(CommandLine.arguments[i + 2]) : nil
            let port = CommandLine.arguments.count > i + 3 ? Int(CommandLine.arguments[i + 3]) : nil
            CLITest.runTailTest(path: path, maxChars: cap ?? 3000, port: port ?? 8766)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--providertest") {
            let port = CommandLine.arguments.count > i + 1 ? Int(CommandLine.arguments[i + 1]) : nil
            CLITest.runProviderRestart(port: port ?? 8767,
                                       legacy: CommandLine.arguments.contains("--legacy"))
        }
        YapApp.main()
    }
}

struct YapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
                .environmentObject(prefs)
        } label: {
            Image(systemName: state.status.symbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(prefs)
                .frame(width: 560, height: 460)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") { Selftest.run() }
        // Cross-language check for the backend /verify HMAC. Prints the proof
        // BackendAuth computes for a nonce (using the real 0600 token file) so a
        // test can confirm it matches the Python backend byte-for-byte.
        if let i = CommandLine.arguments.firstIndex(of: "--authproof"),
           CommandLine.arguments.count > i + 1 {
            print(BackendAuth.proof(nonce: CommandLine.arguments[i + 1]) ?? "NO_TOKEN")
            exit(0)
        }
        if CommandLine.arguments.contains("--diag") {
            print("Yap capture diagnostics\n")
            print(TextCapture.diagnose())
            print("Log file: \(Log.url.path)")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--audiotest"),
           CommandLine.arguments.count > i + 1 {
            let src = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let dest = FileManager.default.temporaryDirectory.appending(path: "yap_audiotest.wav")
            do {
                try AudioImport.toReferenceWAV(src: src, dest: dest)
                let sz = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]) as? Int ?? 0
                print("AudioImport OK -> \(dest.path) (\(sz) bytes)")
            } catch {
                print("AudioImport FAILED: \(error)")
            }
            exit(0)
        }
        // --pipetest / --backpressure are handled in YapMain, before SwiftUI
        // builds its scene (see the note there).
        NSApp.setActivationPolicy(.accessory) // menu-bar only
        // Register the "Read with Yap" Services-menu provider (see NSServices
        // in Info.plist). Strong ref kept so it isn't deallocated.
        NSApp.servicesProvider = serviceProvider
        AppState.shared.bootstrap()
        DictationController.shared.bootstrap()   // the "ears": ⌘⇧D dictation
    }
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.backend.stop()
    }

    private let serviceProvider = ServiceProvider()
}

/// Backs the macOS Services menu item. The system calls `readWithYap:…` with
/// the selected text on a pasteboard; we hand it to AppState to speak.
@MainActor
final class ServiceProvider: NSObject {
    // Services always dispatch on the main thread, so @MainActor on the class
    // lets us call AppState directly. The error pointer is optional — Cocoa may
    // pass nil when the caller doesn't want error details, so never
    // force-dereference it.
    @objc func readWithYap(_ pboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = "No text to read." as NSString
            return
        }
        AppState.shared.readAloud(text)
    }
}
