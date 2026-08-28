import Foundation
import RealityKit
import simd

/// The podium breathes (FR-012, added at Gate 5 by owner request).
///
/// The three steps grow and shrink slowly and out of step with each other, so
/// the cup's height keeps changing and no two throws face the same target. Two
/// halves live here:
///
/// - the **feel constants and the height function**, which are pure arithmetic
///   and unit-tested off-device, in the same one-line-edit spirit as
///   `TossController.Tuning`;
/// - the **rung ladder**, a set of box meshes and collision shapes built once
///   for a range of heights, which is how the animation is played back.
///
/// ## Why a ladder rather than a scale
///
/// Stretching a step with `Entity.scale.y` would be free and perfectly smooth,
/// but it puts the whole feature on one unverifiable assumption: that RealityKit
/// applies a non-uniform entity scale to the entity's `CollisionComponent`
/// shapes as well as to its mesh. If it does not, every ball rests on a
/// phantom step at the original height — the "balls float or sink" failure the
/// task explicitly rules out — and the agent cannot settle the question off
/// device, because ARKit and the physics solver need real hardware.
///
/// So nothing is ever scaled. Each step's mesh *and* its collision shape are
/// swapped together for a pre-built pair of the right size, and the step is
/// re-seated so it still rests on the surface. The visual and the collider are
/// then the same object by construction, under any RealityKit behaviour.
///
/// The cost of that choice is quantisation: the height moves in
/// ``rungCount`` discrete rungs rather than continuously. At the constants
/// below that is ~3 mm per rung, which is invisible at arm's length (0.17° at
/// 1 m) and about a tenth of a ball radius, so a resting ball is nudged rather
/// than punched. The pairs are built once, lazily, and shared by every
/// placement — the update loop allocates nothing at all.
@MainActor
enum PodiumBreathing {

    // MARK: - Feel constants
    //
    // Everything about how the podium breathes is here, so "too fast", "too
    // subtle" or "too jumpy" is a one-line edit, exactly like
    // `TossController.Tuning`.

    /// Peak deviation of a step's height from its resting value, in metres.
    ///
    /// 2.5 cm against the 6/9/12 cm steps: the shortest step swings between
    /// 3.5 cm and 8.5 cm, so the movement is unmistakable and the podium never
    /// approaches zero height.
    static let amplitude: Float = 0.025

    /// Seconds for one full grow-and-shrink cycle, per step.
    ///
    /// The three are deliberately unequal and not small multiples of each
    /// other, so the steps drift in and out of phase for minutes instead of
    /// locking into a single pulsing block.
    static func period(for step: PodiumBuilder.Step) -> TimeInterval {
        switch step {
        case .gold: return 4.3
        case .silver: return 3.7
        case .bronze: return 5.1
        }
    }

    /// Where in its cycle each step starts, in radians. Thirds of a turn, so
    /// the podium is already asymmetric on the first frame.
    static func phase(for step: PodiumBuilder.Step) -> Float {
        switch step {
        case .gold: return 0
        case .silver: return 2 * .pi / 3
        case .bronze: return 4 * .pi / 3
        }
    }

    /// How many discrete heights each step can take. Odd, so the resting height
    /// is one of them.
    static let rungCount = 17

    // MARK: - The height function (pure)

    /// A step's height at `time` seconds of breathing.
    ///
    /// `time` is the game's *breathing clock*, not wall time: the coordinator
    /// stops advancing it while the trophy is being animated, so the podium
    /// freezes for a celebration and then carries on from where it was rather
    /// than jumping (FR-012: "the motion pauses during the make
    /// celebration/relocation").
    static func height(for step: PodiumBuilder.Step, at time: TimeInterval) -> Float {
        height(
            base: step.height,
            amplitude: amplitude,
            period: period(for: step),
            phase: phase(for: step),
            at: time
        )
    }

    /// The oscillator itself, with every input explicit so it can be asserted
    /// without reference to the podium's constants.
    static func height(
        base: Float,
        amplitude: Float,
        period: TimeInterval,
        phase: Float,
        at time: TimeInterval
    ) -> Float {
        guard period > 0, amplitude != 0 else { return base }
        let omega = 2 * Float.pi / Float(period)
        return base + amplitude * sin(omega * Float(time) + phase)
    }

    /// The band a step's height stays inside, for whatever `time`.
    static func bounds(for step: PodiumBuilder.Step) -> ClosedRange<Float> {
        (step.height - amplitude)...(step.height + amplitude)
    }

    // MARK: - The rung ladder

    /// One height a step can actually be drawn and collided at.
    struct Rung {
        let height: Float
        let mesh: MeshResource
        let shape: ShapeResource
    }

    /// The rungs for one step, evenly spaced across ``bounds(for:)``.
    struct Ladder {
        let rungs: [Rung]
        let lowest: Float
        let spacing: Float

        /// The rung closest to `height`, clamped to the ends. Pure — the tests
        /// drive it directly.
        func index(nearest height: Float) -> Int {
            guard rungs.count > 1, spacing > 0 else { return 0 }
            let raw = (height - lowest) / spacing
            guard raw.isFinite else { return 0 }
            return min(max(Int(raw.rounded()), 0), rungs.count - 1)
        }

        func rung(nearest height: Float) -> Rung {
            rungs[index(nearest: height)]
        }
    }

    /// One ladder per step, built on first use and then reused by every
    /// placement — `PodiumBuilder.Step` is a fixed set and the geometry never
    /// depends on where the podium was put.
    static let ladders: [PodiumBuilder.Step: Ladder] = {
        var built: [PodiumBuilder.Step: Ladder] = [:]
        for step in PodiumBuilder.Step.allCases {
            built[step] = makeLadder(for: step)
        }
        return built
    }()

    static func ladder(for step: PodiumBuilder.Step) -> Ladder? {
        ladders[step]
    }

    private static func makeLadder(for step: PodiumBuilder.Step) -> Ladder {
        let range = bounds(for: step)
        let count = max(rungCount, 2)
        let spacing = (range.upperBound - range.lowerBound) / Float(count - 1)
        let rungs = (0..<count).map { index -> Rung in
            let height = range.lowerBound + spacing * Float(index)
            return Rung(
                height: height,
                mesh: PodiumBuilder.stepMesh(height: height),
                shape: PodiumBuilder.stepShape(height: height)
            )
        }
        return Ladder(rungs: rungs, lowest: range.lowerBound, spacing: spacing)
    }
}
