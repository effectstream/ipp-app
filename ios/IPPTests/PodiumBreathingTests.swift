import RealityKit
import XCTest
import simd

@testable import IPP

/// Phase 5B task 5B.1 (FR-012): the podium breathes.
///
/// The height function and the rung ladder are the whole of the feature that
/// can be checked without a camera — whether a *ball* then rests on a moving
/// step is the owner's gate row 5B-g2.
@MainActor
final class PodiumBreathingTests: XCTestCase {

    private let steps = PodiumBuilder.Step.allCases

    // MARK: - The height function

    func testEveryStepStaysInsideItsAmplitudeForever() {
        for step in steps {
            let range = PodiumBreathing.bounds(for: step)
            for tick in stride(from: 0.0, through: 120.0, by: 0.05) {
                let height = PodiumBreathing.height(for: step, at: tick)
                XCTAssertGreaterThanOrEqual(height, range.lowerBound - 1e-5, "\(step) at \(tick)")
                XCTAssertLessThanOrEqual(height, range.upperBound + 1e-5, "\(step) at \(tick)")
            }
        }
    }

    func testTheShortestStepNeverApproachesZeroHeight() {
        // A step that shrank to nothing would drop the trophy through the
        // table; bronze is the one with the least room.
        let bronze = PodiumBreathing.bounds(for: .bronze)
        XCTAssertGreaterThan(bronze.lowerBound, 0.02, "the podium must stay a podium")
    }

    func testEachStepPassesThroughItsRestingHeight() {
        for step in steps {
            let range = PodiumBreathing.bounds(for: step)
            XCTAssertEqual((range.lowerBound + range.upperBound) / 2, step.height, accuracy: 1e-6)
        }
    }

    func testTheThreeStepsBreatheOutOfPhase() {
        // Same instant, three different points in the cycle: the podium never
        // pulses as one block.
        let offsets = steps.map { PodiumBreathing.height(for: $0, at: 0) - $0.height }
        for (a, b) in [(0, 1), (0, 2), (1, 2)] {
            XCTAssertGreaterThan(
                abs(offsets[a] - offsets[b]), 0.005,
                "\(steps[a]) and \(steps[b]) start too close together"
            )
        }
    }

    func testTheThreeStepsHaveDifferentPeriods() {
        let periods = steps.map { PodiumBreathing.period(for: $0) }
        XCTAssertEqual(Set(periods).count, periods.count, "equal periods would lock the steps together")
        for period in periods {
            XCTAssertGreaterThanOrEqual(period, 3.0, "the breath must stay slow")
            XCTAssertLessThanOrEqual(period, 5.5)
        }
    }

    func testHeightRepeatsAfterExactlyOnePeriod() {
        for step in steps {
            let period = PodiumBreathing.period(for: step)
            for tick in stride(from: 0.0, through: 3.0, by: 0.25) {
                XCTAssertEqual(
                    PodiumBreathing.height(for: step, at: tick),
                    PodiumBreathing.height(for: step, at: tick + period),
                    accuracy: 1e-4,
                    "\(step) at \(tick)"
                )
            }
        }
    }

    func testAFrozenClockFreezesTheHeight() {
        // How the pause during a make celebration works: the coordinator stops
        // advancing the clock, so the same time gives the same height and the
        // breath resumes from the same phase rather than jumping.
        for step in steps {
            let held = PodiumBreathing.height(for: step, at: 7.5)
            XCTAssertEqual(PodiumBreathing.height(for: step, at: 7.5), held)
        }
    }

    func testDegenerateOscillatorsReturnTheRestingHeight() {
        XCTAssertEqual(
            PodiumBreathing.height(base: 0.09, amplitude: 0.02, period: 0, phase: 0, at: 3),
            0.09
        )
        XCTAssertEqual(
            PodiumBreathing.height(base: 0.09, amplitude: 0, period: 4, phase: 0, at: 3),
            0.09
        )
    }

    // MARK: - The rung ladder

    func testEachLadderSpansExactlyTheStepsBand() {
        for step in steps {
            guard let ladder = PodiumBreathing.ladder(for: step) else {
                return XCTFail("no ladder for \(step)")
            }
            let range = PodiumBreathing.bounds(for: step)
            XCTAssertEqual(ladder.rungs.count, PodiumBreathing.rungCount)
            XCTAssertEqual(ladder.rungs.first?.height ?? 0, range.lowerBound, accuracy: 1e-6)
            XCTAssertEqual(ladder.rungs.last?.height ?? 0, range.upperBound, accuracy: 1e-6)
            for (lower, higher) in zip(ladder.rungs, ladder.rungs.dropFirst()) {
                XCTAssertGreaterThan(higher.height, lower.height)
            }
        }
    }

    func testTheQuantisationIsFinerThanTheEyeAndThanTheBall() {
        let ballRadius = TossController.Tuning().ballRadius
        for step in steps {
            guard let ladder = PodiumBreathing.ladder(for: step) else {
                return XCTFail("no ladder for \(step)")
            }
            XCTAssertLessThan(ladder.spacing, 0.004, "a visible step in the animation")
            XCTAssertLessThan(
                ladder.spacing, ballRadius / 5,
                "a rung change must nudge a resting ball, not punch it"
            )
        }
    }

