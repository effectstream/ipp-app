import Foundation
import RealityKit
import UIKit
import simd

/// Turns latitude/longitude into points on a square plate. Pure, no RealityKit,
/// no UIKit — every rule the floor map's layout depends on is here so it can be
/// tested off-device (Phase 5C testing item 1).
enum FloorMapProjection {

    /// A bounding-box fit of one pin set onto one plate.
    ///
    /// Equirectangular, which is the right projection for a map a metre across
    /// covering a few kilometres: longitude is compressed by `cos(latitude)` so
    /// the shape is not stretched, and a single uniform `metresPerDegree`
    /// scales both axes so the set keeps its real aspect ratio instead of being
    /// squashed to fill the square.
    struct Fit: Equatable {
        let centerLatitude: Double
        let centerLongitude: Double
        /// `cos(centerLatitude)` — how much a degree of longitude is worth
        /// against a degree of latitude at this latitude.
        let longitudeScale: Double
        /// Plate metres per degree of latitude. **Zero** when the pin set has
        /// no extent (one pin, or every pin at the same coordinate), which
        /// collapses the whole set onto the centre of the plate — the sane
        /// answer, and the one that cannot divide by zero.
        let metresPerDegree: Double
        /// Side of the square the pins are fitted into, in metres.
        let extent: Float

        /// Where a pin lands on the plate, in metres, as `(x, z)` in the
        /// podium's own frame.
        ///
        /// North is **−Z**: the podium is turned to face the player at
        /// placement and +Z is the side they stand on, so higher latitudes
        /// belong further away from them.
        ///
        /// Always finite and always inside the plate: an unusable pin gives the
        /// centre, and anything the arithmetic produces is clamped to the
        /// half-extent, so a stray coordinate cannot fling a dot across the
        /// room.
        func project(_ pin: GeoPin) -> SIMD2<Float> {
            guard pin.isUsable, metresPerDegree.isFinite else { return .zero }
            let x = (pin.longitude - centerLongitude) * longitudeScale * metresPerDegree
            let z = -(pin.latitude - centerLatitude) * metresPerDegree
            guard x.isFinite, z.isFinite else { return .zero }
            let half = Double(extent) / 2
            return SIMD2(
                Float(min(max(x, -half), half)),
                Float(min(max(z, -half), half))
            )
        }
    }

    /// The fit that puts `pins` inside a square of side `extent`, centred.
    ///
    /// Degenerate inputs are answered rather than rejected: an empty list, a
    /// single pin and a list where every pin is identical all produce a fit
    /// whose `metresPerDegree` is zero, so every pin projects to the plate's
    /// centre and the map shows one dot in the middle instead of `NaN`.
    static func fit(_ pins: [GeoPin], extent: Float) -> Fit {
        let usable = pins.filter(\.isUsable)
        guard !usable.isEmpty, extent > 0 else {
            return Fit(
                centerLatitude: 0,
                centerLongitude: 0,
                longitudeScale: 1,
                metresPerDegree: 0,
                extent: max(extent, 0)
            )
        }

        var minLatitude = usable[0].latitude
        var maxLatitude = usable[0].latitude
        var minLongitude = usable[0].longitude
        var maxLongitude = usable[0].longitude
        for pin in usable.dropFirst() {
            minLatitude = min(minLatitude, pin.latitude)
            maxLatitude = max(maxLatitude, pin.latitude)
            minLongitude = min(minLongitude, pin.longitude)
            maxLongitude = max(maxLongitude, pin.longitude)
        }

        let centerLatitude = (minLatitude + maxLatitude) / 2
        let centerLongitude = (minLongitude + maxLongitude) / 2
        // Floored so a pin set near a pole cannot drive the scale to infinity.
        let longitudeScale = max(cos(centerLatitude * .pi / 180), 0.05)

        let spanLatitude = maxLatitude - minLatitude
        let spanLongitude = (maxLongitude - minLongitude) * longitudeScale
        let span = max(spanLatitude, spanLongitude)
        // 1e-9° is about 0.1 mm on the ground: below this the pins are one
        // point as far as a metre-wide plate is concerned.
        let metresPerDegree = span > 1e-9 ? Double(extent) / span : 0

        return Fit(
            centerLatitude: centerLatitude,
            centerLongitude: centerLongitude,
            longitudeScale: longitudeScale,
            metresPerDegree: metresPerDegree,
            extent: extent
        )
    }

