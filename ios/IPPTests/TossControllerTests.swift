import XCTest
import simd

@testable import IPP

/// Throwaway harness used during Phase 3 to exercise `TossController` for real
/// on a Simulator. Phase 6a adds the permanent test target; this file lives
/// outside the repo on purpose.
///
/// `TossController` imports no ARKit and no RealityKit, so every one of these
/// runs off-device — which is the whole point of keeping the game's rules in a
/// pure type.
final class TossControllerTests: XCTestCase {

    /// A player standing upright, camera 1 m up, looking along −Z with +X to
    /// their right — ARKit's convention, reduced to the basis the controller
    /// takes.
    private let camera = TossController.CameraBasis(
        position: [0, 1, 0],
        forward: [0, 0, -1],
        right: [1, 0, 0]
    )

    /// `up` is in points of upward finger travel, so the sign flip to UIKit's
    /// downward-positive screen space happens in exactly one place.
    private func swipe(
        up: Float = 0,
        sideways: Float = 0,
        duration: TimeInterval = 0.1
    ) -> TossController.Swipe {
        TossController.Swipe(translation: SIMD2(sideways, -up), duration: duration)
    }

    private var tuning: TossController.Tuning { TossController.Tuning() }

    // MARK: - Speed clamping

    func testZeroSwipeStillProducesAClampedForwardImpulse() {
        let controller = TossController()
        let flat = swipe()

        XCTAssertEqual(controller.launchSpeed(for: flat), tuning.minLaunchSpeed, accuracy: 1e-5)

        let velocity = controller.launchVelocity(for: flat, camera: camera)
        XCTAssertEqual(simd_length(velocity), tuning.minLaunchSpeed, accuracy: 1e-4)
        XCTAssertLessThan(velocity.z, 0, "a zero swipe must still travel away from the player")
        XCTAssertGreaterThan(velocity.y, 0, "every throw is lofted")
        XCTAssertEqual(velocity.x, 0, accuracy: 1e-5, "a straight swipe must not drift sideways")
    }

    func testSlowShortSwipeClampsToTheMinimumSpeed() {
        let controller = TossController()
        // 30 pt over half a second — 60 pt/s, far below `slowFlick`.
        XCTAssertEqual(
            controller.launchSpeed(for: swipe(up: 30, duration: 0.5)),
            tuning.minLaunchSpeed,
            accuracy: 1e-5
        )
    }

    func testFastLongSwipeClampsToTheMaximumSpeed() {
        let controller = TossController()
        // 600 pt in 80 ms — 7500 pt/s, far above `fastFlick`.
        XCTAssertEqual(
            controller.launchSpeed(for: swipe(up: 600, duration: 0.08)),
            tuning.maxLaunchSpeed,
            accuracy: 1e-5
        )
    }

    func testSpeedRisesWithFlickSpeedBetweenTheClamps() {
        let controller = TossController()
        let gentle = controller.launchSpeed(for: swipe(up: 120, duration: 0.20)) //  600 pt/s
        let firm = controller.launchSpeed(for: swipe(up: 200, duration: 0.15))   // ~1333 pt/s
        let hard = controller.launchSpeed(for: swipe(up: 260, duration: 0.12))   // ~2167 pt/s

        XCTAssertLessThan(gentle, firm)
        XCTAssertLessThan(firm, hard)
        for speed in [gentle, firm, hard] {
            XCTAssertGreaterThanOrEqual(speed, tuning.minLaunchSpeed)
            XCTAssertLessThanOrEqual(speed, tuning.maxLaunchSpeed)
        }
    }

    func testAnImplausiblyBriefSwipeCannotDivideItsWayPastTheMaximum() {
        let controller = TossController()
        XCTAssertEqual(
            controller.launchSpeed(for: swipe(up: 200, duration: 0)),
            tuning.maxLaunchSpeed,
            accuracy: 1e-5
        )
    }

    // MARK: - Direction

    func testEveryThrowIsLoftedByTheTunedArc() {
        let controller = TossController()
        let velocity = controller.launchVelocity(for: swipe(up: 200), camera: camera)
        // Camera aims along −Z, so the loft shows up as up-over-forward.
        XCTAssertEqual(velocity.y / -velocity.z, tuning.arc, accuracy: 1e-4)
    }

    func testSidewaysSwipeDeflectsTowardTheSwipeWithoutAddingPower() {
        let controller = TossController()
        let right = controller.launchVelocity(for: swipe(up: 120, sideways: 300), camera: camera)
        let left = controller.launchVelocity(for: swipe(up: 120, sideways: -300), camera: camera)
        let straight = controller.launchVelocity(for: swipe(up: 120), camera: camera)

        XCTAssertGreaterThan(right.x, 0, "swiping right must throw right")
        XCTAssertLessThan(left.x, 0, "swiping left must throw left")
        XCTAssertEqual(right.x, -left.x, accuracy: 1e-5, "deflection must be symmetric")

        // Power comes from the upward component alone, so all three are the
        // same speed in different directions.
        XCTAssertEqual(simd_length(right), simd_length(straight), accuracy: 1e-4)
        XCTAssertEqual(simd_length(left), simd_length(straight), accuracy: 1e-4)
    }

    func testPurelySidewaysSwipeIsClampedToTheMinimumSpeedAndStillAimsForward() {
        let controller = TossController()
        let velocity = controller.launchVelocity(for: swipe(sideways: 400), camera: camera)

        XCTAssertEqual(simd_length(velocity), tuning.minLaunchSpeed, accuracy: 1e-4)
        XCTAssertLessThan(velocity.z, 0)
        XCTAssertGreaterThan(velocity.x, 0)
    }

    func testLateralDeflectionIsCapped() {
        let controller = TossController()
        XCTAssertEqual(
            controller.lateralDeflection(for: swipe(up: 100, sideways: 5000)),
            tuning.maxLateral,
            accuracy: 1e-5
        )
        XCTAssertEqual(
            controller.lateralDeflection(for: swipe(up: 100, sideways: -5000)),
            -tuning.maxLateral,
            accuracy: 1e-5
        )
    }

    func testDirectionFollowsTheCameraRatherThanTheWorldAxes() {
        let controller = TossController()
        // Player turned 90° to face +X.
        let turned = TossController.CameraBasis(
            position: [0, 1, 0],
            forward: [1, 0, 0],
            right: [0, 0, 1]
        )
        let velocity = controller.launchVelocity(for: swipe(up: 200), camera: turned)
        XCTAssertGreaterThan(velocity.x, 0, "the throw must follow the camera's aim")
        XCTAssertEqual(velocity.z, 0, accuracy: 1e-5)
        XCTAssertGreaterThan(velocity.y, 0)
    }

