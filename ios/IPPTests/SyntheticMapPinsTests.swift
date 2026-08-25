import XCTest

@testable import IPP

/// Phase 5C: the floor map's offline sample. It has to be deterministic (so the
/// map is the same every time), usable (so the projection never has to throw
/// any of it away) and obviously not real.
final class SyntheticMapPinsTests: XCTestCase {

    func testEveryPinIsUsable() {
        let pins = SyntheticMapPins.pins()
        XCTAssertFalse(pins.isEmpty)
        for pin in pins {
            XCTAssertTrue(pin.isUsable, "\(pin)")
        }
    }

    func testTheSampleIsAsBigAsItsClustersSayAndSmallerThanTheDotCap() {
        let expected = SyntheticMapPins.clusters.reduce(0) { $0 + $1.count }
        XCTAssertEqual(SyntheticMapPins.pins().count, expected)
        XCTAssertLessThanOrEqual(expected, FloorMap.Look.maxDots, "the sample is never thinned")
        XCTAssertGreaterThan(expected, 40, "too few dots and it does not read as a map")
    }

    func testTheSameSeedAlwaysGivesTheSameMap() {
        XCTAssertEqual(SyntheticMapPins.pins(), SyntheticMapPins.pins())
        XCTAssertEqual(SyntheticMapPins.pins(seed: 7), SyntheticMapPins.pins(seed: 7))
    }

    func testDifferentSeedsGiveDifferentMaps() {
        XCTAssertNotEqual(SyntheticMapPins.pins(seed: 1), SyntheticMapPins.pins(seed: 2))
    }

    func testThePinsStayNearTheirClusterCentres() {
        // Box–Muller with an unclamped u1 would occasionally throw a pin across
        // the Pacific and blow up the bounding-box fit; 6σ is a generous bound
        // that a broken generator would still fail.
        var index = 0
        let pins = SyntheticMapPins.pins()
        for cluster in SyntheticMapPins.clusters {
            for _ in 0..<cluster.count {
                let pin = pins[index]
                index += 1
                XCTAssertLessThan(
                    abs(pin.latitude - cluster.latitude), cluster.sigma * 6,
                    "pin \(index) wandered off its cluster"
                )
                XCTAssertLessThan(
                    abs(pin.longitude - cluster.longitude), cluster.sigma * 6,
                    "pin \(index) wandered off its cluster"
                )
            }
        }
    }

    func testTheClustersHaveDifferentPopulationsSoTheDensityTintHasSomethingToShow() {
        let counts = SyntheticMapPins.clusters.map(\.count)
        XCTAssertGreaterThan(Set(counts).count, 2)
        XCTAssertGreaterThan(counts.max()!, counts.min()! * 2)
    }

    func testTheSampleIsInOpenWaterWellAwayFromTheRealData() {
        // The real seeded records sit around −71.4…−71.65; the sample lives at
        // least 0.4° (~37 km) further west, in the Pacific. Nobody lives there,
        // so an onlooker reading the offline map learns nothing about anybody.
        for pin in SyntheticMapPins.pins() {
            XCTAssertLessThan(pin.longitude, -72.0, "\(pin) is too close to the coast")
            XCTAssertGreaterThan(pin.longitude, -73.0)
            XCTAssertLessThan(pin.latitude, -32.5)
            XCTAssertGreaterThan(pin.latitude, -33.7)
        }
    }

    func testTheSampleProjectsOntoThePlateWithRealSpread() {
        // The point of the sample is that the map does not look broken: the
        // dots must spread over the plate rather than collapse to a point.
        let pins = SyntheticMapPins.pins()
        let extent = FloorMap.Look.side - 2 * FloorMap.Look.inset
        let fit = FloorMapProjection.fit(pins, extent: extent)
        let points = pins.map(fit.project)

        let widthSpan = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
        let depthSpan = (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
        XCTAssertGreaterThan(max(widthSpan, depthSpan), extent * 0.99, "one axis fills the plate")
        XCTAssertGreaterThan(min(widthSpan, depthSpan), extent * 0.3, "and the other is not a line")
    }

    func testTheSampleProducesMoreThanOneDensityLevel() {
        let pins = SyntheticMapPins.pins()
        let fit = FloorMapProjection.fit(pins, extent: FloorMap.Look.side - 2 * FloorMap.Look.inset)
        let levels = FloorMapProjection.densityLevels(
            for: pins.map(fit.project),
            radius: FloorMap.Look.densityRadius,
            stops: FloorMap.Look.densityStops
        )
        XCTAssertGreaterThan(Set(levels).count, 2, "the offline map should still show heat")
    }
}
