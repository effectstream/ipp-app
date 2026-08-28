import Foundation

/// The one thing "Tiro al Trofeo" remembers between launches: a single integer
/// best score (FR-008, US2).
///
/// That is the whole persistence story for the game — no round history, no
/// player profile, nothing that leaves the device, and nothing that touches the
/// app's own data or the leaderboard. The spec is explicit that a device-local
/// best score is the *only* persistence allowed, so this type is deliberately
/// small enough to audit at a glance.
///
/// `UserDefaults` is injectable so tests can run against their own suite
/// instead of the app's, and so two instances can be pointed at the same suite
/// to prove the value really survives (which is the part that matters — the
/// store holds no cached copy, every read goes to disk).
struct BestScoreStore {

    /// Key under which the best score lives. Namespaced so it cannot collide
    /// with anything the rest of the app stores.
    static let defaultKey = "com.nonturing.ipp.trophyToss.bestScore"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = BestScoreStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The stored best, or 0 when nothing has been stored yet — `integer(forKey:)`
    /// already returns 0 for a missing key, and the `max` guards against a value
    /// some other writer left negative.
    var best: Int { max(defaults.integer(forKey: key), 0) }

    /// Records the score of a finished round.
    ///
    /// - Returns: `true` only when this round beat the stored best, which is
    ///   also the cue the summary uses to say "¡Nuevo récord!". Equal scores do
    ///   not count as a new record, and a zero-point round never writes at all.
    @discardableResult
    func submit(_ score: Int) -> Bool {
        guard score > 0, score > best else { return false }
        defaults.set(score, forKey: key)
        return true
    }

    /// Forgets the best score. Not reachable from the UI; it exists so tests
    /// (and a future debug menu) can start from a clean slate.
    func clear() {
        defaults.removeObject(forKey: key)
    }
}
