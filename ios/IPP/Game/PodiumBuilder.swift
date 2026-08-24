import Foundation
import RealityKit
import UIKit
import simd

/// Procedural assembly of the "Tiro al Trofeo" podium scene (FR-003).
///
/// Everything here is a pure function of constants: it builds and returns
/// `Entity` trees and never touches an `ARView`, an `ARSession` or any app
/// state. That is deliberate — RealityKit's entity/mesh layer works in the
/// Simulator even though ARKit does not, so the geometry can be built and
/// asserted on off-device. `selfCheck()` at the bottom is exactly that
/// assertion set; Phase 6a's test target will host it as real unit tests.
///
/// Units are metres, RealityKit's convention: +X right, +Y up, −Z away from the
/// player. The scene's origin sits **on the surface the player tapped**, so the
/// podium's feet and the invisible floor plane both live at y = 0.
///
/// No bundled 3D assets and no networking are involved (FR-003, FR-008).
@MainActor
enum PodiumBuilder {

    // MARK: - Entity names
    //
    // Stable names are the contract the game logic (and the tests) look things
    // up by — `findEntity(named:)` rather than index arithmetic.

    enum Name {
        static let root = "podium_scene"
        static let steps = "podium_steps"
        static let goldStep = "step_gold"
        static let silverStep = "step_silver"
        static let bronzeStep = "step_bronze"
        static let trophy = "trophy"
        static let cup = "cup"
        static let cupWall = "cup_wall"
        static let cupFloor = "cup_floor"
        static let floor = "floor"
        /// Balls are named `ball_<id>` so a scene dump stays readable; the game
        /// itself matches them by identity, not by name.
        static let ballPrefix = "ball_"
    }

    // MARK: - Dimensions

    enum Metrics {
        /// Footprint of a single step (square, in metres).
        static let stepWidth: Float = 0.10
        static let stepDepth: Float = 0.10

        /// Step heights — 12 / 9 / 6 cm, per the plan.
        static let goldHeight: Float = 0.12
        static let silverHeight: Float = 0.09
        static let bronzeHeight: Float = 0.06

        /// Silver sits left of gold, bronze right of gold, flush against it.
        static let goldX: Float = 0
        static let silverX: Float = -stepWidth
        static let bronzeX: Float = stepWidth

        /// Trophy: a small base and stem carrying an open cup.
        static let trophyBaseRadius: Float = 0.030
        static let trophyBaseHeight: Float = 0.010
        static let trophyStemRadius: Float = 0.008
        static let trophyStemHeight: Float = 0.030

        /// Inner radius of the cup. A Phase 3 ball is ~3.5 cm across, so a
        /// 10 cm mouth is a fair but not trivial target.
        static let cupInnerRadius: Float = 0.050
        static let cupWallThickness: Float = 0.006
        static let cupWallHeight: Float = 0.060
        static let cupFloorThickness: Float = 0.006
        /// Number of box segments approximating the cup's cylindrical wall.
        static let cupWallSegments = 12
        /// How far each wall segment leans **outward**, in radians (Gate 3 row
        /// 3.2). The cup is therefore a shallow cone rather than a tube: its
        /// mouth is wider than its floor, the inner face funnels a ball down
        /// into the cup, and — the point of the change — the rim has no level
        /// surface anywhere on it for a ball to balance on.
        ///
        /// 15° against the rim's friction of ``cupRimFriction`` (0.18, whose
        /// friction angle is ≈ 10°) means a ball landing on the rim always
        /// slides off instead of settling there and being silently culled.
        static let cupWallFlare: Float = 15 * .pi / 180
        /// Friction of the rim and inner wall. Deliberately slippery, so the
        /// flare above can do its job.
        static let cupRimFriction: Float = 0.18
        static let cupRimRestitution: Float = 0.18

        /// Invisible collision plane standing in for the real table or floor,
        /// so missed balls bounce on the surface instead of falling forever.
        static let floorExtent: Float = 3.0
        static let floorThickness: Float = 0.02

        // Derived cup geometry. The game's rim rule (`TossController`) is
        // written against these, so the numbers exist once.