    func testCameraBasisIsReadFromAnARKitStyleTransform() {
        // ARKit camera transform, in its own landscape-right axes: +x right,
        // +y up, +z backward.
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(0.5, 1.2, -0.3, 1)
        let basis = TossController.CameraBasis(transform: transform, orientation: .landscapeRight)

        XCTAssertEqual(basis.position, SIMD3<Float>(0.5, 1.2, -0.3))
        XCTAssertEqual(basis.forward, SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(basis.right, SIMD3<Float>(1, 0, 0))
    }

    // MARK: - The sideways axis (Q4, Phase 5B task 5B.0)
    //
    // Gate 5 row 5-g5: "I only see straight ball launches even with diagonal
    // swipes". ARKit hands out a camera transform in landscape-right axes
    // whatever the device is doing, and IPP is portrait-locked, so the old
    // `columns.0` reading was steering along the phone's long axis.

    /// The ARKit camera transform of a phone held **in portrait**, back camera
    /// looking along −Z, tilted `pitch` radians downward at the table.
    ///
    /// In landscape-right axes that means `columns.0` (ARKit's "right") runs
    /// down the phone's long axis and `columns.1` (ARKit's "up") runs across
    /// the screen — which is the whole of Q4, in two columns.
    private func portraitCameraTransform(
        pitch: Float = 0,
        position: SIMD3<Float> = [0, 1.3, 0]
    ) -> simd_float4x4 {
        let c = cos(pitch)
        let s = sin(pitch)
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(0, -c, s, 0)
        transform.columns.1 = SIMD4<Float>(1, 0, 0, 0)
        transform.columns.2 = SIMD4<Float>(0, s, c, 0)
        transform.columns.3 = SIMD4<Float>(position, 1)
        return transform
    }

    func testPortraitBasisReadsRightAcrossTheScreenNotAlongThePhone() {
        let pitch: Float = 0.35
        let transform = portraitCameraTransform(pitch: pitch)

        // The bug, stated as an assertion: ARKit's first column is very nearly
        // world-vertical for this pose, so reading it as "right" steers the
        // throw up and down.
        let landscapeColumn = SIMD3<Float>(
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z
        )
        XCTAssertGreaterThan(abs(landscapeColumn.y), 0.9)

        let basis = TossController.CameraBasis(transform: transform)
        XCTAssertEqual(basis.right.x, 1, accuracy: 1e-5, "portrait right is across the screen")
        XCTAssertEqual(basis.right.y, 0, accuracy: 1e-5)
        XCTAssertEqual(basis.right.z, 0, accuracy: 1e-5)
        XCTAssertEqual(basis.forward.y, -sin(pitch), accuracy: 1e-5, "and the aim still points down")
        XCTAssertEqual(basis.forward.z, -cos(pitch), accuracy: 1e-5)
    }

    func testTheFourOrientationsAreQuarterTurnsOfEachOther() {
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(1, 0, 0, 0)
        transform.columns.1 = SIMD4<Float>(0, 1, 0, 0)

        func right(_ orientation: TossController.ScreenOrientation) -> SIMD3<Float> {
            TossController.CameraBasis(transform: transform, orientation: orientation).right
        }

        XCTAssertEqual(right(.landscapeRight), SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(right(.landscapeLeft), SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(right(.portrait), SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(right(.portraitUpsideDown), SIMD3<Float>(0, -1, 0))
    }

    func testPortraitIsTheDefaultOrientationBecauseTheAppIsPortraitLocked() {
        let transform = portraitCameraTransform(pitch: 0.2)
        XCTAssertEqual(
            TossController.CameraBasis(transform: transform).right,
            TossController.CameraBasis(transform: transform, orientation: .portrait).right
        )
    }

    func testSideAxisIsHorizontalAndAcrossTheAimForEveryPose() {
        for pitchDegrees in stride(from: Float(-40), through: 60, by: 10) {
            for yawDegrees in stride(from: Float(0), through: 315, by: 45) {
                let pitch = pitchDegrees * .pi / 180
                let yaw = yawDegrees * .pi / 180
                let turn = simd_float4x4(simd_quatf(angle: yaw, axis: [0, 1, 0]))
                let transform = turn * portraitCameraTransform(pitch: pitch)
                let basis = TossController.CameraBasis(transform: transform)
                let side = basis.sideAxis
                let label = "pitch \(pitchDegrees)° yaw \(yawDegrees)°"

                XCTAssertEqual(simd_length(side), 1, accuracy: 1e-4, label)
                XCTAssertEqual(
                    simd_dot(side, TossController.worldUp), 0, accuracy: 1e-4,
                    "\(label): steering must be orthogonal to gravity"
                )
                XCTAssertEqual(
                    simd_dot(side, basis.forward), 0, accuracy: 1e-4,
                    "\(label): steering must be orthogonal to the aim"
                )
            }
        }
    }

    func testDiagonalFlickVeersSidewaysInsteadOfChangingHeight() {
        let controller = TossController()
        // Looking 20° down at a podium on a table, portrait, as at Gate 5.
        let basis = TossController.CameraBasis(transform: portraitCameraTransform(pitch: 0.35))
        let side = basis.sideAxis

        let straight = controller.launchVelocity(for: swipe(up: 200), camera: basis)
        let diagonal = controller.launchVelocity(for: swipe(up: 200, sideways: 260), camera: basis)
        let mirrored = controller.launchVelocity(for: swipe(up: 200, sideways: -260), camera: basis)
        let speed = controller.launchSpeed(for: swipe(up: 200))

        // A straight flick has no sideways component at all…
        XCTAssertEqual(simd_dot(straight, side), 0, accuracy: 1e-4)
        // …and a diagonal one has a big one, in the direction of the swipe.
        XCTAssertGreaterThan(
            simd_dot(diagonal, side), 0.25 * speed,
            "an up-and-right flick must actually veer right"
        )
        XCTAssertEqual(
            simd_dot(mirrored, side), -simd_dot(diagonal, side), accuracy: 1e-4,
            "and up-and-left must mirror it"
        )
        XCTAssertGreaterThan(diagonal.x, 0.25 * speed, "which here is world +x")
        XCTAssertLessThan(mirrored.x, -0.25 * speed)

        // The height of the throw is what must *not* move: the deflection is
        // horizontal, so the only change in the vertical component is the small
        // one that comes from re-normalising a longer heading vector.
        XCTAssertEqual(
            diagonal.y, straight.y,
            accuracy: 0.1 * abs(straight.y),
            "steering must not trade itself for loft — that was the Q4 bug"
        )
        XCTAssertEqual(simd_length(diagonal), simd_length(straight), accuracy: 1e-4)
    }

    func testTheOldLandscapeReadingSteeredAlongAQuiteDifferentAxis() {
        // A regression witness rather than a rule: with the same pose read as
        // landscape-right — what the code did until Phase 5B — the steering
        // axis is (nearly) perpendicular to the screen's real right-hand axis,
        // so a rightward swipe pushed the ball somewhere else entirely.
        let transform = portraitCameraTransform(pitch: 0.35)
        let corrected = TossController.CameraBasis(transform: transform).sideAxis
        let old = TossController.CameraBasis(transform: transform, orientation: .landscapeRight).sideAxis

        XCTAssertEqual(abs(simd_dot(corrected, old)), 0, accuracy: 1e-4)
    }

    func testSideAxisFallsBackToTheAimWhenTheScreenAxisIsVertical() {
        // A phone rolled fully onto its side would hand over a vertical
        // "right"; there is nothing horizontal to recover from it, so the axis
        // comes from the aim instead.
        let rolled = TossController.CameraBasis(
            position: [0, 1, 0],
            forward: [0, 0, -1],
            right: [0, 1, 0]
        )
        XCTAssertEqual(rolled.sideAxis.x, 1, accuracy: 1e-5)
        XCTAssertEqual(rolled.sideAxis.y, 0, accuracy: 1e-5)
        XCTAssertEqual(rolled.sideAxis.z, 0, accuracy: 1e-5)
    }

    func testSideAxisIsDefinedEvenForAnEntirelyDegenerateBasis() {
        let broken = TossController.CameraBasis(position: .zero, forward: .zero, right: .zero)
        let side = broken.sideAxis
        XCTAssertTrue(side.x.isFinite && side.y.isFinite && side.z.isFinite)
        XCTAssertEqual(simd_length(side), 1, accuracy: 1e-5)
    }

    func testStraightDownAimStillHasADefinedSideAxis() {
        let overhead = TossController.CameraBasis(
            position: [0, 1, 0],
            forward: [0, -1, 0],
            right: [0, 1, 0]
        )
        let side = overhead.sideAxis
        XCTAssertTrue(side.x.isFinite && side.y.isFinite && side.z.isFinite)
        XCTAssertEqual(simd_length(side), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(side, TossController.worldUp), 0, accuracy: 1e-5)
    }

    func testDegenerateCameraBasisDoesNotProduceNaN() {
        let controller = TossController()
        let broken = TossController.CameraBasis(position: .zero, forward: .zero, right: .zero)
        let velocity = controller.launchVelocity(for: swipe(up: 200), camera: broken)

        XCTAssertTrue(velocity.x.isFinite && velocity.y.isFinite && velocity.z.isFinite)
        XCTAssertEqual(simd_length(velocity), controller.launchSpeed(for: swipe(up: 200)), accuracy: 1e-4)
    }

    // MARK: - Impulse

    func testImpulseIsVelocityScaledByBallMass() {
        let controller = TossController()
        let gesture = swipe(up: 220, sideways: 60)
        let velocity = controller.launchVelocity(for: gesture, camera: camera)
        let impulse = controller.impulse(for: gesture, camera: camera)

        XCTAssertEqual(impulse.x, velocity.x * tuning.ballMass, accuracy: 1e-6)
        XCTAssertEqual(impulse.y, velocity.y * tuning.ballMass, accuracy: 1e-6)
        XCTAssertEqual(impulse.z, velocity.z * tuning.ballMass, accuracy: 1e-6)
    }

    func testLaunchOriginSitsInFrontOfAndBelowTheCamera() {
        let controller = TossController()
        let origin = controller.launchOrigin(camera: camera)

        XCTAssertEqual(origin.z, camera.position.z - tuning.spawnForwardOffset, accuracy: 1e-5)
        XCTAssertEqual(origin.y, camera.position.y - tuning.spawnDownOffset, accuracy: 1e-5)
    }

    // MARK: - Gesture gate

    func testOnlyAnUpwardFlickCountsAsAToss() {
        let controller = TossController()
        XCTAssertTrue(controller.isToss(swipe(up: tuning.minimumUpwardTravel)))
        XCTAssertFalse(controller.isToss(swipe(up: tuning.minimumUpwardTravel - 1)))
        XCTAssertFalse(controller.isToss(swipe(sideways: 400)), "a sideways drag is aiming, not a toss")
        XCTAssertFalse(controller.isToss(swipe(up: -300)), "a downward drag is not a toss")
    }

    func testARejectedGestureDoesNotConsumeTheRateLimit() {
        var controller = TossController()
        XCTAssertEqual(controller.flick(swipe(up: 10), camera: camera, at: 0), .rejected(.notAToss))
        // The failed gesture must not have started the 0.3 s clock.
        guard case .launched = controller.flick(swipe(up: 200), camera: camera, at: 0.01) else {
            return XCTFail("a real toss right after a non-toss must still launch")
        }
    }

    // MARK: - Rate limiting (FR-006)

    func testLaunchesAreRateLimitedToTheMinimumInterval() {
        var controller = TossController()
        let gesture = swipe(up: 200)

        guard case .launched = controller.flick(gesture, camera: camera, at: 10) else {
            return XCTFail("the first toss must launch")
        }
        XCTAssertEqual(
            controller.flick(gesture, camera: camera, at: 10 + tuning.minimumLaunchInterval - 0.01),
            .rejected(.tooSoon)
        )
        guard case .launched = controller.flick(
            gesture,
            camera: camera,
            at: 10 + tuning.minimumLaunchInterval
        ) else {
            return XCTFail("a toss at exactly the interval must launch")
        }
        XCTAssertEqual(controller.liveBallCount, 2, "a rejected toss must not create a ball")
    }

    // MARK: - Live-ball cap (FR-006, SC-006)

    func testLiveBallsAreCappedAndTheCapFreesUpOnRetirement() {
        var controller = TossController()
        let gesture = swipe(up: 200)
        var launched: [TossController.BallID] = []

        for step in 0..<tuning.maximumLiveBalls {
            let outcome = controller.flick(gesture, camera: camera, at: Double(step))
            guard case .launched(let launch) = outcome else {
                return XCTFail("toss \(step) should have launched, got \(outcome)")
            }
            launched.append(launch.ball)
        }
        XCTAssertEqual(controller.liveBallCount, tuning.maximumLiveBalls)

        XCTAssertEqual(
            controller.flick(gesture, camera: camera, at: 100),
            .rejected(.tooManyLiveBalls)
        )

        controller.retire(launched[0])
        XCTAssertEqual(controller.liveBallCount, tuning.maximumLiveBalls - 1)
        guard case .launched = controller.flick(gesture, camera: camera, at: 101) else {
            return XCTFail("retiring a ball must free a slot")
        }
    }

    func testTheCapIsCheckedBeforeTheRateLimit() {
        var controller = TossController()
        let gesture = swipe(up: 200)
        for step in 0..<tuning.maximumLiveBalls {
            _ = controller.flick(gesture, camera: camera, at: Double(step))
        }
        // Immediately after the last launch both rules would refuse; the cap is
        // the honest reason to show the player.
        XCTAssertEqual(
            controller.flick(gesture, camera: camera, at: Double(tuning.maximumLiveBalls - 1)),
            .rejected(.tooManyLiveBalls)
        )
    }

    func testBallIdentifiersAreNeverReused() {
        var controller = TossController()
        var seen: Set<TossController.BallID> = []
        for step in 0..<20 {
            let outcome = controller.flick(swipe(up: 200), camera: camera, at: Double(step))
            if case .launched(let launch) = outcome {
                XCTAssertTrue(seen.insert(launch.ball).inserted, "id \(launch.ball) was reused")
                controller.retire(launch.ball)
            }
        }
        XCTAssertEqual(seen.count, 20)
    }

    // MARK: - Two-tier scoring (FR-005 amended at Gate 4, SC-002)

    /// Launches a ball and hands back its id.
    private func launchBall(
        _ controller: inout TossController,
        at now: TimeInterval = 0
    ) -> TossController.BallID {
        guard case .launched(let launch) = controller.flick(swipe(up: 200), camera: camera, at: now) else {
            XCTFail("expected a launch")
            return 0
        }
        return launch.ball
    }

    func testTouchingTheCupPaysOnePointExactlyOnce() {
        var controller = TossController()
        let ball = launchBall(&controller)

        XCTAssertFalse(controller.hasHit(ball))
        XCTAssertEqual(
            controller.registerHit(ball),
            TossController.Award(ball: ball, tier: .hit, points: tuning.hitPoints)
        )
        XCTAssertTrue(controller.hasHit(ball))
        XCTAssertTrue(controller.hasScored(ball))

        // A thrown ball rattles round twelve wall segments; only the first one
        // is worth anything.
        XCTAssertNil(controller.registerHit(ball))
        XCTAssertNil(controller.registerHit(ball))
    }

    func testLandingInsidePaysTenPointsExactlyOnce() {
        var controller = TossController()
        let ball = launchBall(&controller)

        XCTAssertFalse(controller.hasMade(ball))
        XCTAssertEqual(
            controller.registerMake(ball),
            TossController.Award(ball: ball, tier: .make, points: tuning.makePoints)
        )
        XCTAssertTrue(controller.hasMade(ball))
        XCTAssertNil(controller.registerMake(ball), "a ball cannot be made twice")
    }

    /// The heart of the owner's rule: a made ball is worth ten in total, not
    /// eleven. The hit is absorbed, whichever tier arrives first.
    func testTheMakeAbsorbsTheHitSoAMadeBallIsWorthTenInTotal() {
        var controller = TossController()

        // Hit first — the usual order: the ball clips the rim or the cup floor
        // on its way to settling.
        let hitFirst = launchBall(&controller, at: 0)
        let hit = controller.registerHit(hitFirst)
        let make = controller.registerMake(hitFirst)
        XCTAssertEqual(hit?.points, tuning.hitPoints)
        XCTAssertEqual(make?.points, tuning.makePoints - tuning.hitPoints)
        XCTAssertEqual((hit?.points ?? 0) + (make?.points ?? 0), tuning.makePoints)

        // Make first — a clean drop through the mouth, credited before the
        // contact event is processed. Same total, and the hit pays nothing.
        let makeFirst = launchBall(&controller, at: 1)
        let cleanMake = controller.registerMake(makeFirst)
        XCTAssertEqual(cleanMake?.points, tuning.makePoints)
        XCTAssertNil(controller.registerHit(makeFirst), "a made ball cannot also collect the hit")
    }

    func testTheTwoTiersHaveTheOwnersValues() {
        XCTAssertEqual(tuning.hitPoints, 1)
        XCTAssertEqual(tuning.makePoints, 10)
    }

    func testBallsScoreIndependentlyOfEachOther() {
        var controller = TossController()
        var ids: [TossController.BallID] = []
        for step in 0..<3 {
            ids.append(launchBall(&controller, at: Double(step)))
        }
        XCTAssertEqual(ids.count, 3)

        XCTAssertEqual(ids.compactMap { controller.registerHit($0) }.count, 3)
        XCTAssertEqual(ids.compactMap { controller.registerHit($0) }.count, 0)

        // One of them goes in; the other two keep their single point.
        XCTAssertEqual(controller.registerMake(ids[1])?.points, tuning.makePoints - tuning.hitPoints)
        XCTAssertFalse(controller.hasMade(ids[0]))
        XCTAssertFalse(controller.hasMade(ids[2]))
        XCTAssertTrue(controller.hasHit(ids[0]))
    }

    func testAnUnknownOrRetiredBallCannotScoreEitherTier() {
        var controller = TossController()
        XCTAssertNil(controller.registerHit(999), "a ball that was never launched cannot score")
        XCTAssertNil(controller.registerMake(999))

        var controller2 = TossController()
        let ball = launchBall(&controller2)
        controller2.retire(ball)
        XCTAssertNil(controller2.registerHit(ball), "a culled ball cannot score late")
        XCTAssertNil(controller2.registerMake(ball))
        XCTAssertFalse(controller2.hasScored(ball))
    }

    /// Ids are never reused, but retiring a ball must still wipe its tiers, or
    /// a stale set would grow for the life of the session.
    func testRetiringABallForgetsItsTiers() {
        var controller = TossController()
        let ball = launchBall(&controller)
        _ = controller.registerHit(ball)
        _ = controller.registerMake(ball)
        XCTAssertTrue(controller.hasScored(ball))

        controller.retire(ball)
        XCTAssertFalse(controller.hasHit(ball))
        XCTAssertFalse(controller.hasMade(ball))
    }

    func testRetireAllClearsEveryBallAndTheRateLimit() {
        var controller = TossController()
        for step in 0..<3 {
            _ = controller.flick(swipe(up: 200), camera: camera, at: Double(step))
        }
        XCTAssertEqual(controller.liveBallCount, 3)

        controller.retireAll()
        XCTAssertEqual(controller.liveBallCount, 0)
        guard case .launched = controller.flick(swipe(up: 200), camera: camera, at: 2.0) else {
            return XCTFail("relocating the podium must reset the rate limit too")
        }
    }

    // MARK: - Culling (FR-006)

    func testAFreshMovingBallIsNotCulled() {
        let controller = TossController()
        XCTAssertNil(controller.cullReason(age: 0.5, restingFor: 0, heightAboveAnchor: 0.4))
    }

    func testABallAtRestIsCulledAfterTheRestWindow() {
        let controller = TossController()
        XCTAssertNil(controller.cullReason(age: 2, restingFor: 0.9, heightAboveAnchor: 0.1))
        XCTAssertEqual(
            controller.cullReason(age: 2, restingFor: tuning.restDuration, heightAboveAnchor: 0.1),
            .atRest
        )
    }

    func testAnOldBallIsCulledEvenWhileMoving() {
        let controller = TossController()
        XCTAssertEqual(
            controller.cullReason(age: tuning.maximumAge, restingFor: 0, heightAboveAnchor: 0.1),
            .expired
        )
    }

    func testABallBelowTheAnchorPlaneIsCulledImmediately() {
        let controller = TossController()
        XCTAssertNil(controller.cullReason(age: 0.1, restingFor: 0, heightAboveAnchor: -0.2))
        XCTAssertEqual(
            controller.cullReason(age: 0.1, restingFor: 0, heightAboveAnchor: tuning.minimumHeight - 0.01),
            .outOfBounds
        )
    }

    func testRestingTimeAccumulatesWhileStillAndResetsOnMovement() {
        let controller = TossController()
        var resting: TimeInterval = 0
        for _ in 0..<3 {
            resting = controller.restingDuration(previous: resting, speed: 0.01, delta: 0.2)
        }
        XCTAssertEqual(resting, 0.6, accuracy: 1e-6)

        resting = controller.restingDuration(previous: resting, speed: 1.5, delta: 0.2)
        XCTAssertEqual(resting, 0, "a ball that moves again is not at rest")
    }

    // MARK: - Power range (Phase 4, task 4.0a — Gate 3 rows 3.1/3.7)

    /// The complaint was reach: the player had to walk the phone closer. The
    /// fix is a materially higher ceiling, not a nudge.
    func testTheHardestFlickIsMuchStrongerThanPhase3s() {
        let controller = TossController()
        XCTAssertGreaterThanOrEqual(
            controller.launchSpeed(for: swipe(up: 600, duration: 0.08)),
            6.5,
            "a hard flick must reach the cup from ~2 m without the player moving"
        )
        XCTAssertGreaterThan(tuning.maxLaunchSpeed, 4.5, "Phase 3's ceiling was the problem")
    }

    /// …and the price of that ceiling must not be paid by ordinary throws:
    /// a middling flick still has to land in the 0.5–1.0 m band, which needs
    /// roughly 2.4–3.5 m/s.
    func testMidStrengthFlicksStayInTheSweetSpot() {
        let controller = TossController()
        let mid = controller.launchSpeed(for: swipe(up: 180, duration: 0.15)) // 1200 pt/s
        XCTAssertGreaterThan(mid, 2.4)
        XCTAssertLessThan(mid, 3.5)

        let easy = controller.launchSpeed(for: swipe(up: 150, duration: 0.15)) // 1000 pt/s
        XCTAssertGreaterThan(easy, 2.0)
        XCTAssertLessThan(easy, 3.0)
    }

    /// The shaped curve must still be a curve, not a staircase: speed rises
    /// with flick speed everywhere between the clamps.
    func testTheShapedCurveIsMonotonicAcrossTheWholeRange() {
        let controller = TossController()
        var previous: Float = 0
        for flick in stride(from: Float(300), through: 2600, by: 50) {
            let speed = controller.launchSpeed(for: swipe(up: flick * 0.1, duration: 0.1))
            XCTAssertGreaterThanOrEqual(speed, previous, "speed dipped at \(flick) pt/s")
            XCTAssertGreaterThanOrEqual(speed, tuning.minLaunchSpeed)
            XCTAssertLessThanOrEqual(speed, tuning.maxLaunchSpeed)
            previous = speed
        }
        XCTAssertEqual(previous, tuning.maxLaunchSpeed, accuracy: 1e-5)
    }

    /// `powerCurve` is the knob that re-spread the range; at 1 it must collapse
    /// back to Phase 3's straight line, so the change is provably a re-shaping
    /// and not a different formula.
    func testAPowerCurveOfOneIsTheOldLinearMapping() {
        var linear = TossController.Tuning()
        linear.powerCurve = 1
        let controller = TossController(tuning: linear)

        let flick: Float = 1200
        let t = (flick - linear.slowFlick) / (linear.fastFlick - linear.slowFlick)
        let expected = linear.minLaunchSpeed + t * (linear.maxLaunchSpeed - linear.minLaunchSpeed)
        XCTAssertEqual(
            controller.launchSpeed(for: swipe(up: flick * 0.1, duration: 0.1)),
            expected,
            accuracy: 1e-4
        )
    }

    func testTheCurveShapeSagsBelowTheStraightLine() {
        var linear = TossController.Tuning()
        linear.powerCurve = 1
        let gesture = swipe(up: 120, duration: 0.1) // 1200 pt/s

        let shaped = TossController().launchSpeed(for: gesture)
        let straight = TossController(tuning: linear).launchSpeed(for: gesture)
        XCTAssertLessThan(shaped, straight, "the curve exists to hold the middle down")
    }

    // MARK: - Rim rescue (Phase 4, task 4.0b — Gate 3 row 3.2)

    private var ballRadius: Float { tuning.ballRadius }
    /// The real geometry the AR side measures against.
    @MainActor
    private var rimOuterRadius: Float { PodiumBuilder.Metrics.cupRimOuterRadius }

    /// A ball balanced on the rim sits a full radius above it.
    @MainActor
    func testABallBalancedOnTheRimIsDetected() {
        let controller = TossController()
        let perched = TossController.CupPlacement(
            heightAboveRim: ballRadius,
            radialDistance: PodiumBuilder.Metrics.cupRimRingRadius
        )
        XCTAssertTrue(
            controller.isPerchedOnRim(perched, ballRadius: ballRadius, cupOuterRadius: rimOuterRadius)
        )
    }

    /// A ball that actually went in sits *below* the rim, and must be left
    /// alone — it has scored and the ordinary rest-cull should remove it.
    @MainActor
    func testABallRestingInsideTheCupIsNotTreatedAsPerched() {
        let controller = TossController()
        // Centre = cup floor thickness + radius, measured against the rim.
        let inside = TossController.CupPlacement(
            heightAboveRim: PodiumBuilder.Metrics.cupFloorThickness + ballRadius
                - PodiumBuilder.Metrics.cupRimHeight,
            radialDistance: 0
        )
        XCTAssertLessThan(inside.heightAboveRim, 0, "a ball in the cup is below the rim")
        XCTAssertFalse(
            controller.isPerchedOnRim(inside, ballRadius: ballRadius, cupOuterRadius: rimOuterRadius)
        )
    }

    @MainActor
    func testABallRestingElsewhereInTheSceneIsNotTreatedAsPerched() {
        let controller = TossController()
        // Right height, but way off to the side — on a step, or on the table.
        let besideTheCup = TossController.CupPlacement(
            heightAboveRim: ballRadius,
            radialDistance: rimOuterRadius + ballRadius + 0.01
        )
        XCTAssertFalse(
            controller.isPerchedOnRim(besideTheCup, ballRadius: ballRadius, cupOuterRadius: rimOuterRadius)
        )

        // Right place, but well below the mouth — under the cup, on the step.
        let belowTheCup = TossController.CupPlacement(heightAboveRim: -0.12, radialDistance: 0.01)
        XCTAssertFalse(
            controller.isPerchedOnRim(belowTheCup, ballRadius: ballRadius, cupOuterRadius: rimOuterRadius)
        )
    }

    /// The two cases have to be separated with margin on both sides, or a ball
    /// in the cup gets shoved out of it.
    @MainActor
    func testTheRimThresholdSitsBetweenTheTwoRestingHeights() {
        let controller = TossController()
        let insideHeight = PodiumBuilder.Metrics.cupFloorThickness + ballRadius
            - PodiumBuilder.Metrics.cupRimHeight
        let perchedHeight = ballRadius
        let threshold = -ballRadius * tuning.rimGraceFraction

        XCTAssertLessThan(insideHeight, threshold - 0.005, "too little margin for a ball in the cup")
        XCTAssertGreaterThan(perchedHeight, threshold + 0.005, "too little margin for a ball on the rim")
        _ = controller
    }

    func testTheNudgeIsAHorizontalShoveWithADownwardBias() {
        let controller = TossController()
        for azimuth in stride(from: Float(0), to: 2 * .pi, by: 0.4) {
            let velocity = controller.rimNudgeVelocity(azimuth: azimuth)
            let horizontal = simd_length(SIMD2(velocity.x, velocity.z))
            XCTAssertEqual(horizontal, tuning.rimNudgeSpeed, accuracy: 1e-5)
            XCTAssertLessThan(velocity.y, 0, "the shove must commit the ball to falling")
            XCTAssertEqual(
                velocity.y,
                -tuning.rimNudgeSpeed * tuning.rimNudgeDownwardBias,
                accuracy: 1e-6
            )
        }
    }

    /// Opposite azimuths must mirror, so a random direction is as likely to
    /// drop the ball into the cup as out of it — which is what Gate 3 asked for.
    func testOppositeNudgesMirrorEachOther() {
        let controller = TossController()
        let right = controller.rimNudgeVelocity(azimuth: 0)
        let left = controller.rimNudgeVelocity(azimuth: .pi)
        XCTAssertEqual(right.x, -left.x, accuracy: 1e-5)
        XCTAssertEqual(right.y, left.y, accuracy: 1e-6)
    }

    func testTheNudgeImpulseIsTheNudgeVelocityTimesMass() {
        let controller = TossController()
        let velocity = controller.rimNudgeVelocity(azimuth: 1.1)
        let impulse = controller.rimNudgeImpulse(azimuth: 1.1)
        XCTAssertEqual(impulse.x, velocity.x * tuning.ballMass, accuracy: 1e-8)
        XCTAssertEqual(impulse.y, velocity.y * tuning.ballMass, accuracy: 1e-8)
        XCTAssertEqual(impulse.z, velocity.z * tuning.ballMass, accuracy: 1e-8)
    }

    /// The rescue is bounded: a ball cannot be nudged forever.
    func testNudgesAreCapped() {
        let controller = TossController()
        for count in 0..<tuning.maximumRimNudges {
            XCTAssertTrue(controller.mayNudgeOffRim(nudgesSoFar: count))
        }
        XCTAssertFalse(controller.mayNudgeOffRim(nudgesSoFar: tuning.maximumRimNudges))
        XCTAssertFalse(controller.mayNudgeOffRim(nudgesSoFar: tuning.maximumRimNudges + 5))
        XCTAssertGreaterThan(tuning.rimNudgeGrace, 0, "a nudged ball needs time for the shove to work")
    }

    // MARK: - Inside the cup (Phase 5, task 5.0a — Gate 4 DEFECT, SC-002)

    /// A ball in the middle of the cup, well below the rim and well within the
    /// wall: the only shape this rule is meant to accept.
    private func insidePlacement(
        depthBelowRim: Float = 0.024,
        radial: Float = 0,
        aboveFloor: Float = 0.035,
        interior: Float = 0.051
    ) -> TossController.CupPlacement {
        TossController.CupPlacement(
            heightAboveRim: -depthBelowRim,
            radialDistance: radial,
            heightAboveCupFloor: aboveFloor,
            interiorRadius: interior
        )
    }

    func testABallSittingInTheCupIsInside() {
        let controller = TossController()
        XCTAssertTrue(controller.isInsideCup(insidePlacement(), ballRadius: ballRadius))
    }

    /// The defect, as a unit test: a ball touching the cup's outer wall has its
    /// centre a full radius *beyond* the wall — ~9 cm from the axis where the
    /// rule allows ~2 — so it can never be inside, at any height, however hard
    /// it is thrown at the front of the cup.
    func testABallAgainstTheOutsideOfTheWallIsNeverInside() {
        let controller = TossController()
        for depth in stride(from: Float(0.001), through: 0.06, by: 0.005) {
            let placement = insidePlacement(
                depthBelowRim: depth,
                radial: 0.051 + 0.006 + ballRadius,
                aboveFloor: 0.065 - depth,
                interior: 0.051
            )
            XCTAssertFalse(
                controller.isInsideCup(placement, ballRadius: ballRadius),
                "outer-wall contact \(depth) m below the rim read as inside"
            )
        }
    }

    /// The lower front of the cup specifically — the position the owner scored
    /// from at Gate 4. Low on the wall, outside it, and the interior is
    /// narrowest down there.
    func testTheLowFrontOfTheCupIsNeverInside() {
        let controller = TossController()
        let lowFront = insidePlacement(
            depthBelowRim: 0.055,
            radial: 0.041 + 0.006 + ballRadius,
            aboveFloor: 0.004,
            interior: 0.041
        )
        XCTAssertFalse(controller.isInsideCup(lowFront, ballRadius: ballRadius))
    }

    func testABallBelowTheCupIsNotInside() {
        let controller = TossController()
        // On the stem or the step: right under the axis, but below the floor.
        let underneath = insidePlacement(radial: 0, aboveFloor: -0.02)
        XCTAssertFalse(controller.isInsideCup(underneath, ballRadius: ballRadius))
    }

    func testABallAtOrAboveTheRimIsNotInside() {
        let controller = TossController()
        let atTheRim = insidePlacement(depthBelowRim: 0, aboveFloor: 0.065, interior: 0.054)
        XCTAssertFalse(controller.isInsideCup(atTheRim, ballRadius: ballRadius))

        let perched = insidePlacement(depthBelowRim: -ballRadius, aboveFloor: 0.10, interior: 0.054)
        XCTAssertFalse(controller.isInsideCup(perched, ballRadius: ballRadius))
    }

    /// Only the *whole* ball counts as in. A ball whose centre is inside but
    /// whose body still sticks out through the wall line is on its way in or
    /// out, not landed.
    func testTheWholeBallHasToFitWithinTheWall() {
        let controller = TossController()
        let interior: Float = 0.051
        let justFits = insidePlacement(radial: interior - ballRadius, interior: interior)
        XCTAssertTrue(controller.isInsideCup(justFits, ballRadius: ballRadius))

        let stickingOut = insidePlacement(
            radial: interior - ballRadius + tuning.insideRadialTolerance + 0.002,
            interior: interior
        )
        XCTAssertFalse(controller.isInsideCup(stickingOut, ballRadius: ballRadius))
    }

    /// Inside and perched must be mutually exclusive, or the rim rescue would
    /// shove a ball that has just scored.
    func testInsideAndPerchedAreMutuallyExclusive() {
        let controller = TossController()
        for depth in stride(from: Float(-0.05), through: 0.06, by: 0.002) {
            let placement = insidePlacement(depthBelowRim: depth, radial: 0.005)
            let inside = controller.isInsideCup(placement, ballRadius: ballRadius)
            let perched = controller.isPerchedOnRim(
                placement,
                ballRadius: ballRadius,
                cupOuterRadius: 0.06
            )
            XCTAssertFalse(inside && perched, "a ball at \(depth) is both inside and perched")
        }
    }

    // MARK: - The dwell that turns "inside" into "landed"

    func testContainmentAccumulatesWhileInsideAndResetsOnLeaving() {
        let controller = TossController()
        var contained: TimeInterval = 0
        for _ in 0..<3 {
            contained = controller.containedDuration(previous: contained, isInside: true, delta: 1 / 60)
        }
        XCTAssertEqual(contained, 3.0 / 60, accuracy: 1e-9)

        contained = controller.containedDuration(previous: contained, isInside: false, delta: 1 / 60)
        XCTAssertEqual(contained, 0, "a ball that leaves the cup starts again")
    }

    /// A ball crossing the cup at speed cannot dwell: the region where it
    /// counts as inside is a few centimetres across, so it is gone within a
    /// frame or two — which is exactly the tunnelling case the defect fix has
    /// to reject.
    func testAFlyThroughNeverSettlesButARestingBallDoes() throws {
        let controller = TossController()
        var contained: TimeInterval = 0
        // Two frames inside, then out — a ball punched through the wall.
        for isInside in [true, true, false] {
            contained = controller.containedDuration(
                previous: contained,
                isInside: isInside,
                delta: 1 / 60
            )
            XCTAssertFalse(controller.hasSettledInside(containedFor: contained))
        }

        // A ball that stays put crosses the threshold within a frame of the
        // nominal dwell and stays across it. (Which side of the exact boundary
        // frame 6 lands on is at the mercy of accumulating 1/60 in binary; the
        // behaviour either side of it is not.)
        var settledAt: Int?
        for frame in 1...30 {
            contained = controller.containedDuration(previous: contained, isInside: true, delta: 1 / 60)
            let settled = controller.hasSettledInside(containedFor: contained)
            if settled, settledAt == nil { settledAt = frame }

            let elapsed = Double(frame) / 60
            if elapsed < tuning.insideDwell - 1.0 / 60 {
                XCTAssertFalse(settled, "frame \(frame) settled too early")
            }
            if elapsed > tuning.insideDwell + 1.0 / 60 {
                XCTAssertTrue(settled, "frame \(frame) has not settled yet")
            }
        }
        let crossing = try XCTUnwrap(settledAt, "a ball resting in the cup never settled")
        XCTAssertEqual(Double(crossing) / 60, tuning.insideDwell, accuracy: 1.0 / 60)
    }

    func testTheDwellIsShortEnoughToFeelInstantAndLongEnoughToFilter() {
        XCTAssertGreaterThanOrEqual(tuning.insideDwell, 3.0 / 60, "one stray frame must not score")
        XCTAssertLessThanOrEqual(tuning.insideDwell, 0.25, "the player would notice the delay")
    }

    // MARK: - Touch-anchored spawn (Phase 5, task 5.0c — FR-004 amended)

    /// The camera's screen basis for these tests: aiming along −Z, +X to the
    /// right of the screen and +Y up it.
    private func ray(right: Float, up: Float) -> TossController.TouchRay {
        TossController.TouchRay(
            origin: camera.position,
            direction: simd_normalize(SIMD3<Float>(right, up, -1))
        )
    }

    private func spawnOffset(_ touch: TossController.TouchRay?) -> SIMD3<Float> {
        TossController().launchOrigin(camera: camera, touch: touch) - camera.position
    }

    func testATouchInTheMiddleSpawnsOnTheAimAxis() {
        let offset = spawnOffset(ray(right: 0, up: 0))
        XCTAssertEqual(offset.x, 0, accuracy: 1e-5)
        XCTAssertEqual(offset.y, 0, accuracy: 1e-5)
        XCTAssertEqual(offset.z, -tuning.spawnForwardOffset, accuracy: 1e-5)
    }

    /// Each corner has to put the ball on its own side of the aim, and all four
    /// at the same depth — the finger moves the spawn sideways, never nearer.
    func testEachCornerSpawnsOnItsOwnSideAtTheSameDepth() {
        let corners: [(name: String, right: Float, up: Float)] = [
            ("top-left", -0.5, 0.8),
            ("top-right", 0.5, 0.8),
            ("bottom-left", -0.5, -0.8),
            ("bottom-right", 0.5, -0.8)
        ]
        for corner in corners {
            let offset = spawnOffset(ray(right: corner.right, up: corner.up))
            XCTAssertEqual(
                offset.z,
                -tuning.spawnForwardOffset,
                accuracy: 1e-5,
                "\(corner.name) changed the spawn depth"
            )
            XCTAssertEqual(
                offset.x.sign,
                corner.right.sign,
                "\(corner.name) spawned on the wrong side"
            )
            XCTAssertEqual(offset.y.sign, corner.up.sign, "\(corner.name) spawned at the wrong height")
            XCTAssertGreaterThan(
                simd_length(SIMD2(offset.x, offset.y)),
                0.05,
                "\(corner.name) barely moved — the spawn does not follow the finger"
            )
        }
        // Opposite corners mirror each other exactly.
        let topLeft = spawnOffset(ray(right: -0.5, up: 0.8))
        let bottomRight = spawnOffset(ray(right: 0.5, up: -0.8))
        XCTAssertEqual(topLeft.x, -bottomRight.x, accuracy: 1e-5)
        XCTAssertEqual(topLeft.y, -bottomRight.y, accuracy: 1e-5)
    }

    func testTheSidewaysOffsetIsClamped() {
        let offset = spawnOffset(ray(right: 3, up: 0))
        XCTAssertEqual(
            simd_length(SIMD2(offset.x, offset.y)),
            tuning.maxSpawnLateral,
            accuracy: 1e-5
        )
        XCTAssertEqual(offset.z, -tuning.spawnForwardOffset, accuracy: 1e-5)
    }

    /// A ray that points behind the player — a bad projection, or a touch
    /// outside the frustum — must still spawn the ball in front of them.
    func testARayPointingBackwardsStillSpawnsInFrontOfTheCamera() {
        let backwards = TossController.TouchRay(origin: camera.position, direction: [0, 0, 1])
        let offset = spawnOffset(backwards)
        XCTAssertLessThan(offset.z, 0, "the ball spawned behind the player")
        XCTAssertGreaterThanOrEqual(-offset.z, tuning.minSpawnDepth - 1e-5)
    }

    func testEverySpawnStaysInsideItsDepthAndOffsetBounds() {
        for right in stride(from: Float(-6), through: 6, by: 0.5) {
            for up in stride(from: Float(-6), through: 6, by: 0.5) {
                let offset = spawnOffset(ray(right: right, up: up))
                let depth = -offset.z
                XCTAssertGreaterThanOrEqual(depth, tuning.minSpawnDepth - 1e-4, "(\(right), \(up))")
                XCTAssertLessThanOrEqual(depth, tuning.maxSpawnDepth + 1e-4, "(\(right), \(up))")
                XCTAssertLessThanOrEqual(
                    simd_length(SIMD2(offset.x, offset.y)),
                    tuning.maxSpawnLateral + 1e-4,
                    "(\(right), \(up))"
                )
                XCTAssertTrue(offset.x.isFinite && offset.y.isFinite && offset.z.isFinite)
            }
        }
    }

    func testADegenerateRayFallsBackToTheAimAxis() {
        let broken = TossController.TouchRay(origin: camera.position, direction: .zero)
        let offset = spawnOffset(broken)
        XCTAssertEqual(offset.x, 0, accuracy: 1e-5)
        XCTAssertEqual(offset.y, 0, accuracy: 1e-5)
        XCTAssertEqual(offset.z, -tuning.spawnForwardOffset, accuracy: 1e-5)
    }

    /// No touch at all keeps the pre-Gate-4 spawn, so nothing regresses if the
    /// AR view cannot project the point.
    func testNoTouchKeepsTheFixedSpawn() {
        let controller = TossController()
        XCTAssertEqual(
            controller.launchOrigin(camera: camera, touch: nil),
            controller.launchOrigin(camera: camera)
        )
    }

    /// …and a real flick actually carries the touch through to the launch.
    func testAFlickSpawnsAtTheTouchPoint() {
        var controller = TossController()
        let touch = ray(right: 0.4, up: -0.7)
        guard case .launched(let launch) = controller.flick(
            swipe(up: 200),
            camera: camera,
            at: 0,
            touch: touch
        ) else {
            return XCTFail("expected a launch")
        }
        XCTAssertEqual(launch.origin, controller.launchOrigin(camera: camera, touch: touch))
        XCTAssertNotEqual(launch.origin, controller.launchOrigin(camera: camera))
        // The aim and the power are untouched by where the finger started.
        XCTAssertEqual(
            launch.velocity,
            controller.launchVelocity(for: swipe(up: 200), camera: camera)
        )
    }

    // MARK: - Tuning is the single knob for Gate 3

    func testTuningOverridesFlowThroughToTheLaunch() {
        var tweaked = TossController.Tuning()
        tweaked.minLaunchSpeed = 5
        tweaked.maxLaunchSpeed = 5
        tweaked.ballMass = 1
        var controller = TossController(tuning: tweaked)

        guard case .launched(let launch) = controller.flick(swipe(up: 200), camera: camera, at: 0) else {
            return XCTFail("expected a launch")
        }
        XCTAssertEqual(simd_length(launch.velocity), 5, accuracy: 1e-4)
        XCTAssertEqual(simd_length(launch.impulse), 5, accuracy: 1e-4)
    }
}