    func testTheLadderRoundsToTheNearestRungAndClampsAtTheEnds() {
        guard let ladder = PodiumBreathing.ladder(for: .gold) else {
            return XCTFail("no ladder for gold")
        }
        let range = PodiumBreathing.bounds(for: .gold)

        XCTAssertEqual(ladder.index(nearest: range.lowerBound), 0)
        XCTAssertEqual(ladder.index(nearest: range.upperBound), ladder.rungs.count - 1)
        XCTAssertEqual(ladder.index(nearest: range.lowerBound - 10), 0, "clamped below")
        XCTAssertEqual(ladder.index(nearest: range.upperBound + 10), ladder.rungs.count - 1)
        XCTAssertEqual(ladder.index(nearest: .nan), 0, "and a NaN cannot crash the loop")

        // Halfway between two rungs rounds to one of them, and never further
        // than half a rung away from what was asked for.
        for target in stride(from: range.lowerBound, through: range.upperBound, by: 0.0005) {
            let chosen = ladder.rung(nearest: target)
            XCTAssertLessThanOrEqual(abs(chosen.height - target), ladder.spacing / 2 + 1e-5)
        }
    }

    func testEveryHeightTheFunctionCanAskForIsOnTheLadder() {
        for step in steps {
            guard let ladder = PodiumBreathing.ladder(for: step) else {
                return XCTFail("no ladder for \(step)")
            }
            for tick in stride(from: 0.0, through: 20.0, by: 0.05) {
                let wanted = PodiumBreathing.height(for: step, at: tick)
                let index = ladder.index(nearest: wanted)
                XCTAssertTrue(ladder.rungs.indices.contains(index), "\(step) at \(tick)")
            }
        }
    }

    func testLaddersAreSharedRatherThanRebuiltPerPlacement() {
        // The meshes are the expensive part; two placements must not pay twice.
        let first = PodiumBreathing.ladder(for: .silver)
        let second = PodiumBreathing.ladder(for: .silver)
        XCTAssertEqual(first?.rungs.count, second?.rungs.count)
        XCTAssertTrue(first?.rungs.first?.mesh === second?.rungs.first?.mesh)
    }

    // MARK: - Applying a rung to a real step

    func testResizingAStepMovesItsMeshAndItsColliderTogether() {
        let step = PodiumBuilder.makeStep(
            name: PodiumBuilder.Name.goldStep,
            color: PodiumBuilder.Medal.gold,
            height: PodiumBuilder.Metrics.goldHeight,
            x: 0
        )
        guard let ladder = PodiumBreathing.ladder(for: .gold) else {
            return XCTFail("no ladder for gold")
        }
        let tall = ladder.rungs[ladder.rungs.count - 1]

        PodiumBuilder.resize(step, mesh: tall.mesh, shape: tall.shape, height: tall.height)

        XCTAssertEqual(step.position.y, tall.height / 2, accuracy: 1e-6, "still resting on the surface")
        XCTAssertTrue(step.model?.mesh === tall.mesh)
        XCTAssertEqual(step.collision?.shapes.count, 1)
        // The step is never scaled — that is the point of the ladder, since a
        // scaled collider is a RealityKit behaviour this cannot verify.
        XCTAssertEqual(step.scale, .one)

        let box = step.model?.mesh.bounds.extents ?? .zero
        XCTAssertEqual(box.y, tall.height, accuracy: 0.002, "the drawn box is the asked-for height")
    }

    func testAStepDrawnAtARungIsCollidableAndStatic() {
        let step = PodiumBuilder.makeStep(
            name: PodiumBuilder.Name.bronzeStep,
            color: PodiumBuilder.Medal.bronze,
            height: PodiumBuilder.Metrics.bronzeHeight,
            x: 0
        )
        guard let shortest = PodiumBreathing.ladder(for: .bronze)?.rungs.first else {
            return XCTFail("no ladder for bronze")
        }
        PodiumBuilder.resize(step, mesh: shortest.mesh, shape: shortest.shape, height: shortest.height)

        XCTAssertFalse(step.collision?.shapes.isEmpty ?? true)
        XCTAssertEqual(step.components[PhysicsBodyComponent.self]?.mode, .static)
    }

    // MARK: - What rides the step

    func testTheTrophyStandsOnWhateverHeightItsStepCurrentlyHas() {
        for step in steps {
            let range = PodiumBreathing.bounds(for: step)
            for height in [range.lowerBound, step.height, range.upperBound] {
                let place = step.trophyPosition(atHeight: height)
                XCTAssertEqual(place.y, height, accuracy: 1e-6)
                XCTAssertEqual(place.x, step.x, accuracy: 1e-6)
                XCTAssertEqual(place.z, 0, accuracy: 1e-6)
            }
        }
        // And the no-argument form is still the resting height.
        XCTAssertEqual(
            PodiumBuilder.Step.gold.trophyPosition,
            PodiumBuilder.Step.gold.trophyPosition(atHeight: PodiumBuilder.Step.gold.height)
        )
    }
}