    /// Evenly thins a pin list down to at most `limit` entries, deterministically.
    ///
    /// The backend can return a thousand pins and the scene should not grow a
    /// thousand entities for a plate a metre across, where they would overlap
    /// into a solid blob anyway. Sampling by *stride over the whole list*
    /// rather than by taking the first `limit` keeps the geographic spread —
    /// the seeded data arrives grouped by month and city, so a prefix would
    /// show only the first few cities.
    static func sample(_ pins: [GeoPin], limit: Int) -> [GeoPin] {
        guard limit > 0 else { return [] }
        guard pins.count > limit else { return pins }
        let step = Double(pins.count) / Double(limit)
        return (0..<limit).map { index in
            pins[min(Int(Double(index) * step), pins.count - 1)]
        }
    }

    /// A density level in `0..<stops` for each point: how crowded its
    /// neighbourhood is, relative to the busiest neighbourhood on the plate.
    ///
    /// This is what makes the map read as a map rather than as confetti — a
    /// city shows as a hot patch and an outlying record as a cool dot. It is
    /// O(n²), which is why ``sample(_:limit:)`` caps `n`; at the 260-dot cap
    /// that is ~34 k distance comparisons, once, in the frame the podium is
    /// placed.
    static func densityLevels(for points: [SIMD2<Float>], radius: Float, stops: Int) -> [Int] {
        guard stops > 1, !points.isEmpty, radius > 0 else {
            return Array(repeating: 0, count: points.count)
        }

        let radiusSquared = radius * radius
        var counts = [Int](repeating: 0, count: points.count)
        for i in points.indices {
            for j in points.index(after: i)..<points.endIndex {
                let delta = points[i] - points[j]
                guard simd_length_squared(delta) <= radiusSquared else { continue }
                counts[i] += 1
                counts[j] += 1
            }
        }

        guard let busiest = counts.max(), busiest > 0 else {
            return Array(repeating: 0, count: points.count)
        }
        let top = Float(stops - 1)
        return counts.map { count in
            min(max(Int((Float(count) / Float(busiest) * top).rounded()), 0), stops - 1)
        }
    }

    /// The line printed on the plate's near edge.
    ///
    /// It names the source on purpose: with the backend up the owner must be
    /// able to see "en vivo" under the podium, and with it stopped the same
    /// glance must show "de ejemplo" (gate rows 5C-g1 and 5C-g3).
    static func caption(pinCount: Int, isLive: Bool) -> String {
        let source = isLive ? "Datos en vivo" : "Datos de ejemplo"
        let places = pinCount == 1 ? "1 ubicación" : "\(pinCount) ubicaciones"
        return "\(source) · \(places)"
    }
}

/// The map of the app's data locations, laid on the floor under the podium
/// (FR-013, Phase 5C — it replaces the Star Wars crawl of Phase 5B).
///
/// A square plate a metre across, centred on the podium, carrying one dot per
/// (already anonymized) data location, tinted by how crowded its neighbourhood
/// is, plus a caption on the near edge naming the source.
///
/// **The game does no networking.** The pins arrive as a plain `FloorMapData`
/// value built by the app layer (`MapPinsService`), which substitutes an
/// offline sample when no backend answers. Nothing in this file — or anywhere
/// under `ios/IPP/Game/` — knows what a URL is (FR-008, SC-005, question Q5).
///
/// No tiles, no imagery, no external map provider: the plate is a procedural
/// box and the dots are procedural cylinders, so the feature adds no asset
/// files (FR-003) and contacts nobody (SC-005).
///
/// ## Cost, and why it cannot touch the game
///
/// Everything is built once, when the podium is placed, and then never
/// touched again — there is no per-frame update at all. One dot mesh and five
/// materials are shared by every dot. Nothing in the subtree carries a
/// `CollisionComponent` or a `PhysicsBodyComponent`, so a ball flies straight
/// through the plate and lands on the invisible floor collider underneath,
/// exactly as it did before the map existed.
@MainActor
enum FloorMap {

