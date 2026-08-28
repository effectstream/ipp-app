import Foundation
import RealityKit
import UIKit
import simd

/// Turns latitude/longitude into points on a square field. Pure, no RealityKit,
/// no UIKit — every rule the floor map's layout depends on is here so it can be
/// tested off-device (Phase 5C testing item 1).
enum FloorMapProjection {

    /// A bounding-box fit of one pin set onto one field.
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
        /// collapses the whole set onto the centre of the field — the sane
        /// answer, and the one that cannot divide by zero.
        let metresPerDegree: Double
        /// Side of the square the pins are fitted into, in metres.
        let extent: Float

        /// Where a pin lands on the field, in metres, as `(x, z)` in the
        /// podium's own frame.
        ///
        /// North is **−Z**: the podium is turned to face the player at
        /// placement and +Z is the side they stand on, so higher latitudes
        /// belong further away from them.
        ///
        /// Always finite and always inside the field: an unusable pin gives the
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
    /// whose `metresPerDegree` is zero, so every pin projects to the field's
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
        // point as far as a metre-wide field is concerned.
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
    /// thousand entities for a field a metre across, where they would overlap
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
    /// neighbourhood is, relative to the busiest neighbourhood on the field.
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

    /// The line printed on the field's near edge.
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

/// How a single dot on the floor map behaves over time (owner request at Gate
/// 5C: "make them slightly animated (randomly) — blink/grow so it looks alive;
/// some can disappear for a few seconds, so it looks like data is changing").
///
/// Pure and deterministic: every dot's whole life is a handful of numbers
/// derived from its index, so the field shimmers organically without anything
/// being stored, randomised at runtime, or allocated per frame. Two dots never
/// share a phase, so the map never pulses in unison — which is the difference
/// between "alive" and "a strobe".
enum FloorMapAnimation {

    /// Same one-line-edit spirit as `TossController.Tuning`: if the owner says
    /// "too fast" or "too many vanishing", it is one number here.
    enum Tuning {
        /// A dot's pulse takes between these, in seconds. Range chosen so no
        /// two neighbouring dots visibly beat together.
        static let minPulsePeriod: TimeInterval = 1.5
        static let maxPulsePeriod: TimeInterval = 4.0
        /// …and grows/shrinks by this fraction of its size.
        static let minPulseAmplitude: Float = 0.20
        static let maxPulseAmplitude: Float = 0.40

        /// What share of the dots ever vanish. The rest are always on, so the
        /// map cannot thin out no matter how the phases line up.
        static let dropoutFraction: Double = 0.12
        /// How often a vanishing dot vanishes, in seconds. The floor of 16 s is
        /// not arbitrary: against a dropout of up to `maxDropoutDuration` it
        /// keeps every dot present for at least three quarters of its cycle,
        /// so a blinking dot reads as *occasionally* missing rather than as
        /// flickering. A test asserts that ratio, so lowering this without
        /// also lowering the duration will fail rather than quietly turn the
        /// map into a strobe.
        static let minDropoutCycle: TimeInterval = 16
        static let maxDropoutCycle: TimeInterval = 26
        /// …and how long it stays gone.
        static let minDropoutDuration: TimeInterval = 2.0
        static let maxDropoutDuration: TimeInterval = 4.0
        /// How long the fade out and back takes. Never more than half the
        /// dropout, or the dot would never actually reach zero.
        static let fadeDuration: TimeInterval = 0.45

        /// How many discrete opacities the fade uses. Pre-built materials, one
        /// per level per density tint, so a fading dot allocates nothing.
        static let fadeSteps = 8

        /// Seed for the per-dot parameters. Fixed, so the same map always
        /// animates the same way. The bytes spell "IPPLIVE".
        static let defaultSeed: UInt64 = 0x4950_504C_4956_45
    }

    /// One dot's constants, drawn once from its index.
    struct Dot: Equatable {
        var pulsePeriod: TimeInterval
        var pulsePhase: Float
        var pulseAmplitude: Float
        var dropsOut: Bool
        var dropoutCycle: TimeInterval
        var dropoutStart: TimeInterval
        var dropoutDuration: TimeInterval
    }

