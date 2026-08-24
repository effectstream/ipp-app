import Foundation

/// One timed round of "Tiro al Trofeo" (FR-007), as a value type with no view,
/// no timer object and no ARKit anywhere in sight.
///
/// The round is **tick-driven**: something outside — in the app, the RealityKit
/// frame loop — hands it the elapsed time and it decides when the round is over.
/// Nothing here reads a clock, which is what makes every rule below testable in
/// the Simulator, where ARKit does not exist.
///
/// ```
/// idle ──start()──▶ running(remaining) ──tick() to 0──▶ ended(score)
///  ▲                      │                                │
///  └───────reset()────────┴────────────reset()─────────────┘
/// ```
///
/// # Pausing
///
/// Two things can stop the clock, and they are tracked separately rather than
/// as one flag: AR tracking going bad, and the app leaving the foreground. A
/// player who covers the camera *and* takes a call must get both back before
/// play resumes, which a single boolean would get wrong. While any reason is
/// present, ``tick(_:)`` consumes no time and the round accepts nothing — so
/// paused seconds are never charged to the player (edge cases "tracking loss
/// mid-round" and "backgrounding mid-round").
///
/// # Free practice vs the round
///
/// FR-007 says flicks are accepted only while a round runs. Taken literally
/// that also freezes the screen the player sees *before* they ever press
/// "Comenzar", which is where Phase 3's playable sandbox lived and where SC-001
/// (first flick within 30 s of opening the game) is actually satisfied. The
/// rule implemented here keeps both: **balls may always be thrown in `idle`,
/// but only a running round counts them**. ``acceptsFlicks`` is the gesture
/// gate, ``countsScores`` is the scoring gate, and they differ exactly in
/// `idle`. Nothing thrown outside a round can touch a round's score or its
/// clock, which is the part FR-007 is protecting.
struct GameRound: Equatable {

    // MARK: - Rules

    /// The knobs, in one place, the way `TossController.Tuning` does it.
    struct Rules: Equatable {
        /// Length of a round in seconds. The spec allows 30–60 s (US2); 60 s is
        /// long enough to recover from a bad start and matches SC-006's
        /// "60-second round of continuous play".
        var duration: TimeInterval = 60

        init() {}
    }

    // MARK: - State

    enum State: Equatable {
        case idle
        /// A round is under way; `remaining` counts down to zero.
        case running(remaining: TimeInterval)
        /// The clock ran out. Carries the final score so the summary cannot
        /// drift from what the round actually recorded.
        case ended(score: Int)
    }

    /// Why the clock is stopped. A set, not a flag: reasons come from
    /// independent sources and each must clear itself.
    enum PauseReason: String, Hashable, CaseIterable {
        /// ARKit reported limited tracking, or the session was interrupted.
        case trackingLimited
        /// The app is not the active scene.
        case backgrounded
    }

    var rules: Rules
    private(set) var state: State = .idle
    /// Points scored so far in the round in progress. Reset by ``start()``.
    private(set) var score: Int = 0
    private(set) var pauseReasons: Set<PauseReason> = []

    init(rules: Rules = Rules()) {
        self.rules = rules
    }

    // MARK: - Queries

    var isIdle: Bool { state == .idle }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var hasEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    /// A round is on the clock but the clock is stopped.
    var isPaused: Bool { isRunning && !pauseReasons.isEmpty }

    /// A round is on the clock and the clock is moving.
    var isTicking: Bool { isRunning && pauseReasons.isEmpty }

    /// Seconds left in the round in progress; zero when no round is running.
    var remaining: TimeInterval {
        if case .running(let remaining) = state { return remaining }
        return 0
    }

    /// Final score of the round that just finished, or `nil` if none has.
    var finalScore: Int? {
        if case .ended(let score) = state { return score }
        return nil
    }

    /// May the player throw a ball right now?
    ///
    /// Yes in `idle` (free practice, see the type's doc comment) and while a
    /// round is actually ticking. No while paused — gameplay stops with the
    /// clock — and no while the summary is up, so a stray swipe over the
    /// end-of-round card cannot fire a ball behind it.
    var acceptsFlicks: Bool {
        switch state {
        case .idle: return true
        case .running: return pauseReasons.isEmpty
        case .ended: return false
        }
    }

    /// Does a ball landing in the cup add to a round's score right now?
    /// Only while a round is ticking (FR-007).
    var countsScores: Bool { isTicking }

    /// May the player press "Comenzar"?
    var canStart: Bool { !isRunning }

    // MARK: - Transitions

    /// Begins a round, from `idle` or from a finished one ("Jugar de nuevo").
    ///
    /// Existing pause reasons are deliberately **kept**: they are owned by the
    /// outside world (tracking state, scene phase) and clearing them here would
    /// leave the round believing it can tick while the camera is still covered.
    /// A round started under a pause simply begins paused and starts counting
    /// when the cause clears.
    ///
    /// - Returns: `true` if a round actually started.
    @discardableResult
    mutating func start() -> Bool {
        guard canStart else { return false }
        score = 0
        state = .running(remaining: rules.duration)
        return true
    }

    /// Adds or clears one pause reason. Idempotent, so callers can fire it on
    /// every tracking-state change without bookkeeping of their own.
    mutating func setPaused(_ paused: Bool, reason: PauseReason) {
        if paused {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }
    }

    /// Advances the clock.
    ///
    /// A no-op unless a round is running with no pause reason, so paused and
    /// backgrounded time is never charged to the player.
    ///
    /// - Returns: `true` on the single tick that ends the round.
    @discardableResult
    mutating func tick(_ delta: TimeInterval) -> Bool {
        guard case .running(let remaining) = state,
              pauseReasons.isEmpty,
              delta > 0
        else { return false }

        let left = remaining - delta
        guard left > 0 else {
            state = .ended(score: score)
            return true
        }
        state = .running(remaining: left)
        return false
    }

    /// Credits a ball that earned points.
    ///
    /// The round does not care *which* tier earned them (FR-005: +1 for
    /// touching the cup, the balance of +10 for landing in it) — that rule
    /// lives in `TossController`, which hands the arithmetic down as a number.
    ///
    /// - Returns: `true` if the points went to a round. `false` means the throw
    ///   was free practice (or landed while paused), and the caller should tally
    ///   it somewhere that is not a round score.
    @discardableResult
    mutating func registerScore(_ points: Int = 1) -> Bool {
        guard countsScores else { return false }
        score += points
        return true
    }

    /// Back to `idle` — dismissing the summary, or relocating the podium.
    mutating func reset() {
        state = .idle
        score = 0
    }

    // MARK: - Presentation helpers

    /// The countdown as `m:ss`, rounded **up** so the HUD shows "1:00" for a
    /// round that has only just begun and only reaches "0:00" when time is
    /// genuinely gone.
    static func countdownText(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var countdownText: String { Self.countdownText(remaining) }
}
