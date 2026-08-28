import XCTest

@testable import IPP

/// Phase 5B task 5B.2 (FR-013): the standings the podium shows are invented on
/// the device, deterministically, and are obviously not real people.
final class SyntheticStandingsTests: XCTestCase {

    // MARK: - Shape of the list

    func testTheDefaultListIsTenPlaces() {
        XCTAssertEqual(SyntheticStandings.defaultCount, 10)
        XCTAssertEqual(SyntheticStandings.standings().count, 10)
    }

    func testRanksAreOneThroughN() {
        let standings = SyntheticStandings.standings()
        XCTAssertEqual(standings.map(\.rank), Array(1...standings.count))
    }

    func testPointsDescendStrictly() {
        for seed in [SyntheticStandings.defaultSeed, 1, 2, 99, .max] as [UInt64] {
            let points = SyntheticStandings.standings(seed: seed).map(\.points)
            for (higher, lower) in zip(points, points.dropFirst()) {
                XCTAssertGreaterThan(higher, lower, "seed \(seed)")
            }
        }
    }

    func testTheTopScoreIsFarAboveAnythingARoundCanProduce() {
        // A 60-second round is worth tens of points (10 per make); the podium
        // is a season table, not a target.
        for seed in [SyntheticStandings.defaultSeed, 7, 12_345] as [UInt64] {
            let standings = SyntheticStandings.standings(seed: seed)
            XCTAssertGreaterThan(standings.first?.points ?? 0, 2_000, "seed \(seed)")
            XCTAssertGreaterThan(standings.last?.points ?? 0, 0, "nobody ends on zero or below")
        }
    }

    func testNamesAreUnique() {
        for seed in [SyntheticStandings.defaultSeed, 3, 1_000] as [UInt64] {
            let names = SyntheticStandings.standings(seed: seed).map(\.name)
            XCTAssertEqual(Set(names).count, names.count, "seed \(seed)")
        }
    }

    func testAskingForMoreThanThePoolsHoldIsClampedRatherThanRepeated() {
        let huge = SyntheticStandings.standings(count: 500)
        XCTAssertGreaterThan(huge.count, 0)
        XCTAssertEqual(Set(huge.map(\.name)).count, huge.count)
    }

    func testAskingForNothingReturnsNothing() {
        XCTAssertTrue(SyntheticStandings.standings(count: 0).isEmpty)
        XCTAssertTrue(SyntheticStandings.standings(count: -4).isEmpty)
    }

    // MARK: - Determinism (the "seeded" in "seeded generator")

    func testTheSameSeedAlwaysProducesTheSameList() {
        for seed in [SyntheticStandings.defaultSeed, 0, 1, 424_242] as [UInt64] {
            XCTAssertEqual(
                SyntheticStandings.standings(seed: seed),
                SyntheticStandings.standings(seed: seed),
                "seed \(seed)"
            )
        }
    }

    func testTheDefaultPodiumIsStableAcrossPlacements() {
        // The player places, relocates, places again — same faces each time.
        XCTAssertEqual(SyntheticStandings.standings(), SyntheticStandings.standings())
    }

    func testDifferentSeedsProduceDifferentLists() {
        let a = SyntheticStandings.standings(seed: 1)
        let b = SyntheticStandings.standings(seed: 2)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Clearly fictional (FR-013)

    func testEverySurnameComesFromThePlaceholderPool() {
        // The point of the pool: a Spanish-speaking doctor cannot mistake
        // "Dra. Marta Ficticia" for a colleague.
        let placeholders = [
            "de Tal", "Fictici", "Ejemplo", "Placebo", "Anónim", "Fulánez", "Menganez",
            "Zutánez", "Perengánez", "Imaginari", "Inventad", "Supuest", "Demostración",
            "Prestad"
        ]
        for seed in [SyntheticStandings.defaultSeed, 5, 55, 555] as [UInt64] {
            for entry in SyntheticStandings.standings(seed: seed) {
                XCTAssertTrue(
                    placeholders.contains { entry.name.contains($0) },
                    "\(entry.name) does not read as fictional"
                )
            }
        }
    }

    func testEveryNameCarriesADoctorsTitle() {
        for entry in SyntheticStandings.standings() {
            XCTAssertTrue(
                entry.name.hasPrefix("Dra. ") || entry.name.hasPrefix("Dr. "),
                entry.name
            )
            XCTAssertTrue(
                entry.shortName.hasPrefix("Dra. ") || entry.shortName.hasPrefix("Dr. "),
                entry.shortName
            )
        }
    }

    func testTheShortNameIsTheTitleAndTheSurnameOfTheFullName() {
        for entry in SyntheticStandings.standings() {
            let surname = entry.shortName
                .replacingOccurrences(of: "Dra. ", with: "")
                .replacingOccurrences(of: "Dr. ", with: "")
            XCTAssertTrue(entry.name.hasSuffix(surname), "\(entry.shortName) vs \(entry.name)")
            XCTAssertLessThan(
                entry.shortName.count, entry.name.count,
                "the short name exists to fit a 10 cm step"
            )
        }
    }

    func testShortNamesFitOnAPodiumStep() {
        // ~19 characters at the label's em size is about 12 cm — a little wider
        // than a step, which is fine for a floating label but not much more.
        for entry in SyntheticStandings.standings() {
            XCTAssertLessThanOrEqual(entry.shortName.count, 20, entry.shortName)
        }
    }

    // MARK: - Formatting

    func testPointsUseTheSpanishThousandsSeparator() {
        XCTAssertEqual(SyntheticStandings.formattedPoints(0), "0")
        XCTAssertEqual(SyntheticStandings.formattedPoints(7), "7")
        XCTAssertEqual(SyntheticStandings.formattedPoints(999), "999")
        XCTAssertEqual(SyntheticStandings.formattedPoints(1_000), "1.000")
        XCTAssertEqual(SyntheticStandings.formattedPoints(4_820), "4.820")
        XCTAssertEqual(SyntheticStandings.formattedPoints(12_345), "12.345")
        XCTAssertEqual(SyntheticStandings.formattedPoints(1_234_567), "1.234.567")
        XCTAssertEqual(SyntheticStandings.formattedPoints(-1_500), "-1.500")
    }

    // The two `crawlLine` cases that used to sit here went with the crawl
    // itself in Phase 5C — the formatter they exercised no longer exists.
}