    /// The parameters for dot `index`. Same index and seed, same dot, always —
    /// so the field is reproducible and the tests can assert on it.
    ///
    /// The generator is re-seeded per dot rather than run as one stream, so a
    /// dot's behaviour depends only on its own index. Adding a pin to the
    /// middle of the list therefore does not reshuffle every dot after it.
    static func dot(index: Int, seed: UInt64 = Tuning.defaultSeed) -> Dot {
        var generator = SyntheticStandings.Generator(seed: seed &+ UInt64(bitPattern: Int64(index)))

        let period = TimeInterval.random(
            in: Tuning.minPulsePeriod...Tuning.maxPulsePeriod,
            using: &generator
        )
        let phase = Float.random(in: 0..<(2 * .pi), using: &generator)
        let amplitude = Float.random(
            in: Tuning.minPulseAmplitude...Tuning.maxPulseAmplitude,
            using: &generator
        )
        let dropsOut = Double.random(in: 0..<1, using: &generator) < Tuning.dropoutFraction
        let cycle = TimeInterval.random(
            in: Tuning.minDropoutCycle...Tuning.maxDropoutCycle,
            using: &generator
        )
        // Staggered over the whole cycle, so the vanishing dots take turns
        // instead of blinking out together.
        let start = TimeInterval.random(in: 0..<cycle, using: &generator)
        let duration = TimeInterval.random(
            in: Tuning.minDropoutDuration...Tuning.maxDropoutDuration,
            using: &generator
        )

        return Dot(
            pulsePeriod: period,
            pulsePhase: phase,
            pulseAmplitude: amplitude,
            dropsOut: dropsOut,
            dropoutCycle: cycle,
            dropoutStart: start,
            dropoutDuration: min(duration, cycle / 2)
        )
    }

    /// How big the dot is right now, as a multiple of its built size. Always
    /// within `1 ± pulseAmplitude`, always finite.
    static func scale(_ dot: Dot, at time: TimeInterval) -> Float {
        guard time.isFinite, dot.pulsePeriod > 0 else { return 1 }
        let angle = Float(time.truncatingRemainder(dividingBy: dot.pulsePeriod) / dot.pulsePeriod)
            * 2 * .pi + dot.pulsePhase
        return 1 + dot.pulseAmplitude * sin(angle)
    }

    /// How visible the dot is right now, 0…1. Always 1 for a dot that never
    /// drops out, which is the great majority of them.
    static func visibility(_ dot: Dot, at time: TimeInterval) -> Float {
        guard dot.dropsOut, time.isFinite, dot.dropoutCycle > 0, dot.dropoutDuration > 0 else {
            return 1
        }

        let offset = (time - dot.dropoutStart).truncatingRemainder(dividingBy: dot.dropoutCycle)
        let phase = offset < 0 ? offset + dot.dropoutCycle : offset
        guard phase < dot.dropoutDuration else { return 1 }

        let fade = min(Tuning.fadeDuration, dot.dropoutDuration / 2)
        guard fade > 0 else { return 0 }
        if phase < fade {
            return Float(1 - phase / fade)
        }
        if phase > dot.dropoutDuration - fade {
            return Float((phase - (dot.dropoutDuration - fade)) / fade)
        }
        return 0
    }

    /// The rung of the pre-built fade ramp a visibility lands on.
    ///
    /// The `isFinite` guard is not decoration — `Swift.min`/`max` propagate a
    /// NaN rather than clamping it and `Int(nan)` traps, the crash Phase 5B's
    /// crawl fade found the hard way.
    static func fadeLevel(forVisibility visibility: Float) -> Int {
        guard visibility.isFinite else { return Tuning.fadeSteps }
        let clamped = min(max(visibility, 0), 1)
        return min(max(Int((clamped * Float(Tuning.fadeSteps)).rounded()), 0), Tuning.fadeSteps)
    }
}

/// The map of the app's data locations, on the floor under the podium (FR-013,
/// Phase 5C — it replaces the Star Wars crawl of Phase 5B).
///
/// A field of dots floating just above the surface, one per (already
/// anonymized) data location, fitted to a metre-wide square centred on the
/// podium, tinted by how crowded each neighbourhood is, with a caption on the
/// near edge naming the source. The dots pulse and occasionally blink out and
/// back, so the field reads as live data rather than as a printed chart
/// (owner rework at Gate 5C, task 5C.3).
///
/// > There is deliberately **no plate and no border**. An earlier version drew
/// > the dots on a translucent slab; the owner asked for the box to go, so the
/// > floor itself — the real desk, seen through the camera — is the map's
/// > background.
///
/// **The game does no networking.** The pins arrive as a plain `FloorMapData`
/// value built by the app layer (`MapPinsService`), which substitutes an
/// offline sample when no backend answers. Nothing in this file — or anywhere
/// under `ios/IPP/Game/` — knows what a URL is (FR-008, SC-005, question Q5).
///
/// No tiles, no imagery, no external map provider: the dots are procedural
/// cylinders, so the feature adds no asset files (FR-003) and contacts nobody
/// (SC-005).
///
/// ## Cost, and why it cannot touch the game
///
/// The field is built once, when the podium is placed: one shared dot mesh and
/// a pre-built ramp of `densityStops × (fadeSteps + 1)` materials, so 260 dots
/// allocate one mesh and 45 materials between them. A frame is then one `sin`
/// and one transform write per dot, plus a material assignment **only** for the
/// ~12 % of dots that ever fade, and only when their rung actually changes —
/// the other 88 % never touch their materials at all.
///
/// Nothing in the subtree carries a `CollisionComponent` or a
/// `PhysicsBodyComponent`, so a ball flies straight through the field and lands
/// on the invisible floor collider underneath, exactly as it did before the map
/// existed. The animation therefore cannot affect play however it moves.
@MainActor
enum FloorMap {

