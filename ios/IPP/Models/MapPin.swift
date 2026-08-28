import Foundation

/// One anonymized data location: a latitude/longitude and nothing else.
///
/// This is the *only* shape in which location data reaches the AR mini-game.
/// The backend's `/api/v1/map-pins` payload also carries a record id and an
/// `anchorKey`; both are dropped at the app layer (``MapPinsService``) so the
/// game — which renders these on a floor plane visible to anyone standing near
/// the phone — never holds anything that could identify a record.
struct GeoPin: Equatable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Both coordinates are real numbers in range. The projection filters on
    /// this rather than trusting the wire.
    var isUsable: Bool {
        latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

/// What the app layer hands the game for its floor map (FR-013).
///
/// `isLive` is not used to decide anything — it only picks the caption, so a
/// person looking at the podium can tell real data from the offline sample
/// without opening a debugger. The game does no networking either way
/// (FR-008, Q5 option A).
struct FloorMapData: Equatable {
    let pins: [GeoPin]
    let isLive: Bool

    init(pins: [GeoPin], isLive: Bool) {
        self.pins = pins
        self.isLive = isLive
    }

    static let none = FloorMapData(pins: [], isLive: false)
}

/// Wire model for `GET /api/v1/map-pins`, the backend's public, anonymized
/// pin list. Read-only; the app never POSTs to it.
struct MapPinsResponse: Decodable {
    struct Pin: Decodable {
        let latitude: Double
        let longitude: Double
    }

    let pins: [Pin]

    var coordinates: [GeoPin] {
        pins.map { GeoPin(latitude: $0.latitude, longitude: $0.longitude) }
    }
}