        /// Radius of the circle the wall segments' centres sit on.
        static var cupRingRadius: Float { cupInnerRadius + cupWallThickness / 2 }
        /// That radius at the mouth, once the segments lean out.
        static var cupRimRingRadius: Float {
            cupRingRadius + (cupWallHeight / 2) * sin(cupWallFlare)
        }
        /// Outermost horizontal reach of the rim — the "is this ball anywhere
        /// near the cup" radius.
        static var cupRimOuterRadius: Float { cupRimRingRadius + cupWallThickness }
        /// Height of the top of the wall above the cup entity's own origin
        /// (which is the underside of the cup's floor disc).
        static var cupRimHeight: Float {
            cupFloorThickness + cupWallHeight / 2 + (cupWallHeight / 2) * cos(cupWallFlare)
        }

        /// Inner radius of the flared wall at `height` above the cup's origin —
        /// smallest at the floor, widest at the mouth.
        static func cupInnerRadius(atHeight height: Float) -> Float {
            let wallMidHeight = cupFloorThickness + cupWallHeight / 2
            return cupInnerRadius + (height - wallMidHeight) * tan(cupWallFlare)
        }

        /// Height of the whole trophy above the step it stands on.
        static var trophyHeight: Float {
            trophyBaseHeight + trophyStemHeight + cupRimHeight
        }
    }

    // MARK: - Steps as a value (spec US3)

    /// The three podium steps, as something the difficulty ramp can reason
    /// about without touching the scene graph.
    ///
    /// The trophy hangs off the **steps container**, not off a step, precisely
    /// so relocation is one `move(to:relativeTo:)` inside a single parent
    /// rather than a re-parent mid-animation — and so it never leaves the
    /// podium's anchor, which is the anchor the balls are simulated on.
    enum Step: String, CaseIterable {
        case gold
        case silver
        case bronze

        var entityName: String {
            switch self {
            case .gold: return Name.goldStep
            case .silver: return Name.silverStep
            case .bronze: return Name.bronzeStep
            }
        }

        var height: Float {
            switch self {
            case .gold: return Metrics.goldHeight
            case .silver: return Metrics.silverHeight
            case .bronze: return Metrics.bronzeHeight
            }
        }

        var x: Float {
            switch self {
            case .gold: return Metrics.goldX
            case .silver: return Metrics.silverX
            case .bronze: return Metrics.bronzeX
            }
        }

        /// Where the trophy stands when it is on this step, in the steps
        /// container's frame: centred on the step's top face.
        var trophyPosition: SIMD3<Float> { [x, height, 0] }
    }

    /// Picks the step the cup jumps to after a make (spec US3: "consecutive
    /// scores require re-aiming").
    ///
    /// It **cannot** return the step the cup is already on — that one is
    /// removed from the pool before the draw rather than being re-rolled away,
    /// so there is no unlucky path where the cup stays put.
    static func nextStep<G: RandomNumberGenerator>(
        after current: Step,
        using generator: inout G
    ) -> Step {
        let others = Step.allCases.filter { $0 != current }
        // `others` always has two elements, so the fallback is unreachable.
        return others.randomElement(using: &generator) ?? current
    }

    /// ``nextStep(after:using:)`` with the system generator.
    static func nextStep(after current: Step) -> Step {
        var generator = SystemRandomNumberGenerator()
        return nextStep(after: current, using: &generator)
    }

    // MARK: - Colors
    //
    // The exact `LeaderboardRow.medalColor` values, so the podium reads as the
    // leaderboard's top three (FR-003, FR-009).

    enum Medal {
        static let gold = UIColor(red: 0.95, green: 0.78, blue: 0.18, alpha: 1)
        static let silver = UIColor(red: 0.75, green: 0.78, blue: 0.82, alpha: 1)
        static let bronze = UIColor(red: 0.80, green: 0.50, blue: 0.20, alpha: 1)
        /// The ball wears the brand teal (`LinearGradient.ippBrand`'s light
        /// stop, `#13837E`) so it reads as the app's rather than as a stray
        /// object, and stays legible against gold and against most desks.
        static let ball = UIColor(red: 0x13 / 255, green: 0x83 / 255, blue: 0x7E / 255, alpha: 1)
    }

    // MARK: - Public assembly

