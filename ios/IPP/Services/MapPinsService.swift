import Foundation

/// Reads the backend's anonymized map pins for the AR mini-game's floor map
/// (FR-013), at the **app layer** — this is the piece that keeps
/// `ios/IPP/Game/` free of networking (FR-008, question Q5, option A).
///
/// The game is handed a plain `FloorMapData` and cannot tell whether it came
/// from the backend or from the offline sample, so it needs no reachability
/// logic, no error states and no timeouts of its own.
///
/// Read-only by construction: one GET, no auth headers, nothing written back.
/// The response's record ids and anchor keys are discarded here — see
/// ``GeoPin``.
struct MapPinsService {

    /// Long enough for a LAN round-trip carrying ~1000 pins, short enough that
    /// a player who opens the leaderboard offline is not left waiting.
    static let defaultTimeout: TimeInterval = 2.5

    var timeout: TimeInterval = defaultTimeout
    var session: URLSession?

    /// Chooses what the floor map shows. Pure — the whole fallback rule in one
    /// testable place.
    ///
    /// An **empty** backend answer counts as a miss, not as live data: a map
    /// with no pins on it looks broken, and "the backend is up but has no
    /// patients yet" is exactly the demo case where the sample is better than
    /// a blank plate.
    static func resolve(fetched: [GeoPin]?, fallback: [GeoPin]) -> FloorMapData {
        let usable = (fetched ?? []).filter(\.isUsable)
        if usable.isEmpty {
            return FloorMapData(pins: fallback.filter(\.isUsable), isLive: false)
        }
        return FloorMapData(pins: usable, isLive: true)
    }

    /// `GET {baseURL}/api/v1/map-pins`. Returns `nil` on any failure — an
    /// unreachable host, a non-2xx status or an undecodable body — because the
    /// caller's next move is the same in all three cases.
    func fetch(baseURL: URL) async -> [GeoPin]? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/map-pins"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let session = session ?? BackendLocator.makeSession(timeout: timeout)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return nil }
            return try JSONDecoder().decode(MapPinsResponse.self, from: data).coordinates
        } catch {
            return nil
        }
    }
}
