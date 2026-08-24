import Foundation
import simd

/// The rules of "Tiro al Trofeo", with none of the machinery.
///
/// Everything a toss needs to be decided — does this swipe count, may we launch
/// right now, how fast and in which direction does the ball leave, has this ball
/// already scored, is it time to clean it up — lives here as plain arithmetic
/// over `simd` vectors. The type imports no ARKit and no RealityKit, so it runs
/// (and is asserted) in the Simulator, where ARKit does not exist.
///
/// `PodiumARViewContainer.Coordinator` owns one of these and does the other
/// half: it reads the ARKit camera, spawns RealityKit entities and applies the
/// impulses this type hands it.
///
/// Conventions:
/// - **Screen space** is UIKit's: points, `+x` right, `+y` **down**. So an
///   upward flick has a *negative* `translation.y`.
/// - **World space** is RealityKit's: metres, `+y` up.
///
/// # Tuning (Gate 3 → Phase 4)
///
/// Every number the game's feel depends on is a stored property of `Tuning`, so
/// the owner's feedback ("too weak", "too floaty", "curves too much") turns into
/// a one-line edit of ``Tuning/init()``'s defaults rather than a hunt through
/// the AR code.
///
/// ## Where the launch-speed range comes from
///
/// Not from eye-balling. The scene fixes the geometry: the cup's floor sits
/// 0.166 m and its mouth 0.226 m above the surface the podium stands on, so a
/// ball has to arrive at ≈ 0.20 m. A player holds the phone ≈ 0.35 m above that
/// surface and the ball leaves ``Tuning/spawnDownOffset`` below the camera, so
/// it starts at ≈ 0.31 m — i.e. it has to **drop** ≈ 0.11 m over the throw.
///
/// Every throw leaves along `normalize(aim + worldUp · arc + side · lateral)`.
/// With ``Tuning/arc`` = 0.45 that is 24.2° above the aim **when the phone is
/// level** — but the player is looking down at a podium on a table, and the loft
/// is added along *world* up, so a downward tilt eats straight into the launch
/// angle. That is the part the first (4.5 m/s) ceiling missed, and it is why
/// Gate 3 row 3.1 reported having to walk the camera closer.
///
/// Solving `x = v·cosθ·t`, `Δy = v·sinθ·t − ½gt²` at g = 9.81 m/s²:
///
/// | Distance | Phone aimed at the cup | Phone tilted 20° down |
/// |---|---|---|
/// | 0.5 m | 2.4 m/s (θ ≈ 13.5°) | 2.7 m/s (θ ≈ 6.6°) |
/// | 0.7 m | 2.9 m/s | 3.6 m/s |
/// | 1.0 m | 3.5 m/s | 4.7 m/s |
/// | 1.5 m | 4.3 m/s | 6.3 m/s |
/// | 2.0 m | 5.0 m/s | 7.7 m/s |
///
/// So the old 4.5 m/s ceiling topped out at ~1.7 m with a flat aim and **0.9 m**
/// with a 20° tilt — hence "move closer". ``Tuning/maxLaunchSpeed`` is now
/// **6.8 m/s**, which reaches ~2.8 m aimed flat and ~1.7 m at a steep tilt: a
/// hard flick clears the ~2 m the owner asked for without walking, and the
/// 7 m/s-ish worst case is only out of reach if the player insists on staring at
/// their own feet.
///
/// ## Why the mapping is a curve, not a line
///
/// Raising the ceiling with the old straight line would have dragged every mid
/// flick up with it (a 1200 pt/s flick would jump 2.8 → 3.8 m/s and sail over a
/// cup 0.7 m away). Instead the flick fraction is raised to
/// ``Tuning/powerCurve`` = 1.8 before it is mixed, which keeps the low and
/// middle of the range where Gate 3 said it already felt right and spends all
/// the new headroom on the hardest flicks:
///
/// | Upward flick | Launch speed | Lands about |
/// |---|---|---|
/// | 600 pt/s (lazy) | 1.8 m/s | short of 0.4 m |
/// | 1000 pt/s | 2.5 m/s | ≈ 0.55 m |
/// | 1200 pt/s | 2.9 m/s | ≈ 0.75 m |
/// | 1400 pt/s | 3.5 m/s | ≈ 1.0 m |
/// | 1800 pt/s | 4.9 m/s | ≈ 1.8 m |
/// | 2200 pt/s (hard) | 6.8 m/s | ≈ 2.8 m |
///
/// ``Tuning/fastFlick`` also came down 2400 → 2200 pt/s so the ceiling is
/// actually reachable by a thumb rather than being a number in a file.
struct TossController {