    enum Name {
        static let root = "floor_map"
        static let plate = "floor_map_plate"
        static let frame = "floor_map_frame"
        static let caption = "floor_map_caption"
        static func pin(_ index: Int) -> String { "floor_map_pin_\(index)" }
    }

    /// Same one-line-edit spirit as `TossController.Tuning`, `PodiumBreathing`
    /// and `StandingsDisplay.Look`.
    enum Look {
        /// Side of the plate, in metres. A metre across puts the map well
        /// outside the 30 cm podium and still fits on a desk.
        static let side: Float = 1.00
        /// Margin between the plate's edge and the outermost dot.
        static let inset: Float = 0.06
        /// Thickness of the plate slab. Thin, but not zero: a zero-height box
        /// z-fights with the floor from a shallow angle.
        static let thickness: Float = 0.004
        /// How far the whole map floats above the anchor plane, so it never
        /// z-fights the invisible floor collider whose top face is y = 0.
        static let lift: Float = 0.001
        /// Width of the border showing around the plate.
        static let frameWidth: Float = 0.012
        static let cornerRadius: Float = 0.02

        /// Diameter of one location dot. 12 mm on a 1 m plate subtends ~0.7°
        /// at a metre — a clearly separate dot, not a pixel.
        static let dotDiameter: Float = 0.012
        static let dotHeight: Float = 0.0035
        static let dotSegments = 10
        /// Hard cap on rendered dots. The seeded backend returns ~960.
        static let maxDots = 260
        /// Neighbourhood radius for the density tint, in plate metres.
        static let densityRadius: Float = 0.05
        /// How many colours the tint ramp has, coolest first.
        static let densityStops = 5

        /// Em size of the caption on the near edge.
        static let captionSize: Float = 0.020
        /// How far the caption's face is tipped up toward the player from flat,
        /// in radians. Flat text on a floor is hard to read from standing
        /// height; 20° is enough to help without it looking like a signpost.
        static let captionLean: Float = 20 * .pi / 180

        static let plateOpacity: Float = 0.42
        static let frameOpacity: Float = 0.30
        static let captionOpacity: Float = 0.85
    }

    /// The plate's ground colour: the app's ink, so the dots read against it.
    static let plateColor = UIColor(red: 0.07, green: 0.11, blue: 0.13, alpha: 1)

