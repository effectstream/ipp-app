import RealityKit
import XCTest
import simd

@testable import IPP

/// Phase 5B task 5B.3 (FR-013): the podium name labels. Whether they *look*
/// right is the owner's gate row; what is checked here is that they are built,
/// positioned, tinted and — above all — incapable of touching a ball.
///
/// **Phase 5C trimmed this suite.** The Star Wars crawl of places #4+ was
/// removed from the game by owner decision (the space under the podium is now
/// `FloorMap`), so the thirteen crawl cases went with it. What remains is the
/// label half, unchanged, plus one case asserting the crawl really is gone
/// rather than merely unused.
@MainActor
final class StandingsDisplayTests: XCTestCase {

    private func placedScene() -> (scene: Entity, display: StandingsDisplay.Display) {
        let scene = PodiumBuilder.makeScene()
        let display = StandingsDisplay.attach(to: scene, standings: SyntheticStandings.standings())
        return (scene, display)
    }

    private func descendants(of entity: Entity) -> [Entity] {
        entity.children.flatMap { [$0] + descendants(of: $0) }
    }

    // MARK: - What gets built

    func testThePodiumGetsExactlyThreeLabelsAndNothingElse() {
        let (_, display) = placedScene()

        XCTAssertEqual(display.labels.count, 3)
        XCTAssertEqual(display.labels.map(\.step), [.gold, .silver, .bronze])
    }

    func testTheCrawlIsGoneFromThePlacedScene() {
        // Phase 5C removed it. A leftover crawl root would mean the deletion
        // was cosmetic and the text is still marching under the floor map.
        let (scene, _) = placedScene()
        for name in ["standings_crawl", "crawl_line_0", "crawl_line_1"] {
            XCTAssertNil(scene.findEntity(named: name), "the crawl survived: \(name)")
        }
    }

    func testLabelsHangOffTheStepsContainerSoTheyInheritThePodiumsPlacement() {
        let (scene, _) = placedScene()
        guard let labelRoot = scene.findEntity(named: StandingsDisplay.Name.labels) else {
            return XCTFail("no label root")
        }
        XCTAssertEqual(labelRoot.parent?.name, PodiumBuilder.Name.steps)
    }

    func testEveryPieceOfSceneryIsInertNoCollisionNoPhysics() {
        // FR-013: "purely decorative". Nothing here may ever touch a ball.
        let (scene, _) = placedScene()
        guard let root = scene.findEntity(named: StandingsDisplay.Name.labels) else {
            return XCTFail("no label root")
        }
        for entity in [root] + descendants(of: root) {
            XCTAssertNil(entity.components[CollisionComponent.self], entity.name)
            XCTAssertNil(entity.components[PhysicsBodyComponent.self], entity.name)
        }
    }

    func testTheSceneryAddsNoCollidersToThePodiumAtAll() {
        // Stronger version of the above: the placed scene must have exactly the
        // colliders `PodiumBuilder` puts there, with or without the standings.
        func colliders(_ entity: Entity) -> Int {
            ([entity] + descendants(of: entity))
                .filter { $0.components[CollisionComponent.self] != nil }
                .count
        }
        let bare = PodiumBuilder.makeScene()
        let before = colliders(bare)
        _ = StandingsDisplay.attach(to: bare, standings: SyntheticStandings.standings())
        XCTAssertEqual(colliders(bare), before)
    }

    func testEachLabelCarriesItsNameAndItsScoreAsTwoLinesOfRealGeometry() {
        let (_, display) = placedScene()
        for label in display.labels {
            let models = descendants(of: label.entity).compactMap { $0 as? ModelEntity }
            XCTAssertEqual(models.count, 2, "a name and a score")
            for model in models {
                XCTAssertGreaterThan(
                    model.model?.mesh.bounds.extents.x ?? 0, 0,
                    "the text mesh is empty"
                )
            }
            // Name above, score below.
            let heights = models.map(\.position.y).sorted()
            XCTAssertLessThan(heights[0], heights[1])
        }
    }