    // MARK: - Tuning

    /// Every constant the game's feel depends on, in one place.
    struct Tuning: Equatable {

        // Ball body — a table-tennis-sized sphere with a little bounce.

        /// Radius of the ball, in metres. 3.5 cm against a 10 cm cup mouth.
        var ballRadius: Float = 0.035
        /// Mass, in kilograms. Light enough to be lively, heavy enough that a
        /// bounce off the podium does not fling it across the room.
        var ballMass: Float = 0.045
        /// Bounciness. Kept well under the cup wall's own value so a ball that
        /// hits the rim does not rocket away.
        var ballRestitution: Float = 0.35
        var ballFriction: Float = 0.60

        // Launch power — flick speed in points/second maps onto metres/second.

        /// Speed of the weakest launch, in m/s. Undershoots from ~0.5 m.
        var minLaunchSpeed: Float = 1.6
        /// Speed of the hardest launch, in m/s. Reaches ~2.8 m with the phone
        /// aimed flat, ~1.7 m with it tilted well down (Gate 3 row 3.1: the
        /// previous 4.5 m/s made the player walk closer).
        var maxLaunchSpeed: Float = 6.8
        /// Upward flick speed (points/second) that still maps to
        /// ``minLaunchSpeed`` — a slow drag.
        var slowFlick: Float = 350
        /// Upward flick speed (points/second) that reaches ``maxLaunchSpeed``.
        /// A hard thumb flick covers ~250 pt in ~0.11 s.
        var fastFlick: Float = 2200
        /// Shape of the flick → speed curve: the normalised flick fraction is
        /// raised to this power before it is mixed between the two speeds.
        ///
        /// `1` is the straight line Phase 3 used. Above 1 the curve sags, so the
        /// gentle and middling flicks keep the speeds they had before the
        /// ceiling was raised and only the hardest flicks reach the new top end
        /// — which is the whole point of 4.0a: more reach, same sweet spot.
        var powerCurve: Float = 1.8
        /// Floor on the measured swipe duration, so a gesture the system reports
        /// as near-instant cannot divide its way to an absurd flick speed.
        var minimumSwipeDuration: TimeInterval = 0.05
        /// How far the finger must travel **upward** for the gesture to count as
        /// a toss at all. Stops a stray drag while aiming from firing a ball.
        var minimumUpwardTravel: Float = 40

        // Aim — where the ball goes.

        /// World-up added per unit of camera-forward before normalising, i.e.
        /// how much loft is baked into every throw. 0.45 ≈ 24° above the aim.
        var arc: Float = 0.45
        /// Points of *horizontal* swipe that produce one full unit of sideways
        /// deflection (before the cap below).
        var lateralReference: Float = 220
        /// Hard cap on the sideways deflection, as a fraction of the aim vector.
        /// Keeps a diagonal flick a nudge rather than a right-angle turn.
        var maxLateral: Float = 0.35

        // Spawn point — just in front of the camera, not inside it.

        /// Metres in front of the camera the ball appears at, so it is outside
        /// the near plane and visibly leaves the player's hand.
        var spawnForwardOffset: Float = 0.16
        /// Metres below the camera the ball appears at, so it arcs up into view
        /// rather than starting dead centre over the crosshair.
        var spawnDownOffset: Float = 0.04

