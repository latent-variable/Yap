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

    /// Merge `Parley/` into `Yap/`. Merge-style (not a bare move) so that if a path
    /// getter already created an empty `Yap/`, each child still moves over when it
    /// isn't already present. Idempotent; a no-op once the old directory is gone.
    private static func migrateAppSupport() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appending(path: "Parley")
        let new = base.appending(path: "Yap")
        guard fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        if let kids = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            for kid in kids {
                let dest = new.appending(path: kid.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: kid, to: dest)
                }
            }
        }
        if let remaining = try? fm.contentsOfDirectory(atPath: old.path), remaining.isEmpty {
            try? fm.removeItem(at: old)
        }
    }
}
