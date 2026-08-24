import CoreText
import Foundation
import RealityKit
import UIKit
import simd

/// The podium's standings, as scenery (FR-013, added at Gate 5).
///
/// Two pieces, both fed entirely by `SyntheticStandings` — the game reads no
/// leaderboard and makes no network request (FR-008, SC-005):
///
/// - **Podium labels** for places #1/#2/#3: a name and a score floating in
///   front of each step in that step's medal colour, turned toward the player
///   every frame and riding the step as it breathes (FR-012).
/// - **The crawl** for places #4 and down: a Star Wars opening crawl running
///   away from the player and down through the floor beneath the podium, one
///   line per place, looping.
///
/// Everything is procedural — text meshes generated from strings, no bundled
/// assets (FR-003) — and none of it has a `CollisionComponent` or a
/// `PhysicsBodyComponent`, so however it moves it cannot touch a ball.
///
/// ## Cost
///
/// Ten text meshes are built once when the podium is placed and then only ever
/// moved: the podium labels never change, and the crawl recycles its lines by
/// wrapping them back to the near end rather than creating entities. Fading is
/// a swap between pre-built materials on a sixteen-step ramp, so a frame of
/// crawl is a handful of transform writes and, occasionally, one material
/// assignment. Nothing is allocated in the update loop.
@MainActor
enum StandingsDisplay {

    // MARK: - Entity names

    enum Name {
        static let labels = "standings_labels"
        static let crawl = "standings_crawl"
        static func label(rank: Int) -> String { "standing_label_\(rank)" }
        static func crawlLine(_ index: Int) -> String { "crawl_line_\(index)" }
    }

    // MARK: - Look constants
    //
    // Same spirit as `TossController.Tuning` and `PodiumBreathing`: if the
    // owner says "too small" or "too fast", it is one line here.

    enum Look {
        /// Em size of a podium name, in metres. ~9 mm of cap height, which
        /// subtends about half a degree at 1 m — comfortably readable.
        static let nameSize: Float = 0.013
        /// Em size of the score under the name.
        static let pointsSize: Float = 0.0095
        /// Gap between the two lines of a label.
        static let lineGap: Float = 0.003
        /// How far above the step's top face the label floats.
        static let labelLift: Float = 0.022
        /// How far in front of the step's front face the label hangs, so it
        /// never fights the trophy for the same air.
        static let labelForward: Float = PodiumBuilder.Metrics.stepDepth / 2 + 0.015
        /// Depth of the text extrusion. Just enough to catch a highlight.
        static let extrusion: Float = 0.0012
        /// Font size the meshes are generated at before being scaled down.
        /// Core Text tessellates glyphs badly at hundredths of a point, so the
        /// text is built big and shrunk.
        static let designFontSize: CGFloat = 0.2
    }

    /// The crawl's geometry and motion (FR-013).
    ///
    /// The band is a straight line in the podium's own frame: it starts just in
    /// front of the podium at surface height and runs **away from the player
    /// and downward**, so the text sinks through the floor plane as it recedes.
    /// Perspective does the shrinking for free — the lines keep their real
    /// size, exactly like the flat crawl plane in the films.
    enum Crawl {
        /// How far below horizontal the band runs, in radians.
        static let tilt: Float = 20 * .pi / 180
        /// Length of the band, in metres — how far a line travels before it
        /// wraps back to the near end.
        static let length: Float = 1.6
        /// Where the band starts, in the podium root's frame: in front of the
        /// steps (+Z is the side the podium was turned toward at placement), a
        /// whisker above the surface so it does not z-fight with the floor.
        static let start = SIMD3<Float>(0, 0.004, 0.30)
        /// How fast the text marches away, in metres per second. At 0.09 m/s a
        /// line takes ~18 s to cross the band: slow enough to read, slow enough
        /// to feel like scenery rather than a ticker.
        static let speed: Float = 0.09
        /// Em size of a crawl line, in metres.
        static let textSize: Float = 0.024
        /// Fraction of the band spent fading in at the near end…
        static let fadeIn: Float = 0.10
        /// …and the fraction at which the fade out begins, so the text
        /// dissolves into the distance instead of vanishing.
        static let fadeOutStart: Float = 0.55
        /// How many discrete opacities the fade uses. Pre-built materials, one
        /// per level, so a fading line allocates nothing.
        static let fadeSteps = 16

        /// Unit vector along the band: away from the player, and down.
        static var direction: SIMD3<Float> {
            [0, -sin(tilt), -cos(tilt)]
        }

        /// The rotation that lays a line of text flat in the band.
        ///
        /// A text mesh is drawn in its own XY plane facing +Z. This rotation
        /// about the X axis sends its **up** (+Y) along ``direction`` — so the
        /// tops of the letters point away down the band, which is what makes it
        /// read as a crawl receding to a vanishing point — and its face (+Z) to
        /// the band's normal, tilted up toward the player.
        static var orientation: simd_quatf {
            simd_quatf(angle: -(.pi / 2 + tilt), axis: [1, 0, 0])
        }