        // Flood control (FR-006, edge case "ball spam").

        /// Minimum seconds between two launches.
        var minimumLaunchInterval: TimeInterval = 0.30
        /// Hard cap on balls simulating at once.
        var maximumLiveBalls: Int = 8

        // Culling (FR-006, edge case "stale balls").

        /// Speed (m/s) below which a ball counts as motionless.
        var restSpeed: Float = 0.06
        /// Seconds a ball may sit still before it is removed.
        var restDuration: TimeInterval = 1.0
        /// Seconds any ball may exist, however it is moving.
        var maximumAge: TimeInterval = 5.0
        /// Height relative to the anchor plane (metres, so negative is below the
        /// table) past which a ball has clearly left the play area.
        var minimumHeight: Float = -0.40

        // Rim rescue (Gate 3 row 3.2) — a ball must never be balanced on the
        // cup's rim when the rest-culler fires, because from the player's seat
        // that reads as the ball evaporating.

        /// How far *below* the rim's top face (as a fraction of the ball's
        /// radius) a resting ball's centre may be and still count as perched on
        /// the rim rather than sitting inside the cup.
        ///
        /// A ball inside the cup rests with its centre ≈ 0.7 radii **below** the
        /// rim; one balanced on the rim sits a full radius above it. 0.4 splits
        /// those two cases with room to spare on both sides.
        var rimGraceFraction: Float = 0.40
        /// Speed (m/s) of the destabilising shove given to a ball caught resting
        /// on the rim. Big enough to topple it, small enough that it drops in or
        /// falls off rather than being launched.
        var rimNudgeSpeed: Float = 0.30
        /// Downward part of that shove, as a fraction of its horizontal part, so
        /// the ball commits to falling instead of skating along the rim.
        var rimNudgeDownwardBias: Float = 0.35
        /// How many times one ball may be nudged before it is culled anyway.
        /// Bounds the worst case; in practice the first shove settles it.
        var maximumRimNudges: Int = 3
        /// Seconds of life handed back to a ball each time it is nudged, so the
        /// shove has time to work before the same cull rule fires again.
        var rimNudgeGrace: TimeInterval = 1.0

        init() {}
    }

    // MARK: - Values crossing the boundary

    /// Identifier the controller hands out per launch. Monotonic and never
    /// reused, so a stale collision event can never credit a later ball.
    typealias BallID = UInt64

    /// A finished swipe, in UIKit screen space.
    struct Swipe: Equatable {
        /// Total finger travel in points: `+x` right, `+y` **down**.
        var translation: SIMD2<Float>
        /// Seconds between touch-down and lift.
        var duration: TimeInterval

        init(translation: SIMD2<Float>, duration: TimeInterval) {
            self.translation = translation
            self.duration = duration
        }

        /// Upward travel in points (0 for a sideways or downward swipe).
        var upwardTravel: Float { max(-translation.y, 0) }
    }

    /// The camera's world-space pose, reduced to the three things a throw needs.
    ///
    /// Built from an `ARCamera`'s transform by the AR side; `simd_float4x4` is a
    /// math type, so taking it here keeps this file free of ARKit.
    struct CameraBasis: Equatable {
        /// Where the camera is, in world space.
        var position: SIMD3<Float>
        /// Unit vector the camera looks along.
        var forward: SIMD3<Float>
        /// Unit vector out of the camera's right-hand side.
        var right: SIMD3<Float>

        init(position: SIMD3<Float>, forward: SIMD3<Float>, right: SIMD3<Float>) {
            self.position = position
            self.forward = forward
            self.right = right
        }