    enum Name {
        static let root = "floor_map"
        static let caption = "floor_map_caption"
        static let pinPrefix = "floor_map_pin_"
        static func pin(_ index: Int) -> String { "\(pinPrefix)\(index)" }
    }

    /// Same one-line-edit spirit as `TossController.Tuning`, `PodiumBreathing`
    /// and `StandingsDisplay.Look`.
    enum Look {
        /// Side of the square the dots are fitted into, in metres. A metre
        /// across puts the field well outside the 30 cm podium and still fits
        /// on a desk.
        static let side: Float = 1.00
        /// Margin between that square's edge and the outermost dot.
        static let inset: Float = 0.06
        /// How far the field floats above the anchor plane, so a dot never
        /// z-fights the invisible floor collider whose top face is y = 0.
        static let lift: Float = 0.001

        /// Diameter of one location dot. 12 mm on a 1 m field subtends ~0.7°
        /// at a metre — a clearly separate dot, not a pixel.
        static let dotDiameter: Float = 0.012
        static let dotHeight: Float = 0.0035
        static let dotSegments = 10
        /// Hard cap on rendered dots. The seeded backend returns ~960.
        static let maxDots = 260
        /// Neighbourhood radius for the density tint, in field metres.
        static let densityRadius: Float = 0.05
        /// How many colours the tint ramp has, coolest first.
        static let densityStops = 5

        /// Em size of the caption on the near edge.
        static let captionSize: Float = 0.020
        /// How far the caption's face is tipped up toward the player from flat,
        /// in radians. Flat text on a floor is hard to read from standing
        /// height; 20° is enough to help without it looking like a signpost.
        static let captionLean: Float = 20 * .pi / 180

        /// Opacity of the sparsest dot, and of the most crowded one. Higher
        /// than the plated version was — without a slab behind them the dots
        /// carry the whole map.
        static let minDotOpacity: Float = 0.75
        static let maxDotOpacity: Float = 1.0
        static let captionOpacity: Float = 0.85
    }

    // MARK: - What the update loop holds on to

    /// The built field: the entities, their constants, and the material ramp
    /// they share. Built once at placement, then only read.
    final class Display {
        let root: Entity
        let dots: [ModelEntity]
        let motion: [FloorMapAnimation.Dot]
        /// `ramp[densityLevel][fadeLevel]`, pre-built so a fading dot never
        /// allocates a material.
        let ramp: [[UnlitMaterial]]
        let density: [Int]
        /// Which rung each dot is showing, so an unchanged frame costs nothing.
        var levels: [Int]

        init(
            root: Entity,
            dots: [ModelEntity],
            motion: [FloorMapAnimation.Dot],
            ramp: [[UnlitMaterial]],
            density: [Int]
        ) {
            self.root = root
            self.dots = dots
            self.motion = motion
            self.ramp = ramp
            self.density = density
            self.levels = Array(repeating: -1, count: dots.count)
        }
    }

    // MARK: - Building

