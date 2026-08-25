import XCTest

@testable import IPP

/// Phase 5C testing item 1: the fallback rule — backend pins versus the offline
/// sample. This is the whole of the decision the game depends on, and it is a
/// pure function so it can be pinned here rather than at the device gate.
final class MapPinsServiceTests: XCTestCase {

    private let fallback = [
        GeoPin(latitude: -33.0, longitude: -72.2),
        GeoPin(latitude: -33.1, longitude: -72.3),
    ]
    private let fetched = [
        GeoPin(latitude: -33.04, longitude: -71.62),
        GeoPin(latitude: -33.05, longitude: -71.61),
        GeoPin(latitude: -33.06, longitude: -71.60),
    ]

    func testBackendPinsAreUsedAndMarkedLive() {
        let result = MapPinsService.resolve(fetched: fetched, fallback: fallback)
        XCTAssertEqual(result.pins, fetched)
        XCTAssertTrue(result.isLive)
    }

    func testAnUnreachableBackendFallsBackToTheSample() {
        let result = MapPinsService.resolve(fetched: nil, fallback: fallback)
        XCTAssertEqual(result.pins, fallback)
        XCTAssertFalse(result.isLive)
    }

    func testAnEmptyBackendAnswerCountsAsAMissNotAsLiveData() {
        // "The backend is up but has no patients yet" is exactly the demo case
        // where a blank plate looks broken and the sample looks right.
        let result = MapPinsService.resolve(fetched: [], fallback: fallback)
        XCTAssertEqual(result.pins, fallback)
        XCTAssertFalse(result.isLive)
    }

    func testUnusableCoordinatesAreFilteredOutOfBothSides() {
        let poisoned = fetched + [GeoPin(latitude: .nan, longitude: 0)]
        let result = MapPinsService.resolve(fetched: poisoned, fallback: fallback)
        XCTAssertEqual(result.pins, fetched)
        XCTAssertTrue(result.isLive)

        // A backend answer made up entirely of junk is a miss.
        let allJunk = MapPinsService.resolve(
            fetched: [GeoPin(latitude: .infinity, longitude: .nan)],
            fallback: fallback
        )
        XCTAssertEqual(allJunk.pins, fallback)
        XCTAssertFalse(allJunk.isLive)
    }

    func testWithNothingAnywhereTheMapIsEmptyRatherThanUndefined() {
        let result = MapPinsService.resolve(fetched: nil, fallback: [])
        XCTAssertEqual(result.pins, [])
        XCTAssertFalse(result.isLive)
        XCTAssertEqual(result, FloorMapData.none)
    }

    func testTheWireFormatDecodesToPlainCoordinatesAndDropsEverythingElse() throws {
        // The backend also sends `id` and `anchorKey`; the game must never see
        // them (see GeoPin's doc comment).
        let json = """
        {"pins":[
          {"id":"35200ad8-3ca3-5a89-a368-6376f0f82e21",
           "latitude":-33.03596037947302,
           "longitude":-71.38914117733839,
           "anchorKey":"1fc0295a6d78bd1f69a522f8232ac8fab2e390dceea7f5b10941a416131b3178"}
        ]}
        """
        let decoded = try JSONDecoder().decode(MapPinsResponse.self, from: Data(json.utf8))
        let coordinates = decoded.coordinates

        XCTAssertEqual(coordinates.count, 1)
        XCTAssertEqual(coordinates[0].latitude, -33.03596037947302, accuracy: 1e-12)
        XCTAssertEqual(coordinates[0].longitude, -71.38914117733839, accuracy: 1e-12)
        XCTAssertTrue(coordinates[0].isUsable)
    }

    func testAnEmptyPinArrayDecodesRatherThanThrowing() throws {
        let decoded = try JSONDecoder().decode(
            MapPinsResponse.self,
            from: Data(#"{"pins":[]}"#.utf8)
        )
        XCTAssertTrue(decoded.coordinates.isEmpty)
    }
}