        /// ARKit's camera transform: `+x` right, `+y` up, `+z` **backward**, so
        /// the viewing direction is the negated third column.
        init(transform: simd_float4x4) {
            self.init(
                position: SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
                forward: -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z),
                right: SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
            )
        }
    }

    /// Everything the AR side needs to put one ball into the scene.
    struct Launch: Equatable {
        var ball: BallID
        /// World-space spawn point.
        var origin: SIMD3<Float>
        /// World-space velocity the ball should leave with, in m/s.
        var velocity: SIMD3<Float>
        /// The same thing as an impulse (mass × velocity), which is what
        /// RealityKit's `applyLinearImpulse` wants.
        var impulse: SIMD3<Float>
    }

    /// Why a flick did not become a ball.
    enum Rejection: Equatable {
        /// The finger did not travel far enough upward to read as a toss.
        case notAToss
        /// Less than ``Tuning/minimumLaunchInterval`` since the last launch.
        case tooSoon
        /// ``Tuning/maximumLiveBalls`` are already in flight.
        case tooManyLiveBalls
    }

    enum Outcome: Equatable {
        case launched(Launch)
        case rejected(Rejection)
    }

    /// Why a ball is being taken out of the scene.
    enum CullReason: Equatable {
        /// It has been motionless long enough to be litter.
        case atRest
        /// It fell off the table or was thrown out of the play area.
        case outOfBounds
        /// It simply ran out of time.
        case expired
    }

    // MARK: - State

    var tuning: Tuning

    /// Balls currently simulating, newest last.
    private(set) var liveBalls: [BallID] = []
    /// Balls that have already been credited. Cleared per ball on ``retire(_:)``
    /// — ids are never reused, so nothing can be double-credited afterwards.
    private var scoredBalls: Set<BallID> = []
    private var lastLaunch: TimeInterval?
    private var nextBall: BallID = 1

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    var liveBallCount: Int { liveBalls.count }

    func hasScored(_ ball: BallID) -> Bool { scoredBalls.contains(ball) }

    func isLive(_ ball: BallID) -> Bool { liveBalls.contains(ball) }

    // MARK: - Swipe → impulse (pure)

    /// Does this gesture read as a toss, rather than as aiming or a stray drag?
    func isToss(_ swipe: Swipe) -> Bool {
        swipe.upwardTravel >= tuning.minimumUpwardTravel
    }

    /// Launch speed in m/s, clamped to
    /// ``Tuning/minLaunchSpeed``…``Tuning/maxLaunchSpeed``.
    ///
    /// Only the **upward** part of the swipe sets the power. That keeps aiming
    /// and power independent: sideways travel steers (see ``lateralDeflection``)
    /// and never adds force, so a hard sideways swipe is a gentle, wide throw
    /// rather than a rocket.
    ///
    /// The flick fraction is shaped by ``Tuning/powerCurve`` before it is mixed,
    /// so raising the ceiling for hard flicks (4.0a) did not also make every
    /// ordinary flick overshoot. The function stays monotonic in flick speed for
    /// any positive exponent.
    func launchSpeed(for swipe: Swipe) -> Float {
        let seconds = Float(max(swipe.duration, tuning.minimumSwipeDuration))
        let flick = swipe.upwardTravel / seconds
        let span = max(tuning.fastFlick - tuning.slowFlick, 1)
        let t = min(max((flick - tuning.slowFlick) / span, 0), 1)
        let shaped = tuning.powerCurve == 1 ? t : pow(t, max(tuning.powerCurve, 0.01))
        return tuning.minLaunchSpeed + shaped * (tuning.maxLaunchSpeed - tuning.minLaunchSpeed)
    }

    /// Sideways steering from the horizontal part of the swipe, as a fraction of
    /// the aim vector, clamped to ±``Tuning/maxLateral``. Positive is to the
    /// player's right, matching the swipe.
    func lateralDeflection(for swipe: Swipe) -> Float {
        let raw = swipe.translation.x / max(tuning.lateralReference, 1)
        return min(max(raw, -tuning.maxLateral), tuning.maxLateral)
    }

    /// Where the ball leaves from: just in front of and slightly below the
    /// camera, so it is outside the near plane and reads as leaving the hand.
    func launchOrigin(camera: CameraBasis) -> SIMD3<Float> {
        let aim = Self.unit(camera.forward, fallback: Self.defaultForward)
        return camera.position
            + aim * tuning.spawnForwardOffset
            - Self.worldUp * tuning.spawnDownOffset
    }

    /// World-space launch velocity: the camera's aim, lofted by ``Tuning/arc``
    /// and steered by the swipe, scaled to ``launchSpeed(for:)``.
    ///
    /// The loft is added along **world** up rather than the camera's up, so the
    /// arc is the same whether the player holds the phone level or tilted.
    func launchVelocity(for swipe: Swipe, camera: CameraBasis) -> SIMD3<Float> {
        let aim = Self.unit(camera.forward, fallback: Self.defaultForward)
        let side = Self.unit(camera.right, fallback: Self.defaultRight)
        let heading = aim
            + Self.worldUp * tuning.arc
            + side * lateralDeflection(for: swipe)
        // |aim| == 1 and both additions are < 1, so `heading` cannot collapse to
        // zero; the fallback is belt-and-braces for a degenerate camera basis.
        return Self.unit(heading, fallback: aim) * launchSpeed(for: swipe)
    }

    /// The velocity above expressed as the impulse RealityKit expects (N·s).
    func impulse(for swipe: Swipe, camera: CameraBasis) -> SIMD3<Float> {
        launchVelocity(for: swipe, camera: camera) * tuning.ballMass
    }

    // MARK: - Launching (stateful)

    /// Why a launch would be refused right now, or `nil` if it is allowed.
    func launchBlocker(at now: TimeInterval) -> Rejection? {
        if liveBalls.count >= tuning.maximumLiveBalls { return .tooManyLiveBalls }
        if let lastLaunch, now - lastLaunch < tuning.minimumLaunchInterval { return .tooSoon }
        return nil
    }

    /// Turns a finished swipe into a ball, subject to the gesture test, the rate
    /// limit and the live-ball cap.
    ///
    /// On success the new ball is recorded as live; the caller is responsible
    /// for calling ``retire(_:)`` when it removes the entity again.
    mutating func flick(_ swipe: Swipe, camera: CameraBasis, at now: TimeInterval) -> Outcome {
        guard isToss(swipe) else { return .rejected(.notAToss) }
        if let blocker = launchBlocker(at: now) { return .rejected(blocker) }

        let ball = nextBall
        nextBall += 1
        liveBalls.append(ball)
        lastLaunch = now

        let velocity = launchVelocity(for: swipe, camera: camera)
        return .launched(
            Launch(
                ball: ball,
                origin: launchOrigin(camera: camera),
                velocity: velocity,
                impulse: velocity * tuning.ballMass
            )
        )
    }

    // MARK: - Scoring (SC-002)

    /// Credits a ball for landing in the cup.
    ///
    /// Returns `true` **exactly once** per ball: the cup's trigger volume fires
    /// a collision every time the ball crosses it — settling, bouncing, rolling
    /// — and only the first of those is a point. A ball that has already been
    /// retired scores nothing, so a late event cannot resurrect it.
    mutating func score(_ ball: BallID) -> Bool {
        guard liveBalls.contains(ball) else { return false }
        return scoredBalls.insert(ball).inserted
    }

    // MARK: - Culling (FR-006)

    /// Runs the "how long has this ball been still" accumulator.
    ///
    /// Returns the updated resting time: `previous + delta` while the ball is
    /// slower than ``Tuning/restSpeed``, and back to zero the moment it moves.
    func restingDuration(previous: TimeInterval, speed: Float, delta: TimeInterval) -> TimeInterval {
        speed <= tuning.restSpeed ? previous + delta : 0
    }

    /// Whether this ball should leave the scene, and why.
    func cullReason(
        age: TimeInterval,
        restingFor: TimeInterval,
        heightAboveAnchor: Float
    ) -> CullReason? {
        if heightAboveAnchor < tuning.minimumHeight { return .outOfBounds }
        if restingFor >= tuning.restDuration { return .atRest }
        if age >= tuning.maximumAge { return .expired }
        return nil
    }

    // MARK: - Rim rescue (Gate 3 row 3.2)

    /// Where a ball sits relative to the cup, reduced to the two numbers the
    /// rim rule needs. Both are measured in the cup's own frame.
    struct RimContact: Equatable {
        /// Ball centre minus the top of the cup wall, in metres. Positive means
        /// the ball is above the mouth.
        var heightAboveRim: Float
        /// Horizontal distance from the cup's axis, in metres.
        var radialDistance: Float

        init(heightAboveRim: Float, radialDistance: Float) {
            self.heightAboveRim = heightAboveRim
            self.radialDistance = radialDistance
        }
    }

    /// Is this ball balanced on the cup's rim, rather than resting inside the
    /// cup or somewhere else in the scene?
    ///
    /// Gate 3 row 3.2: balls occasionally came to rest on the 6 mm rim and were
    /// then removed by the rest-culler, which looks to the player like the ball
    /// vanishing. The geometry answers the question cleanly — a ball in the cup
    /// has its centre below the rim, a ball on the rim has it a radius above —
    /// so the caller can shove the perched one instead of deleting it.
    func isPerchedOnRim(
        _ contact: RimContact,
        ballRadius: Float,
        cupOuterRadius: Float
    ) -> Bool {
        contact.heightAboveRim > -ballRadius * tuning.rimGraceFraction
            && contact.radialDistance < cupOuterRadius + ballRadius
    }

    /// The shove given to a perched ball: horizontal, in the direction
    /// `azimuth` (radians, measured from +X toward +Z), with a downward bias so
    /// it drops rather than skates.
    ///
    /// The direction is a parameter rather than a random draw so the rule stays
    /// pure and testable; the AR side picks the angle. It is picked at random
    /// there on purpose — a ball tipped off the rim should be as free to fall
    /// *in* as to fall out, which is exactly what Gate 3 row 3.2 asked for.
    func rimNudgeVelocity(azimuth: Float) -> SIMD3<Float> {
        SIMD3<Float>(
            cos(azimuth) * tuning.rimNudgeSpeed,
            -tuning.rimNudgeSpeed * tuning.rimNudgeDownwardBias,
            sin(azimuth) * tuning.rimNudgeSpeed
        )
    }

    /// The same shove as an impulse (N·s).
    func rimNudgeImpulse(azimuth: Float) -> SIMD3<Float> {
        rimNudgeVelocity(azimuth: azimuth) * tuning.ballMass
    }

    /// Whether a ball that the culler wants to remove has any nudges left.
    func mayNudgeOffRim(nudgesSoFar: Int) -> Bool {
        nudgesSoFar < tuning.maximumRimNudges
    }

    /// Forgets a ball the caller has removed from the scene.
    mutating func retire(_ ball: BallID) {
        liveBalls.removeAll { $0 == ball }
        scoredBalls.remove(ball)
    }

    /// Drops all per-ball state, e.g. when the podium is relocated and every
    /// ball is cleared out with it. Ids keep counting up.
    mutating func retireAll() {
        liveBalls.removeAll()
        scoredBalls.removeAll()
        lastLaunch = nil
    }

    // MARK: - Vector helpers

    static let worldUp = SIMD3<Float>(0, 1, 0)
    private static let defaultForward = SIMD3<Float>(0, 0, -1)
    private static let defaultRight = SIMD3<Float>(1, 0, 0)

    /// `simd_normalize` on a zero-length vector is a NaN factory; this is the
    /// same operation with a defined answer for that case.
    private static func unit(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        guard lengthSquared > 1e-12, lengthSquared.isFinite else { return fallback }
        return vector / lengthSquared.squareRoot()
    }
}
