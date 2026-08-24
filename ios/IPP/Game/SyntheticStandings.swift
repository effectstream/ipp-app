import Foundation

/// Made-up standings for the podium to display (FR-013, added at Gate 5).
///
/// **Nothing here comes from the app.** Not from `/api/v1/leaderboard`, not
/// from `AppEnvironment`, not from disk, not from the network — the mini-game
/// is offline and disconnected from the app's data by FR-008 and SC-005, and it
/// stays that way while wearing a leaderboard's clothes. Every name below is
/// invented in this file, from a fixed pool, by a seeded generator.
///
/// The names are also *obviously* invented, which is the point of the pool:
/// they are built from the Spanish placeholder tradition — Fulano, Mengano,
/// Zutano, Perengano, "de Tal" — plus surnames like *Ficticia*, *Ejemplo* and
/// *Anónimo*. A Spanish-speaking doctor reading "Dra. Marta Ficticia" on the
/// podium cannot mistake it for a colleague's score.
///
/// Determinism is deliberate: the same seed always produces the same list, so
/// the podium looks the same every time the player places it, the tests can
/// assert on it, and nothing has to be stored anywhere (FR-008: the local best
/// score remains the game's only persistence).
///
/// Pure Foundation — no UIKit, no RealityKit, no ARKit.
enum SyntheticStandings {

    /// One fictional entry.
    struct Entry: Equatable {
        /// 1-based place. `1`, `2` and `3` are the podium steps; the rest go in
        /// the crawl.
        let rank: Int
        /// Full display name, e.g. `"Dra. Marta Ficticia"`.
        let name: String
        /// Title plus surname only, e.g. `"Dra. Ficticia"` — what fits on a
        /// 10 cm podium step and still reads at a metre.
        let shortName: String
        let points: Int
    }

    // MARK: - Tuning

    /// How many places the podium knows about: three on the steps and the rest
    /// in the crawl.
    static let defaultCount = 10

    /// Fixed by default so the podium is the same every time it is placed.
    /// Nothing about the game depends on the value; it is a parameter so the
    /// tests can prove determinism with more than one. The bytes spell "IPP2026".
    static let defaultSeed: UInt64 = 0x4950_5032_3032_36

    // MARK: - Generation

    /// The standings, top first.
    ///
    /// - Parameters:
    ///   - count: how many places to invent. Clamped to the size of the name
    ///     pools, so every name is distinct.
    ///   - seed: same seed, same list, always.
    static func standings(count: Int = defaultCount, seed: UInt64 = defaultSeed) -> [Entry] {
        var generator = Generator(seed: seed)

        let wanted = max(0, min(count, min(givenNames.count, surnames.count)))
        guard wanted > 0 else { return [] }

        var people = givenNames.shuffled(using: &generator)
        let houses = surnames.shuffled(using: &generator)
        people.removeSubrange(wanted...)

        var entries: [Entry] = []
        entries.reserveCapacity(wanted)
        var points = topPoints(using: &generator)

        for index in 0..<wanted {
            let person = people[index]
            let surname = houses[index].form(for: person.gender)
            let title = person.gender.title
            entries.append(
                Entry(
                    rank: index + 1,
                    name: "\(title) \(person.name) \(surname)",
                    shortName: "\(title) \(surname)",
                    points: points
                )
            )
            points -= gap(using: &generator)
        }
        return entries
    }

    /// The line the Star Wars crawl shows for a place outside the podium
    /// (FR-013). Spanish, and in the app's own vocabulary — the leaderboard
    /// says "puntos".
    static func crawlLine(for entry: Entry) -> String {
        "\(entry.rank).º  \(entry.name) · \(formattedPoints(entry.points)) puntos"
    }