    /// Builds the whole map. Returns an entity to be added to the podium's
    /// scene root, where it inherits the placement yaw.
    static func make(_ data: FloorMapData) -> Entity {
        let root = Entity()
        root.name = Name.root
        root.position = [0, Look.lift, 0]

        // Border first, lower, and wider — what shows around the plate is the
        // frame.
        let frame = ModelEntity(
            mesh: .generateBox(
                width: Look.side + 2 * Look.frameWidth,
                height: Look.thickness * 0.6,
                depth: Look.side + 2 * Look.frameWidth,
                cornerRadius: Look.cornerRadius
            ),
            materials: [material(color: PodiumBuilder.Medal.ball, opacity: Look.frameOpacity)]
        )
        frame.name = Name.frame
        frame.position.y = Look.thickness * 0.3
        root.addChild(frame)

        let plate = ModelEntity(
            mesh: .generateBox(
                width: Look.side,
                height: Look.thickness,
                depth: Look.side,
                cornerRadius: Look.cornerRadius
            ),
            materials: [material(color: plateColor, opacity: Look.plateOpacity)]
        )
        plate.name = Name.plate
        plate.position.y = Look.thickness / 2
        root.addChild(plate)

        let sampled = FloorMapProjection.sample(data.pins, limit: Look.maxDots)
        let fit = FloorMapProjection.fit(sampled, extent: Look.side - 2 * Look.inset)
        let points = sampled.map(fit.project)
        let levels = FloorMapProjection.densityLevels(
            for: points,
            radius: Look.densityRadius,
            stops: Look.densityStops
        )

        let ramp = densityRamp()
        // One mesh for every dot — 260 entities sharing a single 10-segment
        // cylinder rather than 260 meshes.
        let dotMesh = PodiumBuilder.cylinderMesh(
            height: Look.dotHeight,
            radius: Look.dotDiameter / 2,
            segments: Look.dotSegments
        )
        let dotY = Look.thickness + Look.dotHeight / 2

        for (index, point) in points.enumerated() {
            let level = levels.indices.contains(index) ? levels[index] : 0
            let dot = ModelEntity(
                mesh: dotMesh,
                materials: [ramp[min(max(level, 0), ramp.count - 1)]]
            )
            dot.name = Name.pin(index)
            dot.position = [point.x, dotY, point.y]
            root.addChild(dot)
        }

        root.addChild(makeCaption(pinCount: sampled.count, isLive: data.isLive))
        return root
    }

    /// The caption, lying on the plate's near edge and tipped up toward the
    /// player.
    ///
    /// The rotation is the flat-on-the-floor case of the same construction the
    /// Phase 5B crawl used: a text mesh is drawn in its own XY plane facing +Z,
    /// so rotating about X by `-(π/2 − lean)` sends its up (+Y) away from the
    /// player and its face (+Z) up out of the floor, leaning back toward them.
    static func makeCaption(pinCount: Int, isLive: Bool) -> Entity {
        let pivot = Entity()
        pivot.name = Name.caption
        pivot.position = [
            0,
            Look.thickness + 0.001,
            Look.side / 2 - Look.inset / 2,
        ]
        pivot.orientation = simd_quatf(angle: -(.pi / 2 - Look.captionLean), axis: [1, 0, 0])
        pivot.addChild(
            StandingsDisplay.makeTextModel(
                FloorMapProjection.caption(pinCount: pinCount, isLive: isLive),
                size: Look.captionSize,
                material: material(color: .white, opacity: Look.captionOpacity)
            )
        )
        return pivot
    }

    /// Coolest (sparse) to hottest (crowded): the app's brand teal warming into
    /// the podium's gold, so the map is built from colours the rest of the app
    /// already uses (FR-009).
    static func densityRamp() -> [UnlitMaterial] {
        let stops = max(2, Look.densityStops)
        return (0..<stops).map { level in
            let t = Float(level) / Float(stops - 1)
            return material(
                color: blend(PodiumBuilder.Medal.ball, PodiumBuilder.Medal.gold, t),
                // Crowded dots are also more solid, which reads as depth on a
                // translucent plate.
                opacity: 0.62 + 0.38 * t
            )
        }
    }

    static func material(color: UIColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: min(max(opacity, 0), 1)))
        return material
    }

    /// Straight RGB interpolation. `t` is clamped, so a level outside the ramp
    /// cannot produce a colour outside it.
    static func blend(_ from: UIColor, _ to: UIColor, _ t: Float) -> UIColor {
        let amount = CGFloat(min(max(t, 0), 1))
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        from.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        to.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        return UIColor(
            red: fr + (tr - fr) * amount,
            green: fg + (tg - fg) * amount,
            blue: fb + (tb - fb) * amount,
            alpha: fa + (ta - fa) * amount
        )
    }
}
