import Foundation

/// One-time migration of pre-rename state. Parley became Yap, which changed two
/// things macOS keys by identity:
///   • the app-support directory (`…/Parley` → `…/Yap`) — models, venv, logs, and
///     the user's cloned `hd-voices`;
///   • the UserDefaults domain (bundle id `dev.latentvariable.parley` → `.yap`) —
///     every setting: engine, selected voice, speed, hotkeys, dictation prefs.
/// Without this, a rename would silently reset both. Runs before any setting is
/// read or any path getter creates a fresh empty directory.
enum AppMigration {
    private static let oldBundleID = "dev.latentvariable.parley"
    private static let migratedKey = "didMigrateFromParley"

    static func runOnce() {
        migrateDefaults()
        migrateAppSupport()
    }

    /// Copy the old bundle-id's settings into the new domain, exactly once. A flag
    /// (not a per-key nil check) gates it: the first Yap launch already wrote some
    /// *default* values into the new domain (e.g. a fallback HD voice), so a nil
    /// check would keep those wrong defaults. Overwriting once restores the user's
    /// real choices; the flag then makes every later change stick.
    private static func migrateDefaults() {
        let std = UserDefaults.standard
        guard !std.bool(forKey: migratedKey) else { return }
        if let old = std.persistentDomain(forName: oldBundleID) {
            for (key, value) in old { std.set(value, forKey: key) }
        }
        std.set(true, forKey: migratedKey)
    }

    /// Merge `Parley/` into `Yap/`. A shallow per-child check is unsafe: if a path
    /// getter (or a partial earlier run) already created an empty `Yap/hd-voices`
    /// or `Yap/models`, skipping that child whole would strand the user's cloned
    /// voices or models. So merge recursively — see `merge`.
    private static func migrateAppSupport() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = base.appending(path: "Parley")
        guard fm.fileExists(atPath: old.path) else { return }
        merge(old, into: base.appending(path: "Yap"), fm: fm)
    }

    /// Recursively move `src` into `dst`. When `dst` doesn't exist, the whole item
    /// (file or directory subtree) moves in one step. When `dst` is an existing
    /// directory, contents merge child-by-child, so a pre-existing (even empty)
    /// destination subdir never causes the source's contents to be skipped. Files
    /// already present at `dst` are kept (never overwritten); a source directory
    /// emptied by the merge is then removed (tolerating a stray `.DS_Store`).
    /// Internal (not private) so `--selftest` can exercise the no-data-loss path.
    static func merge(_ src: URL, into dst: URL, fm: FileManager) {
        var srcIsDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &srcIsDir) else { return }
        if !fm.fileExists(atPath: dst.path) {
            // Fast path: nothing to merge into. Log (to stderr, not the file logger,
            // to avoid re-creating the dir we're migrating) so a failure is
            // diagnosable instead of silently swallowed — the source is left intact.
            do { try fm.moveItem(at: src, to: dst) }
            catch { FileHandle.standardError.write(Data("Yap migration: move \(src.lastPathComponent) failed: \(error)\n".utf8)) }
            return
        }
        guard srcIsDir.boolValue else { return }  // a file already exists at dst — keep it
        for kid in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
            merge(kid, into: dst.appending(path: kid.lastPathComponent), fm: fm)
        }
        // Drop the now-empty source dir; a Finder-dropped .DS_Store doesn't count.
        if let remaining = try? fm.contentsOfDirectory(atPath: src.path),
           remaining.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: src)
        }
    }
}