    /// The whole placeable scene: the three-step podium with its trophy, plus
    /// the invisible floor collision plane. The root's origin is the point the
    /// player tapped on the detected surface.
    static func makeScene() -> Entity {
        let root = Entity()
        root.name = Name.root
        root.addChild(makePodium())
        root.addChild(makeFloor())
        return root
    }

    /// The visible podium: three steps plus the trophy on the tallest one.
    static func makePodium() -> Entity {
        let podium = Entity()
        podium.name = Name.steps

        podium.addChild(
            makeStep(
                name: Name.goldStep,
                color: Medal.gold,
                height: Metrics.goldHeight,
                x: Metrics.goldX
            )
        )
        podium.addChild(
            makeStep(
                name: Name.silverStep,
                color: Medal.silver,
                height: Metrics.silverHeight,
                x: Metrics.silverX
            )
        )
        podium.addChild(
            makeStep(
                name: Name.bronzeStep,
                color: Medal.bronze,
                height: Metrics.bronzeHeight,
                x: Metrics.bronzeX
            )
        )

        // The trophy starts on the gold step but hangs off the steps container
        // rather than off the step itself, so the difficulty ramp (US3) can
        // slide it to another step with a single `move(to:relativeTo:)` in a
        // parent that never changes — and never leaves the podium's anchor,
        // which is the anchor the balls' physics runs on.
        let trophy = makeTrophy()
        trophy.position = Step.gold.trophyPosition
        podium.addChild(trophy)

        return podium
    }

    /// One podium step, resting on y = 0 with its centre at `x`.
    static func makeStep(name: String, color: UIColor, height: Float, x: Float) -> ModelEntity {
        let mesh = MeshResource.generateBox(
            width: Metrics.stepWidth,
            height: height,
            depth: Metrics.stepDepth,
            cornerRadius: 0.004
        )
        let step = ModelEntity(mesh: mesh, materials: [material(color)])
        step.name = name
        step.position = [x, height / 2, 0]
        addStaticPhysics(
            to: step,
            shape: .generateBox(
                width: Metrics.stepWidth,
                height: height,
                depth: Metrics.stepDepth
            )
        )
        return step
    }

    /// The trophy: base + stem + an **open** cup.
    ///
    /// The cup is a ring of wall segments over a floor disc rather than a solid
    /// cylinder on purpose — a solid mesh would make the ball bounce off the
    /// target instead of settling into it, which is what the scoring rule has
    /// to detect. Nothing here is a sensor: whether a ball is inside the cup is
    /// decided from its position (``cupPlacement(ofBallAt:)``), not from a
    /// contact.
    static func makeTrophy() -> Entity {
        let trophy = Entity()
        trophy.name = Name.trophy

        let gold = material(Medal.gold, roughness: 0.25, metallic: true)

        // Base.
        let base = ModelEntity(
            mesh: cylinderMesh(
                height: Metrics.trophyBaseHeight,
                radius: Metrics.trophyBaseRadius
            ),
            materials: [gold]
        )
        base.name = "trophy_base"
        base.position = [0, Metrics.trophyBaseHeight / 2, 0]
        addStaticPhysics(
            to: base,
            shape: .generateBox(
                width: Metrics.trophyBaseRadius * 2,
                height: Metrics.trophyBaseHeight,
                depth: Metrics.trophyBaseRadius * 2
            )
        )
        trophy.addChild(base)

        // Stem.
        let stem = ModelEntity(
            mesh: cylinderMesh(
                height: Metrics.trophyStemHeight,
                radius: Metrics.trophyStemRadius
            ),
            materials: [gold]
        )
        stem.name = "trophy_stem"
        stem.position = [0, Metrics.trophyBaseHeight + Metrics.trophyStemHeight / 2, 0]
        addStaticPhysics(
            to: stem,
            shape: .generateBox(
                width: Metrics.trophyStemRadius * 2,
                height: Metrics.trophyStemHeight,
                depth: Metrics.trophyStemRadius * 2
            )
        )
        trophy.addChild(stem)

        // Cup, sitting on top of the stem.
        let cup = makeCup()
        cup.position = [0, Metrics.trophyBaseHeight + Metrics.trophyStemHeight, 0]
        trophy.addChild(cup)

        return trophy
    }