        /// How far along the band line `index` sits at `time`, wrapping at the
        /// far end. Pure.
        ///
        /// At `time == 0` the lines are spread evenly over the band, so the
        /// crawl is already populated the moment the podium is placed rather
        /// than trickling in one line at a time.
        static func distance(index: Int, count: Int, at time: TimeInterval) -> Float {
            guard count > 0, length > 0, time.isFinite else { return 0 }
            let spacing = length / Float(count)
            let travelled = Float(max(time, 0)) * speed + Float(index) * spacing
            return travelled.truncatingRemainder(dividingBy: length)
        }

        /// Where that is, in the podium root's frame. Pure.
        static func position(atDistance distance: Float) -> SIMD3<Float> {
            start + direction * distance
        }

        /// How opaque a line is at that distance: fades up over the first
        /// ``fadeIn`` of the band, holds, then fades away to nothing at the far
        /// end. Pure, and always within 0…1.
        static func opacity(atDistance distance: Float) -> Float {
            guard length > 0, distance.isFinite else { return 0 }
            let fraction = min(max(distance / length, 0), 1)
            if fadeIn > 0, fraction < fadeIn {
                return fraction / fadeIn
            }
            if fraction > fadeOutStart, fadeOutStart < 1 {
                return max(0, (1 - fraction) / (1 - fadeOutStart))
            }
            return 1
        }

        /// The rung of the pre-built fade ramp an opacity lands on. Pure.
        ///
        /// The `isFinite` guard is not decoration: `Swift.min`/`max` propagate a
        /// NaN rather than clamping it, and `Int(nan)` traps — so without it a
        /// single bad frame time would crash the game rather than skip a fade.
        static func fadeLevel(forOpacity opacity: Float) -> Int {
            guard opacity.isFinite else { return 0 }
            let clamped = min(max(opacity, 0), 1)
            return min(max(Int((clamped * Float(fadeSteps)).rounded()), 0), fadeSteps)
        }
    }

    // MARK: - What the coordinator holds on to

    /// One podium label and the step it rides.
    struct PodiumLabel {
        let step: PodiumBuilder.Step
        let entity: Entity
    }

    /// One crawl line: the pivot that moves, and the model whose material
    /// carries the fade.
    final class CrawlLine {
        let pivot: Entity
        let model: ModelEntity
        var fadeLevel: Int = -1

        init(pivot: Entity, model: ModelEntity) {
            self.pivot = pivot
            self.model = model
        }
    }

    /// Everything the update loop needs, built once at placement.
    final class Display {
        let labels: [PodiumLabel]
        let lines: [CrawlLine]
        let fadeRamp: [UnlitMaterial]

        init(labels: [PodiumLabel], lines: [CrawlLine], fadeRamp: [UnlitMaterial]) {
            self.labels = labels
            self.lines = lines
            self.fadeRamp = fadeRamp
        }
    }

    // MARK: - Building

    /// Hangs the labels off the steps container and the crawl off the scene
    /// root, and hands back the handles the update loop drives.
    ///
    /// The labels are children of the **steps container** (the same parent the
    /// trophy uses) so they inherit the podium's placement yaw and can be
    /// re-seated as their step breathes. The crawl is a child of the **scene
    /// root** so it stays on the surface while the steps move.
    static func attach(to scene: Entity, standings: [SyntheticStandings.Entry]) -> Display {
        let podium = scene.findEntity(named: PodiumBuilder.Name.steps) ?? scene

        let labelRoot = Entity()
        labelRoot.name = Name.labels
        podium.addChild(labelRoot)

        var labels: [PodiumLabel] = []
        for (step, entry) in zip(podiumSteps, standings.prefix(podiumSteps.count)) {
            let label = makeLabel(for: entry, tint: tint(for: step))
            labelRoot.addChild(label)
            labels.append(PodiumLabel(step: step, entity: label))
            // Seated properly on the first update; this keeps it off the floor
            // for the frame before that.
            seat(label, on: step, height: step.height)
        }

        // The band's start and tilt live on this one entity, so a line only has
        // to slide along its parent's local +Y to travel down the band.
        let crawlRoot = Entity()
        crawlRoot.name = Name.crawl
        crawlRoot.position = Crawl.start
        crawlRoot.orientation = Crawl.orientation
        scene.addChild(crawlRoot)

        let fadeRamp = makeFadeRamp(color: PodiumBuilder.Medal.gold)
        var lines: [CrawlLine] = []
        for (offset, entry) in standings.dropFirst(podiumSteps.count).enumerated() {
            let pivot = Entity()
            pivot.name = Name.crawlLine(offset)
            let model = makeTextModel(
                SyntheticStandings.crawlLine(for: entry),
                size: Crawl.textSize,
                material: fadeRamp.last ?? UnlitMaterial(color: PodiumBuilder.Medal.gold)
            )
            pivot.addChild(model)
            crawlRoot.addChild(pivot)
            lines.append(CrawlLine(pivot: pivot, model: model))
        }

        return Display(labels: labels, lines: lines, fadeRamp: fadeRamp)
    }

