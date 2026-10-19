import Foundation

/// `CFFIXED_USER_HOME=<empty dir> Yap --firstrun [port]`: a fresh install, end to
/// end. Launch must start the Kokoro download by itself, the files must arrive and
/// pass their pinned hashes, and the backend must reload them so the voice list is
/// no longer empty. Pocket installed must start nothing.
///
/// Downloads ~340 MB for real. Runs its own sidecar on a spare port, and refuses
/// to run unless Application Support resolves inside the fake home, so it never
/// touches the installed app's models.
enum FirstRunProbe {
    static func run(port: Int) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in exit(await Runner(port: port).run()) }
        dispatchMain()
    }

    @MainActor
    final class Runner {
        let port: Int
        var failures = 0
        init(port: Int) { self.port = port }

        func ok(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            if cond { print("  ✓ \(name)") }
            else { failures += 1; print("  ✗ \(name) \(detail())") }
        }

        func until(_ seconds: Double, every tick: Double = 0.1, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if cond() { return true }
                try? await Task.sleep(for: .seconds(tick))
            }
            return cond()
        }

        func run() async -> Int32 {
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty,
                  support.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: home).standardizedFileURL.path + "/")
            else {
                print("refusing: set CFFIXED_USER_HOME to an empty directory (Application Support is \(support.path))")
                return 2
            }
            let yap = support.appending(path: "Yap")
            // The real home passes the prefix check above, so name it outright.
            if let pw = getpwuid(getuid()), let real = String(validatingCString: pw.pointee.pw_dir),
               URL(fileURLWithPath: real).standardizedFileURL.path == URL(fileURLWithPath: home).standardizedFileURL.path {
                print("refusing: CFFIXED_USER_HOME is your real home; use an empty directory")
                return 2
            }
            // The Pocket case below creates and then trashes hd-packages, so it must
            // be the probe's own: never one that was already there.
            guard !fm.fileExists(atPath: yap.appending(path: "hd-packages").path) else {
                print("refusing: \(yap.path) already has a Pocket install, so this is not a first run")
                return 2
            }
            print("First-run probe: home \(home), own sidecar on :\(port)")

            AppState.probeBackendPort = port
            // Writes no prefs: CFFIXED_USER_HOME moves Application Support but not
            // the defaults domain, so from the signed bundle a write would land in
            // the user's real settings. One fail cue may play.
            guard Prefs.shared.voiceEnabled else {
                print("refusing: Reading aloud is off, and launch only fetches a voice when it is on")
                return 2
            }
            let state = AppState.shared
            guard !state.backend.kokoroFilesOnDisk else {
                print("refusing: Kokoro is already in \(yap.path), so this is not a first run")
                return 2
            }

            print("Pocket installed, Kokoro missing: nothing downloads")
            let hd = yap.appending(path: "hd-packages")
            try? fm.createDirectory(at: hd.appending(path: "torch"), withIntermediateDirectories: true)
            ok("Pocket reads as installed", state.backend.hdInstalledOnDisk)
            ok("no download is reported", !state.downloadVoiceIfMissing("probe"))
            try? await Task.sleep(for: .milliseconds(300))
            ok("no download started", !state.downloader.downloading)
            if hd.path.hasPrefix(yap.path + "/") { try? fm.trashItem(at: hd, resultingItemURL: nil) }

            print("Nothing installed: launch fetches Kokoro and loads it")
            ok("no voice on disk before launch",
               !state.backend.kokoroFilesOnDisk && !state.backend.hdInstalledOnDisk)
            await state.startVoice()
            ok("launch started the download", await until(3) { state.kokoroDownloading })
            ok("voice list empty before the download", state.voices.isEmpty)
            guard state.kokoroDownloading else {
                await state.backend.stopAndWait()
                print("\n\(failures) FAILURE(S)")
                return 1
            }

            // The shortcut mid-download: refused before capture, so no ⌘C is sent.
            state.triggerRead()
            let refused = await until(3) {
                if case .error(let m) = state.status { return m.contains("still downloading") }
                return false
            }
            ok("a read during the download says it is still downloading", refused, "(status \(state.status))")
            ok("that read captured nothing", state.lastCaptured.isEmpty)

            var lastReport = Date()
            let finished = await until(1200, every: 0.5) {
                if Date().timeIntervalSince(lastReport) > 15 {
                    lastReport = Date()
                    print("    … \(Int(state.downloader.progress * 100))% \(state.downloader.statusText)")
                }
                return state.downloader.error != nil || state.downloader.done
            }
            ok("download finished without an error", finished && state.downloader.error == nil,
               "(\(state.downloader.error ?? "timed out"))")
            ok("both files on disk, hashes verified", state.backend.kokoroFilesOnDisk && state.downloader.done)
            // The reload is a backend restart plus a model load: seconds, not minutes.
            // A backend that cannot load the model must fail here, not hang the probe.
            let loaded = await until(120, every: 0.5) { state.modelsPresent && !state.voices.isEmpty }
            ok("reload finished", loaded, "(backend: \(state.backend.lastError ?? "no error reported"))")
            ok("backend reloaded and reports the files", state.backend.kokoroFilesPresent)
            ok("voice list filled without a relaunch", !state.voices.isEmpty, "(\(state.voices.count) voices)")
            ok("download no longer shown in the menu", !state.kokoroDownloading)

            await state.backend.stopAndWait()
            print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
            return failures == 0 ? 0 : 1
        }
    }
}
