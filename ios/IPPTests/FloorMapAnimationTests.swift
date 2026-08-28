import XCTest

@testable import IPP

/// Phase 5C task 5C.3: the pure maths behind the floor map's shimmer. The
/// entity-level behaviour is `FloorMapTests`; this pins the numbers the owner
/// will ask to tune.
final class FloorMapAnimationTests: XCTestCase {

    private let field = (0..<400).map { FloorMapAnimation.dot(index: $0) }

    // MARK: - Per-dot parameters

    func testADotIsDeterministicForItsIndexAndSeed() {
        XCTAssertEqual(FloorMapAnimation.dot(index: 7), FloorMapAnimation.dot(index: 7))
        XCTAssertEqual(
            FloorMapAnimation.dot(index: 7, seed: 42),
            FloorMapAnimation.dot(index: 7, seed: 42)
        )
    }

    func testDifferentDotsAndDifferentSeedsDiffer() {
        XCTAssertNotEqual(FloorMapAnimation.dot(index: 7), FloorMapAnimation.dot(index: 8))
        XCTAssertNotEqual(
            FloorMapAnimation.dot(index: 7, seed: 1),
            FloorMapAnimation.dot(index: 7, seed: 2)
        )
    }

    func testADotDependsOnlyOnItsOwnIndexSoInsertingAPinDoesNotReshuffleTheField() {
        // The generator is re-seeded per dot rather than run as one stream.
        // If it were a stream, dot 300 would change whenever dot 0 changed.
        let alone = FloorMapAnimation.dot(index: 300)
        let inSequence = (0...300).map { FloorMapAnimation.dot(index: $0) }.last
        XCTAssertEqual(alone, inSequence)
    }

    func testEveryDotsConstantsAreInsideTheirTuningRanges() {
        for (index, dot) in field.enumerated() {
            XCTAssertTrue(
                (FloorMapAnimation.Tuning.minPulsePeriod...FloorMapAnimation.Tuning.maxPulsePeriod)
                    .contains(dot.pulsePeriod), "dot \(index)"
            )
            XCTAssertTrue(
                (FloorMapAnimation.Tuning.minPulseAmplitude...FloorMapAnimation.Tuning.maxPulseAmplitude)
                    .contains(dot.pulseAmplitude), "dot \(index)"
            )
            XCTAssertTrue((0..<(2 * Float.pi)).contains(dot.pulsePhase), "dot \(index)")
            XCTAssertTrue(
                (FloorMapAnimation.Tuning.minDropoutCycle...FloorMapAnimation.Tuning.maxDropoutCycle)
                    .contains(dot.dropoutCycle), "dot \(index)"
            )
            XCTAssertTrue((0..<dot.dropoutCycle).contains(dot.dropoutStart), "dot \(index)")
            XCTAssertGreaterThan(dot.dropoutDuration, 0, "dot \(index)")
            XCTAssertLessThanOrEqual(
                dot.dropoutDuration, dot.dropoutCycle / 2,
                "a dot must spend most of its cycle present — dot \(index)"
            )
        }
    }

    func testTheDropoutShareLandsNearItsTuningValue() {
        let dropouts = field.filter(\.dropsOut).count
        let share = Double(dropouts) / Double(field.count)
        XCTAssertEqual(share, FloorMapAnimation.Tuning.dropoutFraction, accuracy: 0.06)
        XCTAssertGreaterThan(dropouts, 0, "nothing would ever blink")
        XCTAssertLessThan(share, 0.25, "too much of the map would be missing")
    }

    func testThePhasesAreSpreadSoTheFieldDoesNotPulseInUnison() {
        // Six buckets around the circle; a field that shimmered organically
        // must touch all of them.
        var buckets = Set<Int>()
        for dot in field {
            buckets.insert(Int(dot.pulsePhase / (2 * .pi) * 6))
        }
        XCTAssertGreaterThanOrEqual(buckets.count, 6)
    }

    // MARK: - Pulse

