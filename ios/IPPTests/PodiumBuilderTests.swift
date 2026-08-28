import RealityKit
import XCTest
import simd

@testable import IPP

/// A generator that always yields zero, so a "pick one of the others at
/// random" rule can be shown to hold even when the randomness does not help.
private struct AlwaysZeroGenerator: RandomNumberGenerator {
    mutating func next() -> UInt64 { 0 }
}

/// Throwaway harness used during Phase 2 to run `PodiumBuilder`'s structural
/// assertions for real on a Simulator. Phase 6a adds the permanent test target;
/// this file lives outside the repo on purpose.
@MainActor
final class PodiumBuilderTests: XCTestCase {

    func testSelfCheckReportsNoProblems() {
        XCTAssertEqual(PodiumBuilder.selfCheck(), [])
    }

    func testSceneContainsThreeStepsCupAndFloor() {
        let scene = PodiumBuilder.makeScene()

        for name in [
            PodiumBuilder.Name.goldStep,
            PodiumBuilder.Name.silverStep,
            PodiumBuilder.Name.bronzeStep,
            PodiumBuilder.Name.trophy,
            PodiumBuilder.Name.cup,
            PodiumBuilder.Name.cupFloor,
            PodiumBuilder.Name.floor
        ] {
            XCTAssertNotNil(scene.findEntity(named: name), "missing \(name)")
        }

        let wallSegments = (0..<PodiumBuilder.Metrics.cupWallSegments).compactMap {
            scene.findEntity(named: "\(PodiumBuilder.Name.cupWall)_\($0)")
        }
        XCTAssertEqual(wallSegments.count, PodiumBuilder.Metrics.cupWallSegments)
    }

    func testStepsHaveStaticPhysicsAndCollision() {
        let scene = PodiumBuilder.makeScene()
        for name in [
            PodiumBuilder.Name.goldStep,
            PodiumBuilder.Name.silverStep,
            PodiumBuilder.Name.bronzeStep,
            PodiumBuilder.Name.cupFloor,
            PodiumBuilder.Name.floor
        ] {
            let entity = try? XCTUnwrap(scene.findEntity(named: name))
            guard let entity else { continue }
            XCTAssertFalse(
                entity.components[CollisionComponent.self]?.shapes.isEmpty ?? true,
                "\(name) has no collision shapes"
            )
            XCTAssertEqual(
                entity.components[PhysicsBodyComponent.self]?.mode,
                .static,
                "\(name) is not a static body"
            )
        }
    }

    /// Phase 5 deleted the sensor volume: a contact cannot tell which side of
    /// the cup wall the ball is on, which is what produced the Gate 4 false
    /// positives. Nothing in the scene may be a trigger any more.
    func testTheSceneHasNoTriggerVolumeLeft() {
        let scene = PodiumBuilder.makeScene()
        var triggers: [String] = []
        func walk(_ entity: Entity) {
            if entity.components[CollisionComponent.self]?.mode == .trigger {
                triggers.append(entity.name)
            }
            entity.children.forEach(walk)
        }
        walk(scene)
        XCTAssertEqual(triggers, [], "scoring must not depend on a sensor any more")
    }

    /// The trophy hangs off the steps *container*, not off a step, so the
    /// difficulty ramp can slide it between steps with one animation inside one
    /// parent — and without ever leaving the podium's anchor, which is the
    /// anchor the balls' physics runs on.
    func testTrophyStandsOnTheGoldStepButHangsOffTheStepsContainer() throws {
        let scene = PodiumBuilder.makeScene()
        let trophy = try XCTUnwrap(scene.findEntity(named: PodiumBuilder.Name.trophy))

        XCTAssertEqual(trophy.parent?.name, PodiumBuilder.Name.steps)
        XCTAssertEqual(trophy.position.x, PodiumBuilder.Metrics.goldX, accuracy: 0.0001)
        XCTAssertEqual(trophy.position.y, PodiumBuilder.Metrics.goldHeight, accuracy: 0.0001)
        XCTAssertEqual(trophy.position, PodiumBuilder.Step.gold.trophyPosition)

        // The gold step's top face — the trophy must stand on it, not float.
        let gold = try XCTUnwrap(scene.findEntity(named: PodiumBuilder.Name.goldStep))
        XCTAssertEqual(
            trophy.position(relativeTo: gold.parent).y,
            gold.position.y + PodiumBuilder.Metrics.goldHeight / 2,
            accuracy: 0.0001
        )
    }

