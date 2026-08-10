//  PeerDaemonVersion: compares a peer host's installed term-meshd
//  version against the project's latest GitHub release, so the relay
//  "Test" flow (PeerHostDoctor) can offer an update when the remote
//  binary is stale.
//
//  Two independent pieces, kept separate on purpose: fetchLatestRelease
//  does the network call (unauthenticated GitHub REST, same pattern as
//  BrewReleaseNotesService.fetch), while parseComponents/compare are
//  pure semver math — unit-testable without any network access.

import Foundation

enum PeerDaemonVersion {
    /// Repo whose releases are the source of truth for the latest
    /// term-meshd build (matches BrewReleaseNotesService.defaultRepo).
    static let defaultRepo = "x-mesh/term-mesh"

    /// Result of comparing an installed version string against the
    /// latest known release.
    ///
    /// UI contract (t3): `.outdated` and `.legacy` both name `latest`
    /// as the update target, but the two must NOT render with the same
    /// copy. `.outdated` is a precise "you're behind" claim ("update to
    /// vX.Y.Z"); `.legacy` is not a comparison at all — show it as
    /// "legacy daemon — update recommended (version reporting predates
    /// v\(versionSyncFloor))" instead of implying any ordering was computed.
    enum Comparison: Equatable {
        case upToDate
        case outdated(latest: String)
        /// `installed` parses as semver but is below `versionSyncFloor`
        /// — see that constant's doc for why ordering it against
        /// `latest` would misreport a pre-sync daemon as outdated (or,
        /// worse, as up to date) essentially at random.
        case legacy(latest: String)
        /// Either side failed to parse as semver — no claim is made,
        /// the caller must not offer an update on this result.
        case unknown
    }

    /// First app release where `scripts/bump-version.sh` syncs the
    /// daemon's own Cargo package version with the app's
    /// MARKETING_VERSION (see that script's daemon Cargo.toml/Cargo.lock
    /// rewrite, introduced alongside `daemon.status` version reporting —
    /// t1 commit e58c008b). `main`'s latest tag at the time this floor
    /// was picked was v0.156.0, so v0.157.0 (the next default minor
    /// bump) is the first release where the two numbering schemes agree.
    ///
    /// Below this floor, `term-meshd --version` reports its own
    /// pre-sync Cargo version (observed in the wild: "0.72.0") — a
    /// number from a completely unrelated series, not a lagging point
    /// on the app's release train. Numerically comparing "0.72.0"
    /// against an app release tag like "0.156.0" always reads as
    /// "wildly outdated" even seconds after a legitimate update, so
    /// `compare` refuses to run that comparison below this floor and
    /// returns `.legacy` instead.
    static let versionSyncFloor = "0.157.0"

    /// `versionSyncFloor` is a fixed literal under this file's own
    /// control, so a parse failure here is a code bug, not a runtime
    /// condition — asserted by unit test
    /// (test_versionSyncFloor_isParsable) rather than threaded through
    /// `compare` as another optional to unwrap.
    private static let versionSyncFloorComponents: [Int] = {
        guard let components = parseComponents(versionSyncFloor) else {
            preconditionFailure("versionSyncFloor must be a parsable semver string")
        }
        return components
    }()

    /// Fetches the repo's latest release tag (e.g. "v0.156.0"). Returns
    /// nil on any network, HTTP, or parse failure — callers treat that
    /// the same as "can't tell", never as "up to date".
    ///
    /// Two sources, in order: the REST API, then the plain
    /// `releases/latest` redirect. The second is not a retry of the
    /// first — it exists because the API's failure mode here is routine.
    /// Unauthenticated calls share a 60-per-hour budget PER IP with
    /// everything else on the machine touching api.github.com, and once
    /// it is gone every call answers 403 for the rest of the hour. That
    /// is what a peer host reporting "server version unknown" usually
    /// means, and the cost is not cosmetic: `showsUpdateButton` in
    /// PeerHostEditorView renders only for `.updateAvailable`/
    /// `.legacyDaemon`, so an unknown version removes the update path
    /// from the UI entirely while the host sits several releases behind.
    static func fetchLatestRelease(repo: String = defaultRepo) async -> String? {
        if let tag = await fetchLatestReleaseViaAPI(repo: repo) { return tag }
        return await fetchLatestReleaseViaRedirect(repo: repo)
    }

