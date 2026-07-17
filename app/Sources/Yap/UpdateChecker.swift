import Foundation

/// Checks GitHub for a newer Yap release.
///
/// This is the ONLY network call Yap makes beyond the one-time model download:
/// a single unauthenticated GET to the public GitHub releases API. It sends no
/// payload and no identifiers — just "what's the latest release?" — and returns
/// nothing personal. Auto-check is a user preference (default on, toggle in
/// Settings ▸ General) and throttled to once per day; a manual "Check now"
/// bypasses the throttle. Disclosed in docs/PRIVACY.md. Turn the pref off for
/// zero outbound connections.
enum UpdateChecker {
    struct Release: Equatable {
        let version: String   // normalized, e.g. "0.8.2"
        let url: URL          // the release page (html_url)
    }

    /// The running app's version (CFBundleShortVersionString), e.g. "0.8.1".
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: Version comparison (pure, unit-tested in --selftest)

    /// True when `candidate` is a strictly newer version than `base`. Tolerates a
    /// leading "v", differing component counts ("1.2" == "1.2.0"), and pre-release
    /// suffixes ("1.2.3-beta" compares as 1.2.3, i.e. NOT newer than 1.2.3).
    static func isNewer(_ candidate: String, than base: String) -> Bool {
        compare(candidate, base) == .orderedDescending
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = components(a), pb = components(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Normalize a tag ("v0.8.2" → "0.8.2"); strips a single leading v/V.
    static func normalized(_ tag: String) -> String {
        (tag.hasPrefix("v") || tag.hasPrefix("V")) ? String(tag.dropFirst()) : tag
    }

    /// Dotted numeric components, stopping at the first non-[0-9.] run so a
    /// pre-release suffix ("1.2.3-beta") reduces to its numeric core [1,2,3].
    private static func components(_ s: String) -> [Int] {
        let t = normalized(s)
        let core = t.prefix { "0123456789.".contains($0) }
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    // MARK: Network

    /// GET the latest release from GitHub and return it only if it's newer than
    /// the running build. Returns nil on ANY failure (offline, rate-limited,
    /// malformed) — an update check must never nag, block, or surface an error.
    static func latestIfNewer(owner: String = "latent-variable",
                              repo: String = "Yap") async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Yap/\(currentVersion)", forHTTPHeaderField: "User-Agent")  // GitHub requires a UA
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let version = normalized(tag)
        guard isNewer(version, than: currentVersion) else { return nil }
        let page = (json["html_url"] as? String).flatMap { URL(string: $0) }
            ?? URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
        return Release(version: version, url: page)
    }
}