    /// The three steps in podium order, so #1 lands on gold.
    static let podiumSteps: [PodiumBuilder.Step] = [.gold, .silver, .bronze]

    static func tint(for step: PodiumBuilder.Step) -> UIColor {
        switch step {
        case .gold: return PodiumBuilder.Medal.gold
        case .silver: return PodiumBuilder.Medal.silver
        case .bronze: return PodiumBuilder.Medal.bronze
        }
    }

    /// A two-line label: the short name over the score.
    static func makeLabel(for entry: SyntheticStandings.Entry, tint: UIColor) -> Entity {
        let label = Entity()
        label.name = Name.label(rank: entry.rank)

        let material = UnlitMaterial(color: tint)
        let name = makeTextModel(entry.shortName, size: Look.nameSize, material: material)
        let points = makeTextModel(
            SyntheticStandings.formattedPoints(entry.points),
            size: Look.pointsSize,
            material: material
        )
        name.position.y = (Look.nameSize + Look.lineGap) / 2
        points.position.y = -(Look.pointsSize + Look.lineGap) / 2

        label.addChild(name)
        label.addChild(points)
        return label
    }

    /// A line of text as a model entity whose **origin is the text's centre**.
    ///
    /// `MeshResource.generateText` puts the origin at the layout box's corner,
    /// which would make every rotation swing the text around its own left edge.
    /// Re-centring here means the caller can place, spin and billboard a label
    /// by its middle.
    static func makeTextModel(_ string: String, size: Float, material: UnlitMaterial) -> ModelEntity {
        let scale = size / Float(Look.designFontSize)
        let mesh = MeshResource.generateText(
            string,
            extrusionDepth: Look.extrusion / max(scale, 1e-5),
            font: .systemFont(ofSize: Look.designFontSize, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let model = ModelEntity(mesh: mesh, materials: [material])
        model.scale = .init(repeating: scale)
        // Transform order is translate ∘ scale, so the offset has to be scaled
        // too for the centre to land on the parent's origin.
        model.position = -mesh.bounds.center * scale
        return model
    }

    /// One material per fade level, built once. Level 0 is invisible, the last
    /// level is fully opaque.
    static func makeFadeRamp(color: UIColor) -> [UnlitMaterial] {
        (0...Crawl.fadeSteps).map { level in
            var material = UnlitMaterial(color: color)
            material.blending = .transparent(
                opacity: .init(floatLiteral: Float(level) / Float(Crawl.fadeSteps))
            )
            return material
        }
    }

    // MARK: - Per-frame updates

    /// Puts a label back on its step's top face. Called every frame, because
    /// the step is breathing under it (FR-012).
    static func seat(_ label: Entity, on step: PodiumBuilder.Step, height: Float) {
        label.position = [step.x, height + Look.labelLift, Look.labelForward]
    }

    /// Turns an entity to face the camera, yaw only, so text stays upright
    /// instead of rolling over when the player crouches.
    static func billboard(_ entity: Entity, toward camera: SIMD3<Float>) {
        let here = entity.position(relativeTo: nil)
        let dx = camera.x - here.x
        let dz = camera.z - here.z
        guard dx * dx + dz * dz > 1e-8 else { return }
        entity.setOrientation(simd_quatf(angle: atan2(dx, dz), axis: [0, 1, 0]), relativeTo: nil)
    }

    /// One frame of crawl: march every line along the band, wrap the ones that
    /// reached the end, and swap the fade material where the level changed.
    ///
    /// The band's start and tilt are baked into the crawl root's transform, so
    /// a line's local position is simply `distance` along the root's own +Y —
    /// which the rotation has already aimed away from the player and down. That
    /// keeps this to one vector write per line. ``Crawl/position(atDistance:)``
    /// is the same point stated in the podium's frame, for the tests.
    static func update(_ display: Display, at time: TimeInterval) {
        let count = display.lines.count
        guard count > 0 else { return }

        for (index, line) in display.lines.enumerated() {
            let distance = Crawl.distance(index: index, count: count, at: time)
            line.pivot.position = [0, distance, 0]

            let level = Crawl.fadeLevel(forOpacity: Crawl.opacity(atDistance: distance))
            guard level != line.fadeLevel, display.fadeRamp.indices.contains(level) else { continue }
            line.fadeLevel = level
            line.model.model?.materials = [display.fadeRamp[level]]
        }
    }
}
