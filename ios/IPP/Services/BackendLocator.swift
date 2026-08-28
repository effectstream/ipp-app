import Foundation

/// Finds the IPP backend on the local network at launch (Phase 5C task 5C.1).
///
/// The bundled `BackendURL` is `http://localhost:3334`, which is right in the
/// Simulator and useless on a phone. On device the app therefore asks a short,
/// ordered list of candidates for `/health` and keeps the first one that
/// answers; `AppEnvironment.resolveBackend()` then points every client at it,
/// so login, patients, field stats, the schema and the leaderboard all follow.
///
/// The candidate hosts live in `Info.plist` under ``candidatesInfoKey``, next
/// to `BackendURL` and `WebURL` — **not** in this file (question Q7). A demo
/// Mac usually offers more than one address for the same server (an Ethernet
/// and a Wi-Fi interface on the same `/24`, say), and only the phone can say
/// which one its subnet actually reaches, so the list is ordered and tried in
/// turn. Pointing the app at a different machine is a plist edit, not a source
/// edit, and an empty or missing list simply means "only use `BackendURL`".
///
/// Everything about *which* URLs are tried and *in what order* is a pure
/// function (``candidates(configured:isSimulator:lan:)``) so it is unit-tested
/// off-device; only ``probe(_:timeout:session:)`` touches the network.
enum BackendLocator {

    /// `Info.plist` key holding the ordered array of candidate base URLs.
    static let candidatesInfoKey = "BackendCandidates"

    /// Turns the raw `Info.plist` value into URLs, ignoring anything unusable.
    ///
    /// Pure, so a malformed plist is a test case rather than a crash: a missing
    /// key, a wrong type, an empty array and junk strings all degrade to "no
    /// candidates", which just leaves the configured `BackendURL` in charge.
    static func parseCandidates(_ raw: Any?) -> [URL] {
        guard let strings = raw as? [String] else { return [] }
        return strings.compactMap { string in
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let url = URL(string: trimmed),
                  url.scheme != nil,
                  url.host != nil
            else { return nil }
            return url
        }
    }

    /// The candidate hosts this build was configured with, in order.
    static var lanCandidates: [URL] {
        parseCandidates(Bundle.main.object(forInfoDictionaryKey: candidatesInfoKey))
    }

    /// How long a single `/health` request may take before the next candidate
    /// is tried. Short: on a LAN a live host answers in single-digit
    /// milliseconds, and a dead one should not hold up the launch.
    static let defaultTimeout: TimeInterval = 1.5

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Hosts that only ever mean "this machine".
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// The candidate list, most likely first, with duplicates removed.
    ///
    /// - In the **Simulator** only the configured URL is tried. `localhost`
    ///   there is the Mac, which is exactly where the backend runs, and
    ///   reaching out to the LAN would be both pointless and slower.
    /// - On **device**, a configured loopback URL cannot possibly work, so the
    ///   two LAN addresses go first and the configured URL stays at the back as
    ///   a last resort.
    /// - A configured URL that is *not* loopback is someone deliberately
    ///   pointing the app somewhere, so it is tried first and the LAN addresses
    ///   become the fallback.
    ///
    /// `lan` defaults to the `Info.plist` list; it is a parameter only so the
    /// ordering can be tested against a fixed list.
    static func candidates(
        configured: URL,
        isSimulator: Bool,
        lan: [URL] = BackendLocator.lanCandidates
    ) -> [URL] {
        let ordered: [URL]
        if isSimulator {
            ordered = [configured]
        } else if isLoopback(configured) {
            ordered = lan + [configured]
        } else {
            ordered = [configured] + lan
        }

        var seen = Set<String>()
        return ordered.filter { seen.insert($0.absoluteString).inserted }
    }

    static func healthURL(for base: URL) -> URL {
        base.appendingPathComponent("health")
    }

    /// Asks each candidate for `/health` in turn and returns the first that
    /// answers 2xx. `nil` when none does — the caller then keeps whatever base
    /// URL it already had, which is the offline case.
    static func probe(
        _ candidates: [URL],
        timeout: TimeInterval = defaultTimeout,
        session: URLSession? = nil
    ) async -> URL? {
        let session = session ?? makeSession(timeout: timeout)
        for candidate in candidates {
            var request = URLRequest(url: healthURL(for: candidate))
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode)
                else { continue }
                return candidate
            } catch {
                continue
            }
        }
        return nil
    }

    static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
