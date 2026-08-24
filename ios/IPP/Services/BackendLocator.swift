import Foundation

/// Finds the IPP backend on the local network at launch (Phase 5C task 5C.1).
///
/// The bundled `BackendURL` is `http://localhost:3334`, which is right in the
/// Simulator and useless on a phone. On device the app therefore asks a short,
/// ordered list of candidates for `/health` and keeps the first one that
/// answers; `AppEnvironment.resolveBackend()` then points every client at it,
/// so login, patients, field stats, the schema and the leaderboard all follow.
///
/// Two LAN addresses are tried because the host Mac has two interfaces on the
/// same `/24` — Ethernet `192.168.100.15` (`en10`) and Wi-Fi `192.168.100.11`
/// (`en0`) — and only the phone can say which one its subnet reaches.
///
/// Everything about *which* URLs are tried and *in what order* is a pure
/// function (``candidates(configured:isSimulator:)``) so it is unit-tested
/// off-device; only ``probe(_:timeout:session:)`` touches the network.
enum BackendLocator {

    /// The owner's two host addresses, in the order the phone should try them.
    static let lanCandidates: [URL] = [
        URL(string: "http://192.168.100.15:3334")!,
        URL(string: "http://192.168.100.11:3334")!,
    ]

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
    static func candidates(configured: URL, isSimulator: Bool) -> [URL] {
        let ordered: [URL]
        if isSimulator {
            ordered = [configured]
        } else if isLoopback(configured) {
            ordered = lanCandidates + [configured]
        } else {
            ordered = [configured] + lanCandidates
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
