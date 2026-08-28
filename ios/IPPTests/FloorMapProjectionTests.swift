import XCTest
import simd

@testable import IPP

/// Phase 5C testing item 1: the lat/lng → floor-plane projection, including the
/// degenerate cases that would otherwise reach RealityKit as `NaN` and take the
/// game down with them.
final class FloorMapProjectionTests: XCTestCase {

    private let extent: Float = 0.88

    // MARK: - Bounding-box fit

    func testAPinSetIsCentredOnThePlate() {
        // Two pins on a north–south line: they must straddle the centre.
        let pins = [
            GeoPin(latitude: -33.00, longitude: -71.60),
            GeoPin(latitude: -33.10, longitude: -71.60),
        ]
        let fit = FloorMapProjection.fit(pins, extent: extent)
        let points = pins.map(fit.project)

        XCTAssertEqual(points[0].x, 0, accuracy: 1e-5)
        XCTAssertEqual(points[1].x, 0, accuracy: 1e-5)
        XCTAssertEqual(points[0].y + points[1].y, 0, accuracy: 1e-5, "symmetric about the centre")
    }

    func testTheDominantAxisFillsTheExtentExactly() {
        let pins = [
            GeoPin(latitude: -33.00, longitude: -71.60),
            GeoPin(latitude: -33.10, longitude: -71.60),
        ]
        let fit = FloorMapProjection.fit(pins, extent: extent)
        let points = pins.map(fit.project)

        XCTAssertEqual(abs(points[0].y - points[1].y), extent, accuracy: 1e-4)
    }

    func testNorthIsAwayFromThePlayer() {
        // The podium faces the player along +Z, so a higher latitude has to
        // land further away, i.e. at a smaller z.
        let north = GeoPin(latitude: -33.00, longitude: -71.60)
        let south = GeoPin(latitude: -33.10, longitude: -71.60)
        let fit = FloorMapProjection.fit([north, south], extent: extent)

        XCTAssertLessThan(fit.project(north).y, fit.project(south).y)
    }

    func testEastIsToThePlayersRight() {
        let west = GeoPin(latitude: -33.05, longitude: -71.70)
        let east = GeoPin(latitude: -33.05, longitude: -71.50)
        let fit = FloorMapProjection.fit([west, east], extent: extent)

        XCTAssertLessThan(fit.project(west).x, fit.project(east).x)
    }

    func testTheAspectRatioIsPreservedRatherThanStretchedToFill() {
        // A set twice as wide as it is tall must stay twice as wide: the
        // shorter axis uses less than the full extent.
        let pins = [
            GeoPin(latitude: -33.00, longitude: -71.70),
            GeoPin(latitude: -33.00, longitude: -71.50),
            GeoPin(latitude: -33.05, longitude: -71.70),
            GeoPin(latitude: -33.05, longitude: -71.50),
        ]
        let fit = FloorMapProjection.fit(pins, extent: extent)
        let points = pins.map(fit.project)
        let widthSpan = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
        let depthSpan = (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)

        XCTAssertEqual(widthSpan, extent, accuracy: 1e-4, "the wide axis fills the plate")
        XCTAssertLessThan(depthSpan, extent * 0.9, "the short axis must not be stretched")
        XCTAssertGreaterThan(depthSpan, 0)
    }