    func testLabelsAreTintedWithTheirStepsMedalColour() {
        XCTAssertEqual(StandingsDisplay.tint(for: .gold), PodiumBuilder.Medal.gold)
        XCTAssertEqual(StandingsDisplay.tint(for: .silver), PodiumBuilder.Medal.silver)
        XCTAssertEqual(StandingsDisplay.tint(for: .bronze), PodiumBuilder.Medal.bronze)
    }

    func testATextModelIsCentredOnItsOwnOrigin() {
        // Otherwise every billboard rotation would swing the label around its
        // left edge.
        let model = StandingsDisplay.makeTextModel(
            "Dra. Ficticia",
            size: StandingsDisplay.Look.nameSize,
            material: UnlitMaterial(color: PodiumBuilder.Medal.gold)
        )
        let bounds = model.visualBounds(relativeTo: model.parent)
        XCTAssertEqual(bounds.center.x, 0, accuracy: 0.002)
        XCTAssertEqual(bounds.center.y, 0, accuracy: 0.002)
        // …and scaled to roughly the requested em size, not left at design size.
        XCTAssertLessThan(bounds.extents.y, StandingsDisplay.Look.nameSize * 2)
    }

    func testTextIsBuiltAtAHumanScale() {
        // The em size is in metres, so a wrong constant does not fail to
        // compile — it puts a three-metre name across the room. These bounds
        // are the "does this fit on a podium" check.
        let standings = SyntheticStandings.standings()
        let white = UnlitMaterial(color: .white)

        let name = StandingsDisplay.makeTextModel(
            standings[0].shortName,
            size: StandingsDisplay.Look.nameSize,
            material: white
        )
        let nameBounds = name.visualBounds(relativeTo: nil)
        print("label width \(nameBounds.extents.x) m, height \(nameBounds.extents.y) m")
        XCTAssertGreaterThan(nameBounds.extents.x, 0.03)
        XCTAssertLessThan(nameBounds.extents.x, 0.20, "wider than the whole podium")
        XCTAssertGreaterThan(nameBounds.extents.y, 0.005, "too small to read at a metre")
        XCTAssertLessThan(nameBounds.extents.y, 0.025)
    }

    // MARK: - Riding a breathing step (FR-012 × FR-013)

    func testALabelIsSeatedAboveAndInFrontOfItsStepsCurrentTopFace() {
        let label = Entity()
        for step in PodiumBuilder.Step.allCases {
            let range = PodiumBreathing.bounds(for: step)
            for height in [range.lowerBound, step.height, range.upperBound] {
                StandingsDisplay.seat(label, on: step, height: height)
                XCTAssertEqual(label.position.x, step.x, accuracy: 1e-6)
                XCTAssertGreaterThan(label.position.y, height, "the label floats above the step")
                XCTAssertEqual(
                    label.position.y - height,
                    StandingsDisplay.Look.labelLift,
                    accuracy: 1e-6
                )
                XCTAssertGreaterThan(
                    label.position.z, PodiumBuilder.Metrics.stepDepth / 2,
                    "in front of the step, so it never fights the trophy for the same air"
                )
            }
        }
    }

    // MARK: - Billboarding

    func testBillboardingTurnsALabelsFaceTowardTheCamera() {
        let label = Entity()
        label.position = [0, 0.2, 0]
        for angle in stride(from: Float(0), through: 350, by: 25) {
            let radians = angle * .pi / 180
            let camera = SIMD3<Float>(2 * sin(radians), 0.4, 2 * cos(radians))
            StandingsDisplay.billboard(label, toward: camera)

            let facing = label.orientation.act(SIMD3<Float>(0, 0, 1))
            let toCamera = simd_normalize(SIMD3<Float>(camera.x, 0, camera.z) - [0, 0, 0])
            XCTAssertEqual(facing.x, toCamera.x, accuracy: 1e-4, "\(angle)°")
            XCTAssertEqual(facing.z, toCamera.z, accuracy: 1e-4, "\(angle)°")
            XCTAssertEqual(facing.y, 0, accuracy: 1e-5, "yaw only — text must stay upright")
        }
    }

    func testBillboardingIgnoresACameraDirectlyAboveTheLabel() {
        let label = Entity()
        label.position = [0, 0.2, 0]
        let before = label.orientation
        StandingsDisplay.billboard(label, toward: [0, 3, 0])
        XCTAssertEqual(label.orientation.vector, before.vector)
    }
}
