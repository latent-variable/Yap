import Foundation
import AppKit

/// Spawns and supervises the local Python Kokoro backend.
@MainActor
final class BackendManager: ObservableObject {
    @Published var ready = false
    /// True only when THIS app spawned the backend process (vs reusing an
    /// already-running one). Model deletion is unsafe against a backend we don't
    /// own — restart() can't replace it, so it would keep serving deleted files.
    @Published private(set) var ownsProcess = false
    @Published var lastError: String?

    private var process: Process?
    let client = BackendClient()
    let port = 8765

    var modelsDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Parley/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Locate the repo (containing scripts/run_backend.sh). Checks the app
    /// bundle, an env override, then walks up from the executable.
    func repoRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["PARLEY_REPO"] {
            return URL(fileURLWithPath: env)
        }
        // Bundled inside the app: Contents/Resources/repo
        if let res = Bundle.main.resourceURL {
            let bundled = res.appending(path: "repo")
            if FileManager.default.fileExists(atPath: bundled.appending(path: "scripts/run_backend.sh").path) {
                return bundled
            }
        }
        // Walk up from the executable looking for the script.
        var dir = Bundle.main.bundleURL
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appending(path: "scripts/run_backend.sh").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// App-support base, WITHOUT the directory-creating side effect of `modelsDir`
    /// (which would re-create an empty models dir just from an existence check).
    private var appSupportParley: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Parley")
    }
    /// HD engine installed on disk (torch present in hd-packages). The backend
    /// can serve HD even when the Kokoro model files are absent — a cheap check
    /// so `ready` doesn't depend solely on Kokoro.
    var hdInstalledOnDisk: Bool {
        let hd = appSupportParley.appending(path: "hd-packages")
        return FileManager.default.fileExists(atPath: hd.appending(path: "torch").path)
    }
    /// Whether the Kokoro model files are present (from the last /health). Distinct
    /// from `ready`: the backend can be ready (HD) with Kokoro deleted.
    @Published private(set) var kokoroFilesPresent = false

    /// Apply a /health response to published state. `ready` means the backend can
    /// serve *some* engine — Kokoro loaded OR HD installed — so deleting one model
    /// doesn't make the backend look dead.
    private func apply(_ h: HealthInfo) {
        kokoroFilesPresent = h.files_present
        ready = h.model_loaded || hdInstalledOnDisk
        lastError = (h.files_present || hdInstalledOnDisk) ? nil : "Model files not installed."
    }

    /// Ensure the backend is up: reuse a running one, else launch it.
    func start() async {
        if let h = await client.health() {
            apply(h)
            if ready { return }
            // Responsive but nothing installable (no Kokoro files, no HD) — don't
            // launch/spin waiting for a model that was deleted.
            if !h.files_present && !hdInstalledOnDisk { return }
        }
        await launchProcess()
        await waitForHealth()
    }

    /// Path to a bundled, self-contained Python runtime, if present.
    private var bundledPython: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let py = res.appending(path: "python/bin/python3")
        return FileManager.default.isExecutableFile(atPath: py.path) ? py : nil
    }

    /// Strip the download-quarantine flag from our own bundle so the nested
    /// Python binaries can be spawned. Safe no-op if not quarantined.
    private func stripQuarantine() async {
        let bundle = Bundle.main.bundleURL.path
        guard bundle.hasSuffix(".app") else { return }
        // xattr -dr walks the whole bundle (thousands of files) — run it off the
        // main actor so app launch stays responsive.
        await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            p.arguments = ["-dr", "com.apple.quarantine", bundle]
            try? p.run(); p.waitUntilExit()
        }.value
    }

    private func launchProcess() async {
        guard process == nil else { return }
        if bundledPython != nil { await stripQuarantine() }
        let p = Process()
        var env = ProcessInfo.processInfo.environment
        env["PARLEY_MODELS_DIR"] = modelsDir.path
        env["PARLEY_PORT"] = String(port)
        env["PARLEY_PROVIDER"] = Prefs.shared.providerMode
        // If the HD engine is installed, run in the combined env (numpy 1.26 +
        // torch + kokoro) so one process serves both engines. hd-packages must
        // be FIRST on PYTHONPATH so its numpy<2 imports before the bundled 2.x.
        let hd = modelsDir.deletingLastPathComponent().appending(path: "hd-packages")
        let hdPresent = FileManager.default.fileExists(atPath: hd.appending(path: "torch").path)

        if let py = bundledPython, let root = repoRoot() {
            // Preferred: run the bundled runtime directly — no system Python.
            let server = root.appending(path: "backend/server.py")
            p.executableURL = py
            p.arguments = [server.path, "--port", String(port),
                           "--models-dir", modelsDir.path, "--provider", Prefs.shared.providerMode]
            // Drop inherited vars that would pull in the user's Python so the
            // relocatable runtime self-locates — THEN set PYTHONPATH to just
            // hd-packages (when present). Order matters: a prior bug cleared this
            // key AFTER setting it, so the HD engine loaded the bundled numpy 2.x
            // and torch/chatterbox failed on the version mismatch.
            env.removeValue(forKey: "PYTHONHOME")
            env.removeValue(forKey: "PYTHONSTARTUP")
            env["PYTHONNOUSERSITE"] = "1"   // ignore ~/.local site-packages
            if hdPresent {
                env["PYTHONPATH"] = hd.path
            } else {
                env.removeValue(forKey: "PYTHONPATH")
            }
        } else if let root = repoRoot() {
            // Dev fallback: build a venv via the shell launcher.
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [root.appending(path: "scripts/run_backend.sh").path]
            if hdPresent {
                // Append the existing PYTHONPATH only if it's non-empty — a bare
                // ":" would add an empty entry (== cwd) to sys.path.
                if let existing = env["PYTHONPATH"], !existing.isEmpty {
                    env["PYTHONPATH"] = hd.path + ":" + existing
                } else {
                    env["PYTHONPATH"] = hd.path
                }
            }
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin"
        } else {
            lastError = "Backend not found (no bundled runtime or dev scripts)."
            return
        }
        p.environment = env

        let logURL = FileManager.default.temporaryDirectory.appending(path: "parley_backend.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let fh = try? FileHandle(forWritingTo: logURL)
        if let fh {
            p.standardOutput = fh
            p.standardError = fh
        }
        do { try p.run(); process = p; ownsProcess = true }
        catch { lastError = "Failed to launch backend: \(error.localizedDescription)" }
        // The child dup'd the log fd at run(); close the parent's copy so we
        // don't leak a descriptor on every launch.
        try? fh?.close()
    }

    private func waitForHealth() async {
        for _ in 0..<120 { // up to ~60s (covers first-run install/model load)
            // If we own the process and it has already exited, it crashed on
            // startup — fail fast instead of polling /health for 60s.
            if let p = process, !p.isRunning {
                if lastError == nil { lastError = "Backend exited unexpectedly." }
                return
            }
            if let h = await client.health() {
                apply(h)
                if ready { return }
                // Responsive but no model will ever load (Kokoro deleted, no HD) —
                // stop waiting instead of hanging the full 60s.
                if !h.files_present && !hdInstalledOnDisk { return }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !ready && lastError == nil { lastError = "Backend did not become ready in time." }
    }

    func stop() {
        process?.terminate()
        process = nil
        ownsProcess = false
    }

    /// Terminate the backend process and WAIT for it to exit, so its file handles
    /// are released before a caller deletes model files. (stop() returns before
    /// the process has actually exited — a fixed sleep would race the unlink.)
    func stopAndWait() async {
        guard let p = process else { ownsProcess = false; return }
        p.terminate()
        // Wait up to ~5s for exit; never hang the UI if the process ignores
        // SIGTERM (the unlink that follows works on still-open files anyway).
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline {
            // do/catch (not try?) so cancellation breaks instead of busy-spinning:
            // try? would swallow CancellationError and burn CPU until the deadline.
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { break }
        }
        process = nil
        ownsProcess = false
    }

    /// Restart the backend (e.g. after installing HD deps, to load the new env).
    func restart() async {
        stop()
        ready = false
        try? await Task.sleep(nanoseconds: 500_000_000)
        await start()
    }
}