    // MARK: - Step picker (spec US3)

    /// The whole point of the ramp is that the cup is somewhere else next time.
    func testTheStepPickerNeverReturnsTheCurrentStep() {
        var generator = SystemRandomNumberGenerator()
        for current in PodiumBuilder.Step.allCases {
            for _ in 0..<200 {
                let next = PodiumBuilder.nextStep(after: current, using: &generator)
                XCTAssertNotEqual(next, current, "the cup stayed on \(current)")
            }
        }
    }

    /// …and it must be able to reach *both* of the others, or the ramp is a
    /// two-position toggle.
    func testTheStepPickerReachesEveryOtherStep() {
        var generator = SystemRandomNumberGenerator()
        for current in PodiumBuilder.Step.allCases {
            var seen: Set<PodiumBuilder.Step> = []
            for _ in 0..<200 {
                seen.insert(PodiumBuilder.nextStep(after: current, using: &generator))
            }
            XCTAssertEqual(seen, Set(PodiumBuilder.Step.allCases).subtracting([current]))
        }
    }

    /// A rigged generator proves the "never the current step" property is
    /// structural (the current step is removed from the pool) rather than a
    /// lucky draw: even a generator that always picks the first candidate
    /// cannot land on the current step.
    func testTheStepPickerHoldsWithADegenerateGenerator() {
        var generator = AlwaysZeroGenerator()
        for current in PodiumBuilder.Step.allCases {
            for _ in 0..<10 {
                XCTAssertNotEqual(PodiumBuilder.nextStep(after: current, using: &generator), current)
            }
        }
    }

    func testEveryStepPutsTheTrophyOnItsOwnTopFace() {
        for step in PodiumBuilder.Step.allCases {
            XCTAssertEqual(step.trophyPosition.y, step.height, accuracy: 0.0001)
            XCTAssertEqual(step.trophyPosition.x, step.x, accuracy: 0.0001)
            XCTAssertEqual(step.trophyPosition.z, 0, accuracy: 0.0001)
        }
        // The three steps really are three different places to aim at.
        let places = PodiumBuilder.Step.allCases.map { $0.trophyPosition }
        for (index, place) in places.enumerated() {
            for other in places[(index + 1)...] {
                XCTAssertGreaterThan(simd_distance(place, other), 0.02, "steps are too close to matter")
            }
        }
    }

    func testStepsRestOnTheAnchorPlane() {
        let scene = PodiumBuilder.makeScene()
        let expected: [(String, Float)] = [
            (PodiumBuilder.Name.goldStep, PodiumBuilder.Metrics.goldHeight),
            (PodiumBuilder.Name.silverStep, PodiumBuilder.Metrics.silverHeight),
            (PodiumBuilder.Name.bronzeStep, PodiumBuilder.Metrics.bronzeHeight)
        ]
        for (name, height) in expected {
            guard let step = scene.findEntity(named: name) else {
                XCTFail("missing \(name)")
                continue
            }
            XCTAssertEqual(step.position.y, height / 2, accuracy: 0.0001, "\(name)")
        }
    }

    // MARK: - Flared rim (Phase 4, task 4.0b — Gate 3 row 3.2)

    /// The cup must be a shallow cone, not a tube: wider at the mouth than at
    /// the floor, so its rim is a slope with nowhere for a ball to balance.
    func testTheCupWidensTowardItsMouth() {
        let metrics = PodiumBuilder.Metrics.self
        let atFloor = metrics.cupInnerRadius(atHeight: metrics.cupFloorThickness)
        let atMouth = metrics.cupInnerRadius(atHeight: metrics.cupRimHeight)

        XCTAssertGreaterThan(metrics.cupWallFlare, 0, "a flat rim is what balls balanced on")
        XCTAssertGreaterThan(atMouth, atFloor + 0.005, "the flare is too slight to matter")
        XCTAssertGreaterThan(atMouth, metrics.cupInnerRadius)
    }

    /// The flare leans the wall's base inward, so check it did not close the
    /// cup around the ball.
    func testTheFlaredWallStillLetsABallReachTheCupFloor() {
        let metrics = PodiumBuilder.Metrics.self
        let ballRadius = TossController.Tuning().ballRadius
        let restingHeight = metrics.cupFloorThickness + ballRadius
        XCTAssertGreaterThan(
            metrics.cupInnerRadius(atHeight: restingHeight),
            ballRadius + 0.005,
            "the ball cannot settle on the cup floor"
        )
    }

