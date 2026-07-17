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
        let (na, preA) = split(a)
        let (nb, preB) = split(b)
        for i in 0..<max(na.count, nb.count) {
            let x = i < na.count ? na[i] : 0
            let y = i < nb.count ? nb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        // Numeric cores equal. A pre-release ("0.8.1-beta") is OLDER than the same
        // final release ("0.8.1"), so someone on a beta IS still told about the
        // stable build of that version. Two pre-releases of the same core count as
        // equal — we don't parse beta.1 vs beta.2, and Yap doesn't ship them.
        if preA == preB { return .orderedSame }
        return preA ? .orderedAscending : .orderedDescending
    }

    /// Normalize a tag ("v0.8.2" → "0.8.2"); strips a single leading v/V.
    static func normalized(_ tag: String) -> String {
        (tag.hasPrefix("v") || tag.hasPrefix("V")) ? String(tag.dropFirst()) : tag
    }

    /// Numeric components + whether a pre-release suffix followed them. Stops at
    /// the first non-[0-9.] char: "1.2.3-beta" → ([1,2,3], true), "1.2" → ([1,2], false).
    private static func split(_ s: String) -> ([Int], Bool) {
        let t = normalized(s)
        let core = t.prefix { "0123456789.".contains($0) }
        let nums = core.split(separator: ".").map { Int($0) ?? 0 }
        return (nums, core.count < t.count)
    }

    // MARK: Network

    /// The result of a check. Distinguishing `.failed` from `.upToDate` is load-
    /// bearing: both used to collapse to nil, which let a failed check (a) poison
    /// the once/day throttle so it wouldn't retry, and (b) make the UI claim "up
    /// to date" when it was really just offline. The caller keys on these cases.
    enum Outcome: Equatable {
        case update(Release)   // a strictly newer release exists
        case upToDate          // checked OK; running the latest (or newer)
        case failed            // offline, rate-limited, or malformed — inconclusive
    }

    /// GET the latest release from GitHub. Returns `.failed` on ANY error so a
    /// check never nags, blocks, or throws — but the caller can still tell failure
    /// from success and avoid a false "up to date" / a poisoned throttle.
    static func check(owner: String = "latent-variable",
                      repo: String = "Yap") async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
        else { return .failed }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Yap/\(currentVersion)", forHTTPHeaderField: "User-Agent")  // GitHub requires a UA
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return .failed }
        let version = normalized(tag)
        guard isNewer(version, than: currentVersion) else { return .upToDate }
        let page = (json["html_url"] as? String).flatMap { URL(string: $0) }
            ?? URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
        return .update(Release(version: version, url: page))
    }
}