    func testLongitudeIsCompressedByTheCosineOfTheLatitude() {
        // At Valparaíso's latitude a degree of longitude is ~0.838 of a degree
        // of latitude on the ground; ignoring that would smear the map
        // east–west by 19 %.
        let pins = [
            GeoPin(latitude: -33.05, longitude: -71.70),
            GeoPin(latitude: -33.05, longitude: -71.50),
        ]
        let fit = FloorMapProjection.fit(pins, extent: extent)
        XCTAssertEqual(fit.longitudeScale, cos(-33.05 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(fit.longitudeScale, 0.838, accuracy: 0.005)
    }

    // MARK: - Degenerate inputs

    func testASinglePinSitsDeadCentre() {
        let pin = GeoPin(latitude: -33.05, longitude: -71.60)
        let fit = FloorMapProjection.fit([pin], extent: extent)
        let point = fit.project(pin)

        XCTAssertEqual(point.x, 0, accuracy: 1e-6)
        XCTAssertEqual(point.y, 0, accuracy: 1e-6)
        XCTAssertEqual(fit.metresPerDegree, 0, "no extent to scale to")
    }

    func testEveryPinAtTheSameCoordinateCollapsesToTheCentreWithoutDividingByZero() {
        let pin = GeoPin(latitude: -33.05, longitude: -71.60)
        let pins = Array(repeating: pin, count: 40)
        let fit = FloorMapProjection.fit(pins, extent: extent)

        for point in pins.map(fit.project) {
            XCTAssertTrue(point.x.isFinite && point.y.isFinite)
            XCTAssertEqual(simd_length(point), 0, accuracy: 1e-6)
        }
    }

    func testAnEmptyPinListStillProducesAUsableFit() {
        let fit = FloorMapProjection.fit([], extent: extent)
        let point = fit.project(GeoPin(latitude: -33.05, longitude: -71.60))
        XCTAssertTrue(point.x.isFinite && point.y.isFinite)
    }

    func testAZeroExtentPlateProducesNoNaN() {
        let fit = FloorMapProjection.fit(
            [GeoPin(latitude: -33.0, longitude: -71.5), GeoPin(latitude: -33.1, longitude: -71.6)],
            extent: 0
        )
        let point = fit.project(GeoPin(latitude: -33.05, longitude: -71.55))
        XCTAssertTrue(point.x.isFinite && point.y.isFinite)
    }

    func testNonFiniteAndOutOfRangeCoordinatesAreRejectedRatherThanProjected() {
        let bad = [
            GeoPin(latitude: .nan, longitude: -71.6),
            GeoPin(latitude: -33.0, longitude: .nan),
            GeoPin(latitude: .infinity, longitude: .infinity),
            GeoPin(latitude: 91, longitude: 0),
            GeoPin(latitude: 0, longitude: -181),
        ]
        for pin in bad {
            XCTAssertFalse(pin.isUsable, "\(pin)")
        }

        // …and one that slips into a fit alongside good pins projects to the
        // centre instead of poisoning the plate.
        let good = [
            GeoPin(latitude: -33.00, longitude: -71.60),
            GeoPin(latitude: -33.10, longitude: -71.50),
        ]
        let fit = FloorMapProjection.fit(good + bad, extent: extent)
        for pin in bad {
            let point = fit.project(pin)
            XCTAssertTrue(point.x.isFinite && point.y.isFinite, "\(pin)")
            XCTAssertEqual(simd_length(point), 0, accuracy: 1e-6)
        }
        // The good pins still fill the plate: the bad ones did not widen the
        // bounding box.
        XCTAssertEqual(abs(fit.project(good[0]).y - fit.project(good[1]).y), extent, accuracy: 1e-4)
    }

    func testNothingEverLandsOutsideThePlate() {
        let pins = [
            GeoPin(latitude: -33.00, longitude: -71.60),
            GeoPin(latitude: -33.10, longitude: -71.50),
        ]
        let fit = FloorMapProjection.fit(pins, extent: extent)
        let half = extent / 2 + 1e-4

        // Sweep well outside the fitted set, including the far side of the
        // planet.
        for latitude in stride(from: -90.0, through: 90.0, by: 7.5) {
            for longitude in stride(from: -180.0, through: 180.0, by: 15.0) {
                let point = fit.project(GeoPin(latitude: latitude, longitude: longitude))
                XCTAssertLessThanOrEqual(abs(point.x), half, "\(latitude),\(longitude)")
                XCTAssertLessThanOrEqual(abs(point.y), half, "\(latitude),\(longitude)")
            }
        }
    }

    // MARK: - Thinning

    func testASmallPinSetIsNotThinnedAtAll() {
        let pins = (0..<10).map { GeoPin(latitude: Double($0), longitude: 0) }
        XCTAssertEqual(FloorMapProjection.sample(pins, limit: 260), pins)
    }

    func testALargePinSetIsThinnedToExactlyTheLimit() {
        let pins = (0..<960).map { GeoPin(latitude: Double($0) / 100, longitude: 0) }
        let sampled = FloorMapProjection.sample(pins, limit: 260)

        XCTAssertEqual(sampled.count, 260)
        XCTAssertTrue(sampled.allSatisfy { pins.contains($0) })
    }

    func testThinningKeepsTheSpreadRatherThanTakingAPrefix() {
        // The seeded data arrives grouped by city, so a prefix would show one
        // city. Stride sampling has to reach the end of the list.
        let pins = (0..<960).map { GeoPin(latitude: Double($0) / 100, longitude: 0) }
        let sampled = FloorMapProjection.sample(pins, limit: 260)

        XCTAssertEqual(sampled.first, pins.first)
        XCTAssertGreaterThan(sampled.last!.latitude, pins[900].latitude, "never reached the tail")
        // Strictly increasing, i.e. it walks the list once in order.
        for (a, b) in zip(sampled, sampled.dropFirst()) {
            XCTAssertLessThan(a.latitude, b.latitude)
        }
    }

    func testThinningToNothingIsAnEmptyMapNotACrash() {
        let pins = (0..<50).map { GeoPin(latitude: Double($0), longitude: 0) }
        XCTAssertEqual(FloorMapProjection.sample(pins, limit: 0).count, 0)
        XCTAssertEqual(FloorMapProjection.sample(pins, limit: -3).count, 0)
        XCTAssertEqual(FloorMapProjection.sample([], limit: 260).count, 0)
    }

    // MARK: - Density tint

    func testAUniformlySpreadSetGetsAUniformTint() {
        let points = (0..<9).map { index in
            SIMD2<Float>(Float(index % 3) * 0.3, Float(index / 3) * 0.3)
        }
        let levels = FloorMapProjection.densityLevels(for: points, radius: 0.05, stops: 5)
        XCTAssertEqual(Set(levels).count, 1, "nobody has a neighbour, so nobody is hotter")
    }

    func testACrowdedNeighbourhoodRunsHotAndALonePinRunsCold() {
        var points = (0..<12).map { index in
            SIMD2<Float>(0.01 * Float(index % 4), 0.01 * Float(index / 4))
        }
        let loner = SIMD2<Float>(0.45, 0.45)
        points.append(loner)

        let levels = FloorMapProjection.densityLevels(for: points, radius: 0.05, stops: 5)
        XCTAssertEqual(levels.last, 0, "the isolated pin is the coldest")
        XCTAssertEqual(levels.dropLast().max(), 4, "the cluster reaches the top of the ramp")
    }

    func testEveryLevelIndexesTheRamp() {
        let points = (0..<200).map { index in
            SIMD2<Float>(
                Float(index % 20) * 0.02 - 0.2,
                Float(index / 20) * 0.05 - 0.2
            )
        }
        for stops in [2, 3, 5, 8] {
            let levels = FloorMapProjection.densityLevels(for: points, radius: 0.05, stops: stops)
            XCTAssertEqual(levels.count, points.count)
            XCTAssertTrue(levels.allSatisfy { (0..<stops).contains($0) }, "stops=\(stops)")
        }
    }

    func testDegenerateTintRequestsAnswerRatherThanCrash() {
        let points = [SIMD2<Float>(0, 0), SIMD2<Float>(0.01, 0)]
        XCTAssertEqual(FloorMapProjection.densityLevels(for: [], radius: 0.05, stops: 5), [])
        XCTAssertEqual(
            FloorMapProjection.densityLevels(for: points, radius: 0.05, stops: 1),
            [0, 0]
        )
        XCTAssertEqual(
            FloorMapProjection.densityLevels(for: points, radius: 0, stops: 5),
            [0, 0]
        )
    }

    // MARK: - Caption

    func testTheCaptionNamesTheSourceSoTheGateIsDecidableByEye() {
        let live = FloorMapProjection.caption(pinCount: 260, isLive: true)
        let sample = FloorMapProjection.caption(pinCount: 80, isLive: false)

        XCTAssertTrue(live.contains("en vivo"), live)
        XCTAssertTrue(live.contains("260"), live)
        XCTAssertTrue(sample.contains("ejemplo"), sample)
        XCTAssertTrue(sample.contains("80"), sample)
        XCTAssertNotEqual(live, sample)
    }

    func testTheCaptionIsGrammaticalSpanishForOneLocation() {
        XCTAssertTrue(
            FloorMapProjection.caption(pinCount: 1, isLive: true).contains("1 ubicación"),
            "singular, not '1 ubicaciones' (FR-009)"
        )
        XCTAssertTrue(
            FloorMapProjection.caption(pinCount: 0, isLive: false).contains("0 ubicaciones")
        )
    }
}
