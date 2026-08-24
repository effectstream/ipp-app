import Foundation

/// The floor map's offline sample (FR-013, Phase 5C).
///
/// When no backend answers, the app layer hands the game this array instead of
/// real pins (see `MapPinsService.resolve`), so the map under the podium is
/// never a blank plate and the game stays fully playable with no network —
/// which is the property FR-008 and SC-005 protect.
///
/// **Nothing here is real.** The coordinates are invented on the spot by a
/// seeded generator from four fictional cluster centres placed off the Chilean
/// coast, in water, several kilometres from any of the cities the real data
/// uses. Nobody lives at these coordinates, so an onlooker who reads the map
/// while the game is offline learns nothing about anybody.
///
/// The clusters have deliberately different populations and spreads, so the
/// density tint (`FloorMap`) has something to show and the sample map looks
/// like the real one rather than like noise.
///
/// Pure Foundation — no UIKit, no RealityKit, no ARKit, no networking.
enum SyntheticMapPins {

    /// One invented cluster: where it sits, how many pins it holds, and how
    /// far they scatter (1σ, in degrees — 0.01° ≈ 1.1 km).
    struct Cluster {
        let latitude: Double
        let longitude: Double
        let count: Int
        let sigma: Double
    }

    /// Fixed by default so the sample map is the same every time it is shown.
    /// The bytes spell "IPPMAP".
    static let defaultSeed: UInt64 = 0x4950_504D_4150

    /// Four clusters in open water west of Valparaíso: same latitude band as
    /// the real data (so the map's aspect ratio looks familiar) but ~40–60 km
    /// offshore, which puts them in the Pacific.
    static let clusters: [Cluster] = [
        Cluster(latitude: -33.04, longitude: -72.20, count: 34, sigma: 0.016),
        Cluster(latitude: -33.19, longitude: -72.36, count: 22, sigma: 0.011),
        Cluster(latitude: -32.92, longitude: -72.41, count: 15, sigma: 0.022),
        Cluster(latitude: -33.28, longitude: -72.12, count: 9, sigma: 0.008),
    ]

    /// The sample pins. Same seed, same pins, always.
    static func pins(seed: UInt64 = defaultSeed) -> [GeoPin] {
        var generator = SyntheticStandings.Generator(seed: seed)
        var pins: [GeoPin] = []
        pins.reserveCapacity(clusters.reduce(0) { $0 + max(0, $1.count) })

        for cluster in clusters {
            for _ in 0..<max(0, cluster.count) {
                let (dLat, dLng) = gaussianPair(using: &generator)
                pins.append(
                    GeoPin(
                        latitude: cluster.latitude + dLat * cluster.sigma,
                        longitude: cluster.longitude + dLng * cluster.sigma
                    )
                )
            }
        }
        return pins
    }

    /// Two independent standard normals, Box–Muller.
    ///
    /// `u1` is nudged off zero because `log(0)` is `-infinity`, which would
    /// send a pin to a coordinate the projection then has to throw away.
    private static func gaussianPair(
        using generator: inout SyntheticStandings.Generator
    ) -> (Double, Double) {
        let u1 = max(Double.random(in: 0..<1, using: &generator), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &generator)
        let radius = (-2 * log(u1)).squareRoot()
        let angle = 2 * Double.pi * u2
        return (radius * cos(angle), radius * sin(angle))
    }
}
