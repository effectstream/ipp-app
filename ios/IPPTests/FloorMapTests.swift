import RealityKit
import XCTest
import simd

@testable import IPP

/// Phase 5C tasks 5C.2 and 5C.3: the built floor map. Whether it *looks* right
/// is the owner's gate rows 5C-g1/5C-g3; what is checked here is that it is
/// built, bounded, capped, captioned, animated — and, above all, incapable of
/// touching a ball.
///
/// **Task 5C.3 reshaped this suite.** The owner removed the plate and border,
/// so the three cases that asserted their geometry are gone; the dot, caption
/// and inertness cases stay, and the animation cases are new.
@MainActor
final class FloorMapTests: XCTestCase {

    private func descendants(of entity: Entity) -> [Entity] {
        entity.children.flatMap { [$0] + descendants(of: $0) }
    }

    private func dots(of display: FloorMap.Display) -> [Entity] {
        descendants(of: display.root).filter { $0.name.hasPrefix(FloorMap.Name.pinPrefix) }
    }

    private func sampleData(count: Int, isLive: Bool = true) -> FloorMapData {
        let pins = (0..<count).map { index in
            GeoPin(
                latitude: -33.05 + Double(index % 40) * 0.002,
                longitude: -71.60 + Double(index / 40) * 0.003
            )
        }
        return FloorMapData(pins: pins, isLive: isLive)
    }

    // MARK: - Inertness (FR-013: "must not interfere with physics or scoring")

    func testNothingInTheMapHasACollisionShapeOrAPhysicsBody() {
        let display = FloorMap.make(sampleData(count: 120))
        for entity in [display.root] + descendants(of: display.root) {
            XCTAssertNil(entity.components[CollisionComponent.self], entity.name)
            XCTAssertNil(entity.components[PhysicsBodyComponent.self], entity.name)
        }
    }

    func testAddingTheMapToThePodiumAddsNoColliders() {
        func colliders(_ entity: Entity) -> Int {
            ([entity] + descendants(of: entity))
                .filter { $0.components[CollisionComponent.self] != nil }
                .count
        }
        let scene = PodiumBuilder.makeScene()
        let before = colliders(scene)
        scene.addChild(FloorMap.make(sampleData(count: 200)).root)
        XCTAssertEqual(colliders(scene), before)
    }

    func testAnimatingTheMapNeverGrowsColliders() {
        // The shimmer writes transforms and materials every frame; none of that
        // may ever add a collider to the scene.
        let display = FloorMap.make(sampleData(count: 120))
        for time in stride(from: 0.0, through: 40.0, by: 0.5) {
            FloorMap.update(display, at: time)
        }
        for entity in [display.root] + descendants(of: display.root) {
            XCTAssertNil(entity.components[CollisionComponent.self], entity.name)
            XCTAssertNil(entity.components[PhysicsBodyComponent.self], entity.name)
        }
    }

    // MARK: - The plate is gone (task 5C.3)

    func testThereIsNoPlateOrBorderLeftUnderTheDots() {
        // The owner asked for the bounding box to go: the floor itself is the
        // map's background now. A leftover slab would mean the removal was
        // cosmetic.
        let display = FloorMap.make(sampleData(count: 60))
        for name in ["floor_map_plate", "floor_map_frame"] {
            XCTAssertNil(display.root.findEntity(named: name), "\(name) survived")
        }
        // Every model in the subtree is either a dot or the caption's text.
        let caption = display.root.findEntity(named: FloorMap.Name.caption)
        let captionModels = caption.map { descendants(of: $0) } ?? []
        let models = descendants(of: display.root).compactMap { $0 as? ModelEntity }
        for model in models {
            let isDot = model.name.hasPrefix(FloorMap.Name.pinPrefix)
            let isCaption = captionModels.contains { $0 === model }
            XCTAssertTrue(isDot || isCaption, "unexpected geometry: \(model.name)")
        }
    }

    // MARK: - Geometry

    func testTheFieldSitsAboveTheFloorPlaneSoItCannotZFightIt() {
        // PodiumBuilder's invisible collider has its top face at y = 0.
        let display = FloorMap.make(sampleData(count: 20))
        XCTAssertGreaterThan(display.root.position.y, 0)
        XCTAssertLessThan(display.root.position.y, 0.01, "it is a map on the floor, not a table")
    }

    func testTheFieldIsBigEnoughToSurroundThePodiumAndSmallEnoughForADesk() {
        let podiumWidth = PodiumBuilder.Metrics.stepWidth * 3
        XCTAssertGreaterThan(FloorMap.Look.side, podiumWidth * 2, "the map has to read as under it")
        XCTAssertLessThanOrEqual(FloorMap.Look.side, 1.2)
    }

    func testEveryDotLandsInTheFieldWithItsInsetRespected() {
        let display = FloorMap.make(sampleData(count: 400))
        let limit = FloorMap.Look.side / 2 - FloorMap.Look.inset + 1e-4

        XCTAssertFalse(dots(of: display).isEmpty)
        for dot in dots(of: display) {
            XCTAssertLessThanOrEqual(abs(dot.position.x), limit, dot.name)
            XCTAssertLessThanOrEqual(abs(dot.position.z), limit, dot.name)
            XCTAssertGreaterThan(dot.position.y, 0, "dots float above the anchor plane")
        }
    }