    /// The REST API path — one documented JSON request, exact tag.
    static func fetchLatestReleaseViaAPI(repo: String = defaultRepo) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("term-mesh-peer-doctor", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return nil
            }
            return tag
        } catch {
            return nil
        }
    }

    /// The rate-limit-free path: `github.com/<repo>/releases/latest`
    /// redirects to the newest release's own page, so the tag is in the
    /// final URL. `install-linux.sh` resolves `latest` exactly this way
    /// (see its TAG resolution) — same answer, no API budget spent.
    ///
    /// HEAD rather than GET: only the redirect target is wanted, and the
    /// release page body is large enough that downloading it to throw it
    /// away would be the whole cost of the call.
    static func fetchLatestReleaseViaRedirect(repo: String = defaultRepo) async -> String? {
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        request.setValue("term-mesh-peer-doctor", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            // URLSession follows the redirect itself, so `response.url`
            // is the tag page — not the URL requested above.
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let finalURL = http.url else {
                return nil
            }
            return parseTagFromReleaseURL(finalURL.absoluteString)
        } catch {
            return nil
        }
    }

    /// Pure: pulls `v0.178.0` out of `…/releases/tag/v0.178.0`.
    ///
    /// Returns nil when there is no `/releases/tag/` segment at all —
    /// which is what a repo with no published releases looks like, since
    /// nothing redirects and the final URL is still `…/releases/latest`.
    /// Answering nil there matters: a tag invented from that URL would
    /// be compared against the host's real version and reported as an
    /// update.
    static func parseTagFromReleaseURL(_ absoluteString: String) -> String? {
        guard let marker = absoluteString.range(of: "/releases/tag/") else { return nil }
        var tag = String(absoluteString[marker.upperBound...])
        if let cut = tag.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            tag = String(tag[tag.startIndex..<cut])
        }
        guard !tag.isEmpty, !tag.contains("/") else { return nil }
        return tag.removingPercentEncoding ?? tag
    }

    /// Parses a semver-ish string into numeric components. Strips a
    /// leading "v"/"V", then drops any prerelease suffix (`-rc1`,
    /// `-beta.2`, …) and build metadata (`+build5`) — those identifiers
    /// are excluded from ordering entirely, not compared. Returns nil
    /// when what remains isn't a dotted run of integers (unparsable).
    static func parseComponents(_ raw: String) -> [Int]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plusIdx = s.firstIndex(of: "+") { s = String(s[s.startIndex..<plusIdx]) }
        if let dashIdx = s.firstIndex(of: "-") { s = String(s[s.startIndex..<dashIdx]) }
        guard !s.isEmpty else { return nil }

        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        components.reserveCapacity(parts.count)
        for part in parts {
            guard let n = Int(part) else { return nil }
            components.append(n)
        }
        return components.isEmpty ? nil : components
    }

    /// Numeric component-by-component comparison — never a string
    /// compare, so `0.9.0 < 0.100.0` holds. A shorter array is padded
    /// with zeros (`1.2` == `1.2.0`).
    static func compareComponents(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        let count = max(a.count, b.count)
        for i in 0..<count {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai != bi { return ai < bi ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Compares raw version strings end-to-end. `.unknown` whenever
    /// either side fails to parse — this function never guesses.
    /// `installed` strictly below `versionSyncFloor` short-circuits to
    /// `.legacy` before the numeric comparison runs at all — see
    /// `versionSyncFloor` for why that comparison isn't meaningful down
    /// there. `installed == versionSyncFloor` is NOT legacy: the sync
    /// release itself gets the precise comparison.
    static func compare(installed: String, latest: String) -> Comparison {
        guard let installedComponents = parseComponents(installed),
              let latestComponents = parseComponents(latest) else {
            return .unknown
        }
        if compareComponents(installedComponents, versionSyncFloorComponents) == .orderedAscending {
            return .legacy(latest: latest)
        }
        switch compareComponents(installedComponents, latestComponents) {
        case .orderedAscending:
            return .outdated(latest: latest)
        case .orderedSame, .orderedDescending:
            return .upToDate
        }
    }
}