    /// The open cup. Its origin is the underside of its floor disc.
    static func makeCup() -> Entity {
        let cup = Entity()
        cup.name = Name.cup

        let gold = material(Medal.gold, roughness: 0.2, metallic: true)

        // Floor disc.
        let floorDisc = ModelEntity(
            mesh: cylinderMesh(
                height: Metrics.cupFloorThickness,
                radius: Metrics.cupInnerRadius
            ),
            materials: [gold]
        )
        floorDisc.name = Name.cupFloor
        floorDisc.position = [0, Metrics.cupFloorThickness / 2, 0]
        addStaticPhysics(
            to: floorDisc,
            shape: .generateBox(
                width: Metrics.cupInnerRadius * 2,
                height: Metrics.cupFloorThickness,
                depth: Metrics.cupInnerRadius * 2
            ),
            // A soft, grippy floor so balls settle instead of bouncing back out.
            friction: 0.9,
            restitution: 0.05
        )
        cup.addChild(floorDisc)

        // Wall: `cupWallSegments` thin boxes on a circle, forming a polygonal
        // ring that reads as a cylinder and collides like a container.
        //
        // Each segment also leans outward by `cupWallFlare`, which turns the
        // tube into a shallow cone (Gate 3 row 3.2). Two consequences, both
        // wanted: the inner face now funnels a ball toward the cup floor, and
        // the top face is a slope rather than a ledge, so a ball can no longer
        // come to rest on the rim and be culled out of existence.
        let segments = Metrics.cupWallSegments
        let ringRadius = Metrics.cupRingRadius
        // Chord length of one segment, measured at the **mouth**, where the
        // flare has pushed the ring out furthest — sizing it at the mid radius
        // would open gaps between neighbours at the top. Plus a hair of overlap.
        let segmentWidth = 2 * Metrics.cupRimRingRadius * sin(.pi / Float(segments)) * 1.08
        let wallY = Metrics.cupFloorThickness + Metrics.cupWallHeight / 2

        for index in 0..<segments {
            let angle = 2 * Float.pi * Float(index) / Float(segments)
            let segment = ModelEntity(
                mesh: .generateBox(
                    width: segmentWidth,
                    height: Metrics.cupWallHeight,
                    depth: Metrics.cupWallThickness
                ),
                materials: [gold]
            )
            segment.name = "\(Name.cupWall)_\(index)"
            segment.position = [
                ringRadius * sin(angle),
                wallY,
                ringRadius * cos(angle)
            ]
            // Yaw puts the segment's local +Z along the outward radius and its
            // local +X along the tangent; the second rotation then tips its top
            // toward that outward radius.
            segment.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
                * simd_quatf(angle: Metrics.cupWallFlare, axis: [1, 0, 0])
            addStaticPhysics(
                to: segment,
                shape: .generateBox(
                    width: segmentWidth,
                    height: Metrics.cupWallHeight,
                    depth: Metrics.cupWallThickness
                ),
                friction: Metrics.cupRimFriction,
                restitution: Metrics.cupRimRestitution
            )
            cup.addChild(segment)
        }

        return cup
    }

    /// A ball's position in the cup's own frame, described the way
    /// `TossController`'s cup rules want it (Gate 4 DEFECT).
    ///
    /// This is the single bridge between the geometry above and the scoring
    /// rules: the AR side measures the ball's centre relative to the cup entity
    /// and hands the result straight to ``TossController/isInsideCup(_:ballRadius:)``
    /// and ``TossController/isPerchedOnRim(_:ballRadius:cupOuterRadius:)``.
    /// There is no sensor volume any more — Phase 5 deleted it, because contact
    /// with a sensor cannot tell which side of the wall the ball is on, which
    /// is exactly what Gate 4 caught.
    static func cupPlacement(ofBallAt centre: SIMD3<Float>) -> TossController.CupPlacement {
        TossController.CupPlacement(
            heightAboveRim: centre.y - Metrics.cupRimHeight,
            radialDistance: simd_length(SIMD2(centre.x, centre.z)),
            heightAboveCupFloor: centre.y - Metrics.cupFloorThickness,
            interiorRadius: Metrics.cupInnerRadius(atHeight: centre.y)
        )
    }