    func testTheScaleStaysInsideItsAmplitudeAndIsAlwaysPositive() {
        for (index, dot) in field.prefix(60).enumerated() {
            for time in stride(from: 0.0, through: 30.0, by: 0.05) {
                let scale = FloorMapAnimation.scale(dot, at: time)
                XCTAssertGreaterThanOrEqual(scale, 1 - dot.pulseAmplitude - 1e-5, "\(index)@\(time)")
                XCTAssertLessThanOrEqual(scale, 1 + dot.pulseAmplitude + 1e-5, "\(index)@\(time)")
                XCTAssertGreaterThan(scale, 0)
            }
        }
    }

    func testTheScaleActuallyReachesBothEndsOfItsSwing() {
        // A pulse that never grows or never shrinks is not a pulse.
        let dot = FloorMapAnimation.dot(index: 3)
        var lowest = Float.greatestFiniteMagnitude
        var highest = -Float.greatestFiniteMagnitude
        for time in stride(from: 0.0, through: dot.pulsePeriod, by: 0.01) {
            let scale = FloorMapAnimation.scale(dot, at: time)
            lowest = min(lowest, scale)
            highest = max(highest, scale)
        }
        XCTAssertEqual(lowest, 1 - dot.pulseAmplitude, accuracy: 0.01)
        XCTAssertEqual(highest, 1 + dot.pulseAmplitude, accuracy: 0.01)
    }

    func testThePulseRepeatsAfterExactlyOnePeriod() {
        let dot = FloorMapAnimation.dot(index: 11)
        for time in stride(from: 0.0, through: 2.0, by: 0.13) {
            XCTAssertEqual(
                FloorMapAnimation.scale(dot, at: time),
                FloorMapAnimation.scale(dot, at: time + dot.pulsePeriod),
                accuracy: 1e-4
            )
        }
    }

    func testAPulseIsGentleEnoughToReadAsBreathingRatherThanStrobing() {
        // The owner asked for "slightly animated". Bounds on the tuning so a
        // later edit cannot quietly turn the map into a disco floor.
        XCTAssertGreaterThanOrEqual(FloorMapAnimation.Tuning.minPulsePeriod, 1.0)
        XCTAssertLessThanOrEqual(FloorMapAnimation.Tuning.maxPulseAmplitude, 0.5)
    }

    // MARK: - Dropout

    func testADotThatNeverDropsOutIsAlwaysFullyVisible() {
        guard let steady = field.first(where: { !$0.dropsOut }) else {
            return XCTFail("every dot drops out")
        }
        for time in stride(from: 0.0, through: 120.0, by: 0.1) {
            XCTAssertEqual(FloorMapAnimation.visibility(steady, at: time), 1, "t=\(time)")
        }
    }

    func testADroppingDotFadesOutHoldsAtNothingAndFadesBack() {
        guard let dot = field.first(where: { $0.dropsOut }) else {
            return XCTFail("no dot drops out")
        }
        let fade = min(FloorMapAnimation.Tuning.fadeDuration, dot.dropoutDuration / 2)

        // Just before its turn: fully present.
        XCTAssertEqual(FloorMapAnimation.visibility(dot, at: dot.dropoutStart - 0.01), 1, accuracy: 1e-3)
        // Mid fade-out: partly there.
        let fadingOut = FloorMapAnimation.visibility(dot, at: dot.dropoutStart + fade / 2)
        XCTAssertGreaterThan(fadingOut, 0.2)
        XCTAssertLessThan(fadingOut, 0.8)
        // Middle of the dropout: gone.
        XCTAssertEqual(
            FloorMapAnimation.visibility(dot, at: dot.dropoutStart + dot.dropoutDuration / 2),
            0, accuracy: 1e-6
        )
        // Mid fade-back: partly there again.
        let fadingIn = FloorMapAnimation.visibility(
            dot, at: dot.dropoutStart + dot.dropoutDuration - fade / 2
        )
        XCTAssertGreaterThan(fadingIn, 0.2)
        XCTAssertLessThan(fadingIn, 0.8)
        // After: back for good, until the next cycle.
        XCTAssertEqual(
            FloorMapAnimation.visibility(dot, at: dot.dropoutStart + dot.dropoutDuration + 0.01),
            1, accuracy: 1e-3
        )
    }