    /// The rim slope is only a fix if it beats the rim's friction — a ball must
    /// slide off it rather than grip.
    func testTheRimIsSteeperThanItIsGrippy() {
        let metrics = PodiumBuilder.Metrics.self
        let frictionAngle = atan(metrics.cupRimFriction)
        XCTAssertGreaterThan(
            metrics.cupWallFlare,
            frictionAngle,
            "a ball would still rest on the rim instead of sliding off"
        )
    }

    // MARK: - The scoring geometry (Gate 4 DEFECT, SC-002)

    /// The bridge between the built cup and the scoring rule, checked against
    /// the real metrics: a ball resting on the cup floor is inside, and a ball
    /// pressed against the *outside* of the wall is not — at any height on the
    /// wall, the low front included, which is where the owner produced false
    /// makes at Gate 4.
    func testOnlyABallActuallyInTheCupReadsAsInside() {
        let toss = TossController()
        let radius = toss.tuning.ballRadius
        let metrics = PodiumBuilder.Metrics.self

        let resting = SIMD3<Float>(0, metrics.cupFloorThickness + radius, 0)
        XCTAssertTrue(
            toss.isInsideCup(PodiumBuilder.cupPlacement(ofBallAt: resting), ballRadius: radius),
            "a ball sitting on the cup floor must count as a make"
        )

        for step in 0...24 {
            let height = Float(step) / 24 * metrics.cupRimHeight
            let outward = metrics.cupInnerRadius(atHeight: height) + metrics.cupWallThickness + radius
            for angle in stride(from: Float(0), to: 2 * .pi, by: .pi / 6) {
                let outside = SIMD3<Float>(outward * cos(angle), height, outward * sin(angle))
                XCTAssertFalse(
                    toss.isInsideCup(PodiumBuilder.cupPlacement(ofBallAt: outside), ballRadius: radius),
                    "a ball touching the cup's outside at \(height) m read as inside"
                )
            }
        }
    }

    /// A ball perched on the rim is not a make either — Gate 3's rim rescue and
    /// Gate 4's make rule must not disagree about the same ball.
    func testAPerchedBallIsPerchedAndNotInside() {
        let toss = TossController()
        let radius = toss.tuning.ballRadius
        let metrics = PodiumBuilder.Metrics.self
        let centre = SIMD3<Float>(metrics.cupRimRingRadius, metrics.cupRimHeight + radius, 0)
        let placement = PodiumBuilder.cupPlacement(ofBallAt: centre)

        XCTAssertFalse(toss.isInsideCup(placement, ballRadius: radius))
        XCTAssertTrue(
            toss.isPerchedOnRim(
                placement,
                ballRadius: radius,
                cupOuterRadius: metrics.cupRimOuterRadius
            )
        )
    }

    /// Every collidable part of the cup is what the +1 tier listens to, so the
    /// cup has to actually have collidable parts — and they must be ordinary
    /// physics bodies, not sensors.
    func testTheCupHasCollidablePartsForTheHitTier() throws {
        let scene = PodiumBuilder.makeScene()
        let cup = try XCTUnwrap(scene.findEntity(named: PodiumBuilder.Name.cup))

        var colliders: [Entity] = []
        func walk(_ entity: Entity) {
            if entity.components[CollisionComponent.self] != nil { colliders.append(entity) }
            entity.children.forEach(walk)
        }
        walk(cup)

        // Twelve wall segments plus the floor disc.
        XCTAssertEqual(colliders.count, PodiumBuilder.Metrics.cupWallSegments + 1)
        for collider in colliders {
            XCTAssertEqual(
                collider.components[CollisionComponent.self]?.mode,
                .default,
                "\(collider.name) would not produce a physical bounce"
            )
        }
    }