    /// Invisible static plane at anchor height (y = 0) standing in for the real
    /// table or floor, so missed balls bounce on the surface the player placed
    /// the podium on instead of falling through the world.
    static func makeFloor() -> Entity {
        let floor = Entity()
        floor.name = Name.floor
        // Top face flush with y = 0.
        floor.position = [0, -Metrics.floorThickness / 2, 0]
        addStaticPhysics(
            to: floor,
            shape: .generateBox(
                width: Metrics.floorExtent,
                height: Metrics.floorThickness,
                depth: Metrics.floorExtent
            ),
            friction: 0.8,
            restitution: 0.25
        )
        return floor
    }

    // MARK: - Ball (FR-004)

    /// One throwable ball: a small dynamic sphere in the brand teal.
    ///
    /// Dimensions and physics material come from `TossController.Tuning`, which
    /// is where Gate 3's feel feedback gets applied — this function only turns
    /// those numbers into an entity.
    ///
    /// Continuous collision detection is on: at the 6.8 m/s ceiling a 3.5 cm
    /// ball moves ~11 cm per 60 Hz step, far further than the cup's 6 mm walls
    /// are thick, so discrete stepping would let a hard throw tunnel straight
    /// through the cup. (It mattered at Phase 3's 4.5 m/s; it matters more now.)
    static func makeBall(
        id: UInt64,
        radius: Float,
        mass: Float,
        friction: Float,
        restitution: Float
    ) -> ModelEntity {
        let ball = ModelEntity(
            mesh: .generateSphere(radius: radius),
            materials: [material(Medal.ball, roughness: 0.35)]
        )
        ball.name = "\(Name.ballPrefix)\(id)"
        ball.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius)]))
        var body = PhysicsBodyComponent(
            massProperties: .init(mass: mass),
            material: .generate(friction: friction, restitution: restitution),
            mode: .dynamic
        )
        body.isContinuousCollisionDetectionEnabled = true
        ball.components.set(body)
        // Present from the start so the culler can read the ball's speed on the
        // very first frame instead of treating it as motionless.
        ball.components.set(PhysicsMotionComponent())
        return ball
    }

    // MARK: - Helpers

    static func material(
        _ color: UIColor,
        roughness: Float = 0.45,
        metallic: Bool = false
    ) -> SimpleMaterial {
        SimpleMaterial(color: color, roughness: .float(roughness), isMetallic: metallic)
    }

    /// Gives an entity a collision shape and an immovable physics body, so the
    /// Phase 3 balls bounce off it rather than through it.
    static func addStaticPhysics(
        to entity: Entity,
        shape: ShapeResource,
        friction: Float = 0.7,
        restitution: Float = 0.2
    ) {
        entity.components.set(CollisionComponent(shapes: [shape]))
        entity.components.set(
            PhysicsBodyComponent(
                massProperties: .default,
                material: .generate(friction: friction, restitution: restitution),
                mode: .static
            )
        )
    }

    /// A Y-axis cylinder centred on its own origin, built from scratch.
    ///
    /// `MeshResource.generateCylinder` is iOS 18+, and the app deploys to
    /// iOS 17, so the mesh is generated here instead — still procedural, still
    /// no asset files (FR-003).
    ///
    /// Winding is counter-clockwise seen from outside, RealityKit's front-face
    /// convention. With `p(θ) = (r·sin θ, y, r·cos θ)`, increasing θ runs
    /// counter-clockwise when viewed from +Y, which fixes the order of every
    /// triangle below.
    static func cylinderMesh(height: Float, radius: Float, segments: Int = 24) -> MeshResource {
        let n = max(3, segments)
        let halfHeight = height / 2

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(4 * n + 2)
        normals.reserveCapacity(4 * n + 2)

        let ring: [SIMD2<Float>] = (0..<n).map { index in
            let angle = 2 * Float.pi * Float(index) / Float(n)
            return SIMD2(sin(angle), cos(angle))
        }

        // 0..<n — side, bottom ring (radial normals).
        for point in ring {
            positions.append([radius * point.x, -halfHeight, radius * point.y])
            normals.append([point.x, 0, point.y])
        }
        // n..<2n — side, top ring.
        for point in ring {
            positions.append([radius * point.x, halfHeight, radius * point.y])
            normals.append([point.x, 0, point.y])
        }
        // 2n — top cap centre; 2n+1..<3n+1 — top cap ring.
        positions.append([0, halfHeight, 0])
        normals.append([0, 1, 0])
        for point in ring {
            positions.append([radius * point.x, halfHeight, radius * point.y])
            normals.append([0, 1, 0])
        }
        // 3n+1 — bottom cap centre; 3n+2..<4n+2 — bottom cap ring.
        positions.append([0, -halfHeight, 0])
        normals.append([0, -1, 0])
        for point in ring {
            positions.append([radius * point.x, -halfHeight, radius * point.y])
            normals.append([0, -1, 0])
        }

        let topCentre = UInt32(2 * n)
        let topRing = UInt32(2 * n + 1)
        let bottomCentre = UInt32(3 * n + 1)
        let bottomRing = UInt32(3 * n + 2)

        var indices: [UInt32] = []
        indices.reserveCapacity(12 * n)
        for index in 0..<n {
            let i = UInt32(index)
            let j = UInt32((index + 1) % n)
            // Side quad, split into two counter-clockwise triangles.
            indices += [i, j, UInt32(n) + j]
            indices += [i, UInt32(n) + j, UInt32(n) + i]
            // Top cap — counter-clockwise seen from above.
            indices += [topCentre, topRing + i, topRing + j]
            // Bottom cap — reversed, since it is seen from below.
            indices += [bottomCentre, bottomRing + j, bottomRing + i]
        }

        var descriptor = MeshDescriptor(name: "cylinder")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)

        // The descriptor is built from constants above, so this cannot fail in
        // practice; a box of the same footprint keeps the game playable if a
        // future edit ever breaks it.
        if let mesh = try? MeshResource.generate(from: [descriptor]) {
            return mesh
        }
        return .generateBox(width: radius * 2, height: height, depth: radius * 2)
    }
}