    /// Points with a Spanish thousands separator: `4820` → `"4.820"`.
    ///
    /// Written out rather than delegated to `NumberFormatter` so the result
    /// cannot change with the device's locale — the podium is a fixed piece of
    /// scenery, not a data display.
    static func formattedPoints(_ points: Int) -> String {
        let digits = String(abs(points))
        var grouped = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 {
                grouped.append(".")
            }
            grouped.append(digit)
        }
        return points < 0 ? "-\(grouped)" : grouped
    }

    // MARK: - Points

    /// The winner's score. Comfortably above anything a 60-second round can
    /// produce (a round is tens of points), so the podium reads as a season
    /// table rather than as something the player is about to beat.
    private static func topPoints(using generator: inout Generator) -> Int {
        4_200 + 5 * Int(generator.next(upperBound: UInt64(180)))
    }

    /// The drop from one place to the next. Always positive, so the list is
    /// strictly descending, and small enough that ten places cannot reach zero
    /// (9 × 340 = 3_060 against a floor of 4_200).
    private static func gap(using generator: inout Generator) -> Int {
        120 + 5 * Int(generator.next(upperBound: UInt64(45)))
    }

    // MARK: - The name pools

    fileprivate enum Gender {
        case feminine
        case masculine

        var title: String {
            switch self {
            case .feminine: return "Dra."
            case .masculine: return "Dr."
            }
        }
    }

    fileprivate struct Person {
        let name: String
        let gender: Gender
    }

    /// A surname that agrees with the given name where Spanish asks it to.
    fileprivate struct Surname {
        let feminine: String
        let masculine: String

        init(_ invariant: String) {
            self.feminine = invariant
            self.masculine = invariant
        }

        init(feminine: String, masculine: String) {
            self.feminine = feminine
            self.masculine = masculine
        }

        func form(for gender: Gender) -> String {
            switch gender {
            case .feminine: return feminine
            case .masculine: return masculine
            }
        }
    }

    /// Ordinary Spanish given names — the half of each name that is *supposed*
    /// to look real, so the podium reads like a leaderboard.
    fileprivate static let givenNames: [Person] = [
        Person(name: "Marta", gender: .feminine),
        Person(name: "Javier", gender: .masculine),
        Person(name: "Lucía", gender: .feminine),
        Person(name: "Álvaro", gender: .masculine),
        Person(name: "Elena", gender: .feminine),
        Person(name: "Diego", gender: .masculine),
        Person(name: "Nuria", gender: .feminine),
        Person(name: "Íñigo", gender: .masculine),
        Person(name: "Carmen", gender: .feminine),
        Person(name: "Sergio", gender: .masculine),
        Person(name: "Irene", gender: .feminine),
        Person(name: "Tomás", gender: .masculine),
        Person(name: "Pilar", gender: .feminine),
        Person(name: "Hugo", gender: .masculine)
    ]

    /// The half that makes the whole thing unmistakably fictional: Spain's
    /// placeholder people (Fulano/Mengano/Zutano/Perengano, "de Tal") turned
    /// into surnames, plus the plainly descriptive ones.
    fileprivate static let surnames: [Surname] = [
        Surname("de Tal"),
        Surname(feminine: "Ficticia", masculine: "Ficticio"),
        Surname("Ejemplo"),
        Surname("Placebo"),
        Surname(feminine: "Anónima", masculine: "Anónimo"),
        Surname("Fulánez"),
        Surname("Menganez"),
        Surname("Zutánez"),
        Surname("Perengánez"),
        Surname(feminine: "Imaginaria", masculine: "Imaginario"),
        Surname(feminine: "Inventada", masculine: "Inventado"),
        Surname(feminine: "Supuesta", masculine: "Supuesto"),
        Surname("Demostración"),
        Surname(feminine: "Prestada", masculine: "Prestado")
    ]

    // MARK: - The generator

    /// SplitMix64 — small, fast, and identical on every device and every OS
    /// version, which `SystemRandomNumberGenerator` is not. Determinism is a
    /// requirement here (FR-013), not a convenience.
    struct Generator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            // A zero seed is a legal SplitMix64 state, but mixing in the
            // constant keeps a caller's "0" from looking special.
            self.state = seed &+ 0x9E37_79B9_7F4A_7C15
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
