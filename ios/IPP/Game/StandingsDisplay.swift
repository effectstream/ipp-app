import CoreText
import Foundation
import RealityKit
import UIKit
import simd

/// The podium's standings, as scenery (FR-013, added at Gate 5).
///
/// **Podium labels** for places #1/#2/#3: a name and a score floating in front
/// of each step in that step's medal colour, turned toward the player every
/// frame and riding the step as it breathes (FR-012). The names come entirely
/// from `SyntheticStandings` — the game reads no leaderboard and makes no
/// network request (FR-008, SC-005).
///
/// > The Star Wars crawl of places #4 and down that used to live here was
/// > **removed in Phase 5C** by owner decision: the space under the podium is
/// > now the floor map of data locations (`FloorMap`). Nothing of the crawl
/// > remains — its band, its fade ramp and its per-frame update are gone, and
/// > with them the only thing in this file that needed a clock.
///
/// Everything is procedural — text meshes generated from strings, no bundled
/// assets (FR-003) — and none of it has a `CollisionComponent` or a
/// `PhysicsBodyComponent`, so however it moves it cannot touch a ball.
///
/// ## Cost
///
/// Six text meshes are built once when the podium is placed and then only ever
/// moved: the labels never change their text, so a frame costs three transform
/// writes and three billboard rotations. Nothing is allocated in the update
/// loop.
@MainActor
enum StandingsDisplay {

    // MARK: - Entity names

    enum Name {
        static let labels = "standings_labels"
        static func label(rank: Int) -> String { "standing_label_\(rank)" }
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

    // MARK: - What the coordinator holds on to

    /// One podium label and the step it rides.
    struct PodiumLabel {
        let step: PodiumBuilder.Step
        let entity: Entity
    }

    /// Everything the update loop needs, built once at placement.
    final class Display {
        let labels: [PodiumLabel]

        init(labels: [PodiumLabel]) {
            self.labels = labels
        }
    }

    // MARK: - Building

    /// Hangs the three labels off the steps container and hands back the
    /// handles the update loop drives.
    ///
    /// The labels are children of the **steps container** (the same parent the
    /// trophy uses) so they inherit the podium's placement yaw and can be
    /// re-seated as their step breathes.
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

        return Display(labels: labels)
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
}