    func testVisibilityIsAlwaysABlendableFraction() {
        for dot in field.prefix(80) {
            for time in stride(from: -20.0, through: 120.0, by: 0.07) {
                let visibility = FloorMapAnimation.visibility(dot, at: time)
                XCTAssertGreaterThanOrEqual(visibility, 0)
                XCTAssertLessThanOrEqual(visibility, 1)
            }
        }
    }

    func testTheDropoutRepeatsOnItsCycle() {
        guard let dot = field.first(where: { $0.dropsOut }) else {
            return XCTFail("no dot drops out")
        }
        for time in stride(from: 0.0, through: 8.0, by: 0.29) {
            XCTAssertEqual(
                FloorMapAnimation.visibility(dot, at: time),
                FloorMapAnimation.visibility(dot, at: time + dot.dropoutCycle),
                accuracy: 1e-4
            )
        }
    }

    func testADotIsPresentForMostOfItsCycle() {
        // "Some can disappear for a few seconds" — occasionally missing, not
        // flickering. This is the guard on `minDropoutCycle` against
        // `maxDropoutDuration`; the two constants have to be tuned together.
        for dot in field.filter(\.dropsOut) {
            let present = (dot.dropoutCycle - dot.dropoutDuration) / dot.dropoutCycle
            XCTAssertGreaterThan(present, 0.72, "a dot should be missing, not mostly absent")
        }
    }

    // MARK: - Fade ramp indexing

    func testEveryVisibilityIndexesTheRampAndSpansInvisibleToFull() {
        for step in 0...100 {
            let level = FloorMapAnimation.fadeLevel(forVisibility: Float(step) / 100)
            XCTAssertTrue((0...FloorMapAnimation.Tuning.fadeSteps).contains(level), "\(step)")
        }
        XCTAssertEqual(FloorMapAnimation.fadeLevel(forVisibility: 0), 0)
        XCTAssertEqual(
            FloorMapAnimation.fadeLevel(forVisibility: 1),
            FloorMapAnimation.Tuning.fadeSteps
        )
    }

    func testTheFadeLevelSurvivesTheValuesThatWouldTrapAnIntConversion() {
        // `Swift.min`/`max` propagate NaN and `Int(nan)` traps — the crash the
        // Phase 5B crawl fade found. An unreadable visibility must fail *on*,
        // never off, so a bug cannot silently empty the map.
        XCTAssertEqual(
            FloorMapAnimation.fadeLevel(forVisibility: .nan),
            FloorMapAnimation.Tuning.fadeSteps
        )
        XCTAssertEqual(FloorMapAnimation.fadeLevel(forVisibility: -5), 0)
        XCTAssertEqual(
            FloorMapAnimation.fadeLevel(forVisibility: 5),
            FloorMapAnimation.Tuning.fadeSteps
        )
        XCTAssertEqual(
            FloorMapAnimation.fadeLevel(forVisibility: .infinity),
            FloorMapAnimation.Tuning.fadeSteps
        )
    }

    // MARK: - Degenerate dots

    func testADotWithNoPeriodOrNoCycleIsStillWellDefined() {
        var frozen = FloorMapAnimation.dot(index: 1)
        frozen.pulsePeriod = 0
        XCTAssertEqual(FloorMapAnimation.scale(frozen, at: 3), 1)

        var never = FloorMapAnimation.dot(index: 2)
        never.dropsOut = true
        never.dropoutCycle = 0
        XCTAssertEqual(FloorMapAnimation.visibility(never, at: 3), 1)

        var instant = FloorMapAnimation.dot(index: 3)
        instant.dropsOut = true
        instant.dropoutDuration = 0
        XCTAssertEqual(FloorMapAnimation.visibility(instant, at: 3), 1)
    }

    func testANonFiniteClockFreezesRatherThanCrashes() {
        let dot = FloorMapAnimation.dot(index: 5)
        for time in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(FloorMapAnimation.scale(dot, at: time), 1)
            XCTAssertEqual(FloorMapAnimation.visibility(dot, at: time), 1)
        }
    }
}