#if DEBUG
extension PodiumBuilder {
    /// Structural assertions for the built scene, as a list of human-readable
    /// problems (empty == healthy).
    ///
    /// This stands in for the unit tests that Phase 6a's test target will host.
    /// `PodiumARViewContainer` runs it once in DEBUG builds, so a broken
    /// hierarchy trips an `assert` on the first launch instead of silently
    /// producing an unplayable podium.
    static func selfCheck() -> [String] {
        var problems: [String] = []
        let scene = makeScene()

        func requireEntity(_ name: String) -> Entity? {
            guard let found = scene.findEntity(named: name) else {
                problems.append("missing entity '\(name)'")
                return nil
            }
            return found
        }

        func requireCollision(_ entity: Entity, _ label: String) {
            guard let collision = entity.components[CollisionComponent.self] else {
                problems.append("'\(label)' has no CollisionComponent")
                return
            }
            if collision.shapes.isEmpty {
                problems.append("'\(label)' has an empty collision shape list")
            }
        }

        func requireStaticBody(_ entity: Entity, _ label: String) {
            guard let body = entity.components[PhysicsBodyComponent.self] else {
                problems.append("'\(label)' has no PhysicsBodyComponent")
                return
            }
            if body.mode != .static {
                problems.append("'\(label)' physics body is not .static")
            }
        }

        // 1. Three steps: medal-coloured, resting on the surface, collidable.
        let expectedSteps: [(String, Float, UIColor)] = [
            (Name.goldStep, Metrics.goldHeight, Medal.gold),
            (Name.silverStep, Metrics.silverHeight, Medal.silver),
            (Name.bronzeStep, Metrics.bronzeHeight, Medal.bronze)
        ]
        for (name, height, color) in expectedSteps {
            guard let step = requireEntity(name) else { continue }
            requireCollision(step, name)
            requireStaticBody(step, name)
            if abs(step.position.y - height / 2) > 0.0001 {
                problems.append("'\(name)' does not rest on the anchor plane")
            }
            guard let model = step.components[ModelComponent.self] else {
                problems.append("'\(name)' has no ModelComponent")
                continue
            }
            guard let simple = model.materials.first as? SimpleMaterial else {
                problems.append("'\(name)' is not using a SimpleMaterial")
                continue
            }
            if !sameColor(simple.color.tint, color) {
                problems.append("'\(name)' is not using its medal color")
            }
        }

        // 2. Trophy standing on the tallest (gold) step, hanging off the steps
        //    container so the ramp can slide it between steps (US3).
        if let trophy = requireEntity(Name.trophy) {
            if trophy.parent?.name != Name.steps {
                problems.append("trophy is not parented to the steps container")
            }
            if simd_distance(trophy.position, Step.gold.trophyPosition) > 0.0001 {
                problems.append("trophy does not start on the gold step's top face")
            }
        }

        // 3. Cup: a closed ring of wall segments over a floor disc.
        if let cupFloor = requireEntity(Name.cupFloor) {
            requireCollision(cupFloor, Name.cupFloor)
            requireStaticBody(cupFloor, Name.cupFloor)
        }
        let wallSegments = (0..<Metrics.cupWallSegments).compactMap {
            scene.findEntity(named: "\(Name.cupWall)_\($0)")
        }
        if wallSegments.count != Metrics.cupWallSegments {
            problems.append(
                "cup wall has \(wallSegments.count) of \(Metrics.cupWallSegments) segments"
            )
        }
        for segment in wallSegments {
            requireCollision(segment, segment.name)
            requireStaticBody(segment, segment.name)
        }

        // 4. The scoring rule against the real geometry (Gate 4 DEFECT): a ball
        //    resting on the cup floor must read as inside, and a ball touching
        //    the *outside* of the wall must never read as inside, at any height
        //    — including the low front, which is where the false positives came
        //    from.
        let toss = TossController()
        let ballRadius = toss.tuning.ballRadius
        let restingCentre = SIMD3<Float>(0, Metrics.cupFloorThickness + ballRadius, 0)
        if !toss.isInsideCup(cupPlacement(ofBallAt: restingCentre), ballRadius: ballRadius) {
            problems.append("a ball resting on the cup floor does not register as inside")
        }
        for step in 0...12 {
            let height = Float(step) / 12 * Metrics.cupRimHeight
            // Centre of a ball pressed against the outer face of the wall.
            let outside = SIMD3<Float>(
                Metrics.cupInnerRadius(atHeight: height) + Metrics.cupWallThickness + ballRadius,
                height,
                0
            )
            if toss.isInsideCup(cupPlacement(ofBallAt: outside), ballRadius: ballRadius) {
                problems.append(
                    "a ball touching the cup's outside at \(height) m reads as inside"
                )
            }
        }
        // A ball perched on the rim is neither inside nor allowed to score.
        let perched = SIMD3<Float>(Metrics.cupRimRingRadius, Metrics.cupRimHeight + ballRadius, 0)
        if toss.isInsideCup(cupPlacement(ofBallAt: perched), ballRadius: ballRadius) {
            problems.append("a ball perched on the rim reads as inside")
        }

        // 4b. Cup geometry after the Gate 3 rim fix: the wall must flare
        //     outward and still admit the ball at the bottom.
        let mouthRadius = Metrics.cupInnerRadius(atHeight: Metrics.cupRimHeight)
        let baseRadius = Metrics.cupInnerRadius(atHeight: Metrics.cupFloorThickness)
        if mouthRadius <= baseRadius {
            problems.append("the cup narrows toward its mouth — the rim flare is inverted")
        }
        let restingHeight = Metrics.cupFloorThickness + ballRadius
        if Metrics.cupInnerRadius(atHeight: restingHeight) <= ballRadius {
            problems.append("the flared wall is too tight for a ball to reach the cup floor")
        }

        // 5. Floor plane: invisible, static, top face at the anchor height.
        if let floor = requireEntity(Name.floor) {
            requireCollision(floor, Name.floor)
            requireStaticBody(floor, Name.floor)
            if floor.components[ModelComponent.self] != nil {
                problems.append("floor plane is visible — it must have no ModelComponent")
            }
            if abs(floor.position.y + Metrics.floorThickness / 2) > 0.0001 {
                problems.append("floor plane's top face is not at the anchor height")
            }
        }

        return problems
    }

    /// Compares two colours by sRGB components — `UIColor ==` also compares
    /// colour spaces, which a round-trip through the material does not promise
    /// to preserve.
    private static func sameColor(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
              rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        else { return false }
        let tolerance: CGFloat = 0.01
        return abs(lr - rr) < tolerance
            && abs(lg - rg) < tolerance
            && abs(lb - rb) < tolerance
            && abs(la - ra) < tolerance
    }
}
#endif