    /// The entities, not just the arithmetic: every wall segment must actually
    /// lean outward, and the ring must stay closed at the mouth where the flare
    /// has spread the segments furthest apart.
    func testEveryWallSegmentLeansOutward() throws {
        let scene = PodiumBuilder.makeScene()
        let metrics = PodiumBuilder.Metrics.self

        for index in 0..<metrics.cupWallSegments {
            let segment = try XCTUnwrap(scene.findEntity(named: "\(PodiumBuilder.Name.cupWall)_\(index)"))
            let outward = SIMD3<Float>(
                sin(2 * Float.pi * Float(index) / Float(metrics.cupWallSegments)),
                0,
                cos(2 * Float.pi * Float(index) / Float(metrics.cupWallSegments))
            )
            let localUp = segment.orientation.act(SIMD3<Float>(0, 1, 0))
            XCTAssertEqual(localUp.y, cos(metrics.cupWallFlare), accuracy: 1e-4, "segment \(index)")
            XCTAssertEqual(
                simd_dot(localUp, outward),
                sin(metrics.cupWallFlare),
                accuracy: 1e-4,
                "segment \(index) leans the wrong way"
            )
        }
    }

    func testTheWallRingHasNoGapsAtTheMouth() throws {
        let scene = PodiumBuilder.makeScene()
        let metrics = PodiumBuilder.Metrics.self
        let segment = try XCTUnwrap(scene.findEntity(named: "\(PodiumBuilder.Name.cupWall)_0"))
        let model = try XCTUnwrap(segment.components[ModelComponent.self])
        let width = model.mesh.bounds.extents.x
        let chordAtMouth = 2 * metrics.cupRimRingRadius * sin(.pi / Float(metrics.cupWallSegments))
        XCTAssertGreaterThan(width, chordAtMouth, "neighbouring segments leave a gap at the rim")
    }

    // MARK: - Ball (Phase 3)

    func testBallIsADynamicSphereWithCollision() {
        let ball = PodiumBuilder.makeBall(
            id: 7,
            radius: 0.035,
            mass: 0.045,
            friction: 0.6,
            restitution: 0.35
        )
        XCTAssertEqual(ball.name, "\(PodiumBuilder.Name.ballPrefix)7")
        XCTAssertNotNil(ball.components[ModelComponent.self], "the ball must be visible")
        XCTAssertFalse(ball.components[CollisionComponent.self]?.shapes.isEmpty ?? true)
        XCTAssertEqual(ball.components[PhysicsBodyComponent.self]?.mode, .dynamic)
        XCTAssertEqual(ball.components[PhysicsBodyComponent.self]?.massProperties.mass, 0.045)
        XCTAssertTrue(
            ball.components[PhysicsBodyComponent.self]?.isContinuousCollisionDetectionEnabled ?? false,
            "a fast ball would tunnel through the 6 mm cup wall without CCD"
        )
        XCTAssertNotNil(
            ball.components[PhysicsMotionComponent.self],
            "the culler reads the ball's velocity from the first frame"
        )
    }

    /// The +1 tier rests on the cup wall and the ball being able to see each
    /// other's collision filters. Assert it rather than discovering it on
    /// device.
    func testBallAndCupWallCollisionFiltersSeeEachOther() throws {
        let scene = PodiumBuilder.makeScene()
        let wall = try XCTUnwrap(scene.findEntity(named: "\(PodiumBuilder.Name.cupWall)_0"))
        let wallFilter = try XCTUnwrap(wall.components[CollisionComponent.self]).filter

        let ball = PodiumBuilder.makeBall(
            id: 1,
            radius: 0.035,
            mass: 0.045,
            friction: 0.6,
            restitution: 0.35
        )
        let ballFilter = try XCTUnwrap(ball.components[CollisionComponent.self]).filter

        XCTAssertNotEqual(
            wallFilter.mask.rawValue & ballFilter.group.rawValue,
            0,
            "the cup wall cannot see the ball"
        )
        XCTAssertNotEqual(
            ballFilter.mask.rawValue & wallFilter.group.rawValue,
            0,
            "the ball cannot see the cup wall"
        )
    }

    func testCylinderMeshIsGeneratedProcedurally() {
        let mesh = PodiumBuilder.cylinderMesh(height: 0.02, radius: 0.05, segments: 16)
        let parts = Array(mesh.contents.models).flatMap { Array($0.parts) }
        XCTAssertFalse(parts.isEmpty, "cylinder mesh has no parts")
        // 4n + 2 vertices and 12n indices for n = 16.
        let positions = parts.reduce(0) { $0 + $1.positions.count }
        let indices = parts.reduce(0) { $0 + ($1.triangleIndices?.count ?? 0) }
        XCTAssertEqual(positions, 4 * 16 + 2)
        XCTAssertEqual(indices, 12 * 16)
        XCTAssertTrue(parts.allSatisfy { $0.normals != nil }, "cylinder mesh has no normals")
    }
}