    func testTheDotCountIsCappedHoweverManyPinsArrive() {
        // The seeded backend returns ~960; the scene must not grow 960
        // entities for a field a metre across.
        let display = FloorMap.make(sampleData(count: 960))
        XCTAssertEqual(dots(of: display).count, FloorMap.Look.maxDots)
        XCTAssertEqual(display.dots.count, FloorMap.Look.maxDots)
        XCTAssertEqual(display.motion.count, FloorMap.Look.maxDots)
        XCTAssertEqual(display.density.count, FloorMap.Look.maxDots)
    }

    func testASmallPinSetDrawsEveryPin() {
        let display = FloorMap.make(sampleData(count: 37))
        XCTAssertEqual(dots(of: display).count, 37)
    }

    func testAnEmptyMapIsStillACaptionRatherThanNothing() {
        let display = FloorMap.make(FloorMapData.none)
        XCTAssertNotNil(display.root.findEntity(named: FloorMap.Name.caption))
        XCTAssertTrue(dots(of: display).isEmpty)
        // …and animating an empty field is a no-op, not a crash.
        FloorMap.update(display, at: 12.5)
    }

    func testASinglePinDrawsOneDotInTheMiddle() {
        let display = FloorMap.make(
            FloorMapData(pins: [GeoPin(latitude: -33.05, longitude: -71.6)], isLive: true)
        )
        let placed = dots(of: display)
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed[0].position.x, 0, accuracy: 1e-5)
        XCTAssertEqual(placed[0].position.z, 0, accuracy: 1e-5)
    }

    // MARK: - Caption

    func testTheCaptionSaysWhereTheDataCameFromAndIsRealGeometry() {
        for isLive in [true, false] {
            let display = FloorMap.make(sampleData(count: 50, isLive: isLive))
            guard let caption = display.root.findEntity(named: FloorMap.Name.caption) else {
                return XCTFail("no caption")
            }
            let models = descendants(of: caption).compactMap { $0 as? ModelEntity }
            XCTAssertEqual(models.count, 1)
            XCTAssertGreaterThan(models[0].model?.mesh.bounds.extents.x ?? 0, 0)
        }
    }

    func testTheCaptionLiesOnTheFieldAndLeansTowardThePlayer() {
        let display = FloorMap.make(sampleData(count: 50))
        guard let caption = display.root.findEntity(named: FloorMap.Name.caption) else {
            return XCTFail("no caption")
        }
        // On the near edge, the side the podium was turned toward.
        XCTAssertGreaterThan(caption.position.z, FloorMap.Look.side / 2 - FloorMap.Look.inset)
        XCTAssertLessThan(caption.position.z, FloorMap.Look.side / 2)

        // Its face points mostly up out of the floor, tipped back at the player.
        let facing = caption.orientation.act(SIMD3<Float>(0, 0, 1))
        XCTAssertGreaterThan(facing.y, 0.9, "mostly up")
        XCTAssertGreaterThan(facing.z, 0, "leaning toward the player, not away")
        XCTAssertEqual(facing.x, 0, accuracy: 1e-6)

        // Text runs away from the player, so it reads the right way up.
        let textUp = caption.orientation.act(SIMD3<Float>(0, 1, 0))
        XCTAssertLessThan(textUp.z, 0)
    }

    func testTheCaptionFitsInTheField() {
        let model = StandingsDisplay.makeTextModel(
            FloorMapProjection.caption(pinCount: 260, isLive: true),
            size: FloorMap.Look.captionSize,
            material: UnlitMaterial(color: .white)
        )
        let bounds = model.visualBounds(relativeTo: nil)
        print("caption width \(bounds.extents.x) m, height \(bounds.extents.y) m")
        XCTAssertGreaterThan(bounds.extents.x, 0.10, "too small to read at a metre")
        XCTAssertLessThan(bounds.extents.x, FloorMap.Look.side, "wider than the field")
    }

    // MARK: - Tint ramp

    func testTheRampCrossesEveryTintWithEveryFadeLevel() {
        let ramp = FloorMap.densityRamp()
        XCTAssertEqual(ramp.count, FloorMap.Look.densityStops)
        for row in ramp {
            XCTAssertEqual(row.count, FloorMapAnimation.Tuning.fadeSteps + 1)
        }
    }

    func testTheDensityRampRunsFromTheBrandTealToThePodiumGold() {
        XCTAssertEqual(FloorMap.blend(PodiumBuilder.Medal.ball, PodiumBuilder.Medal.gold, 0),
                       PodiumBuilder.Medal.ball)
        XCTAssertEqual(FloorMap.blend(PodiumBuilder.Medal.ball, PodiumBuilder.Medal.gold, 1),
                       PodiumBuilder.Medal.gold)
    }

    func testBlendingClampsRatherThanExtrapolating() {
        // Compared component-wise: `blend` always returns an sRGB colour, and
        // `UIColor.black`/`.white` are greyscale, so `==` on the objects is
        // false even when the colours are identical.
        func rgba(_ color: UIColor) -> [CGFloat] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue, alpha]
        }

        XCTAssertEqual(rgba(FloorMap.blend(.black, .white, -5)), rgba(.black))
        XCTAssertEqual(rgba(FloorMap.blend(.black, .white, 5)), rgba(.white))
        XCTAssertEqual(rgba(FloorMap.blend(.black, .white, 0.5))[0], 0.5, accuracy: 1e-6)
    }

    // MARK: - The field is alive (task 5C.3)

    func testTheFieldIsAlreadyAnimatedTheFrameItIsBuilt() {
        // Otherwise the map snaps into motion a frame after the podium lands.
        let display = FloorMap.make(sampleData(count: 120))
        XCTAssertFalse(display.levels.contains(-1), "every dot got its opening rung")
        XCTAssertTrue(display.dots.contains { $0.scale.x != 1 }, "nothing is pulsing")
    }

    func testEveryDotStaysWithinItsPulseBoundsForeverAndKeepsItsPlace() {
        let display = FloorMap.make(sampleData(count: 80))
        let origins = display.dots.map(\.position)

        for time in stride(from: 0.0, through: 90.0, by: 0.37) {
            FloorMap.update(display, at: time)
            for (index, dot) in display.dots.enumerated() {
                let amplitude = display.motion[index].pulseAmplitude
                XCTAssertGreaterThanOrEqual(dot.scale.x, 1 - amplitude - 1e-5, "t=\(time)")
                XCTAssertLessThanOrEqual(dot.scale.x, 1 + amplitude + 1e-5, "t=\(time)")
                XCTAssertEqual(dot.scale.x, dot.scale.y, accuracy: 1e-6, "uniform scale only")
                // A pulsing dot must not wander off its location.
                XCTAssertEqual(dot.position, origins[index], "t=\(time)")
            }
        }
    }

    func testTheMapNeverLooksEmptyHoweverThePhasesLineUp() {
        // The dropouts are staggered and only a minority of dots ever drop out;
        // if that ever stopped being true the map would visibly gutter.
        let display = FloorMap.make(sampleData(count: 260))
        for time in stride(from: 0.0, through: 200.0, by: 0.25) {
            FloorMap.update(display, at: time)
            let visible = display.dots.filter(\.isEnabled).count
            XCTAssertGreaterThan(
                Double(visible), Double(display.dots.count) * 0.8,
                "only \(visible)/\(display.dots.count) dots visible at t=\(time)"
            )
        }
    }

    func testSomeDotsDoActuallyVanishAndComeBack() {
        // The other half of the previous test: a field that never blinks would
        // pass "never empty" trivially.
        let display = FloorMap.make(sampleData(count: 260))
        var everHidden = Set<Int>()
        for time in stride(from: 0.0, through: 60.0, by: 0.25) {
            FloorMap.update(display, at: time)
            for (index, dot) in display.dots.enumerated() where !dot.isEnabled {
                everHidden.insert(index)
            }
        }
        XCTAssertGreaterThan(everHidden.count, 10, "nothing ever blinked out")

        // …and every one of them is visible again at some point.
        var stillHidden = everHidden
        for time in stride(from: 0.0, through: 60.0, by: 0.25) {
            FloorMap.update(display, at: time)
            for index in everHidden where display.dots[index].isEnabled {
                stillHidden.remove(index)
            }
        }
        XCTAssertTrue(stillHidden.isEmpty, "these never came back: \(stillHidden)")
    }

    func testAFullyFadedDotIsDisabledRatherThanDrawnInvisible() {
        let display = FloorMap.make(sampleData(count: 260))
        for time in stride(from: 0.0, through: 60.0, by: 0.25) {
            FloorMap.update(display, at: time)
            for (index, dot) in display.dots.enumerated() {
                let level = FloorMapAnimation.fadeLevel(
                    forVisibility: FloorMapAnimation.visibility(display.motion[index], at: time)
                )
                XCTAssertEqual(dot.isEnabled, level > 0, "dot \(index) at t=\(time)")
            }
        }
    }

    func testTheFieldIsDeterministicForASeed() {
        // The same map must animate the same way every time it is placed.
        let a = FloorMap.make(sampleData(count: 60), seed: 99)
        let b = FloorMap.make(sampleData(count: 60), seed: 99)
        XCTAssertEqual(a.motion, b.motion)

        let c = FloorMap.make(sampleData(count: 60), seed: 100)
        XCTAssertNotEqual(a.motion, c.motion)
    }

    func testAnimationIsWellDefinedForAbsurdClocks() {
        let display = FloorMap.make(sampleData(count: 40))
        for time in [-5.0, 0.0, .greatestFiniteMagnitude, .infinity, .nan] as [TimeInterval] {
            FloorMap.update(display, at: time)
            for dot in display.dots {
                XCTAssertTrue(dot.scale.x.isFinite, "t=\(time)")
                XCTAssertGreaterThan(dot.scale.x, 0, "t=\(time)")
            }
        }
    }
}