    /// Builds the whole field. The returned `root` goes on the podium's scene
    /// root, where it inherits the placement yaw.
    static func make(_ data: FloorMapData, seed: UInt64 = FloorMapAnimation.Tuning.defaultSeed) -> Display {
        let root = Entity()
        root.name = Name.root
        root.position = [0, Look.lift, 0]

        let sampled = FloorMapProjection.sample(data.pins, limit: Look.maxDots)
        let fit = FloorMapProjection.fit(sampled, extent: Look.side - 2 * Look.inset)
        let points = sampled.map(fit.project)
        let density = FloorMapProjection.densityLevels(
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

        var dots: [ModelEntity] = []
        var motion: [FloorMapAnimation.Dot] = []
        dots.reserveCapacity(points.count)
        motion.reserveCapacity(points.count)

        for (index, point) in points.enumerated() {
            let tint = ramp[min(max(density[index], 0), ramp.count - 1)]
            let dot = ModelEntity(mesh: dotMesh, materials: [tint[tint.count - 1]])
            dot.name = Name.pin(index)
            dot.position = [point.x, Look.dotHeight / 2, point.y]
            root.addChild(dot)
            dots.append(dot)
            motion.append(FloorMapAnimation.dot(index: index, seed: seed))
        }

        root.addChild(makeCaption(pinCount: sampled.count, isLive: data.isLive))

        let display = Display(
            root: root,
            dots: dots,
            motion: motion,
            ramp: ramp,
            density: density
        )
        // Put every dot on its phase-zero size and opacity now, so the field
        // appears already alive instead of snapping into motion on the frame
        // after the podium is placed.
        update(display, at: 0)
        return display
    }

    /// The caption, lying on the field's near edge and tipped up toward the
    /// player.
    ///
    /// The rotation is the flat-on-the-floor case of the same construction the
    /// Phase 5B crawl used: a text mesh is drawn in its own XY plane facing +Z,
    /// so rotating about X by `-(π/2 − lean)` sends its up (+Y) away from the
    /// player and its face (+Z) up out of the floor, leaning back toward them.
    static func makeCaption(pinCount: Int, isLive: Bool) -> Entity {
        let pivot = Entity()
        pivot.name = Name.caption
        pivot.position = [0, 0.002, Look.side / 2 - Look.inset / 2]
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

    /// `ramp[densityLevel][fadeLevel]` — the tint ramp crossed with the fade
    /// ramp, built once. Coolest (sparse) to hottest (crowded) is the app's
    /// brand teal warming into the podium's gold, so the map is built from
    /// colours the rest of the app already uses (FR-009); within each tint,
    /// level 0 is invisible and the last level is the dot at full strength.
    static func densityRamp() -> [[UnlitMaterial]] {
        let stops = max(2, Look.densityStops)
        let steps = max(1, FloorMapAnimation.Tuning.fadeSteps)
        return (0..<stops).map { level in
            let t = Float(level) / Float(stops - 1)
            let color = blend(PodiumBuilder.Medal.ball, PodiumBuilder.Medal.gold, t)
            let peak = Look.minDotOpacity + (Look.maxDotOpacity - Look.minDotOpacity) * t
            return (0...steps).map { step in
                material(color: color, opacity: peak * Float(step) / Float(steps))
            }
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

    // MARK: - Per-frame update

    /// One frame of the field: every dot takes its current size, and the ones
    /// that are fading take their current rung.
    ///
    /// The material is only reassigned when the rung actually changes, and a
    /// dot that never drops out sits at the top rung forever — so in a typical
    /// frame this is `n` sines and `n` transform writes with **no** material
    /// traffic at all. A fully faded dot is disabled outright rather than drawn
    /// at zero opacity.
    static func update(_ display: Display, at time: TimeInterval) {
        for index in display.dots.indices {
            let dot = display.dots[index]
            let motion = display.motion[index]

            dot.scale = .init(repeating: FloorMapAnimation.scale(motion, at: time))

            let level = FloorMapAnimation.fadeLevel(
                forVisibility: FloorMapAnimation.visibility(motion, at: time)
            )
            guard level != display.levels[index] else { continue }
            display.levels[index] = level

            guard level > 0 else {
                dot.isEnabled = false
                continue
            }
            dot.isEnabled = true
            let row = display.ramp[min(max(display.density[index], 0), display.ramp.count - 1)]
            dot.model?.materials = [row[min(level, row.count - 1)]]
        }
    }
}
