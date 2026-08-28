import Foundation
import XCTest

@testable import IPP

/// Phase 5C task 5C.1: which backend the phone tries, and in what order.
/// Phase 6 (question Q7): *where the list comes from* — `Info.plist`, not
/// source — is now part of the contract, so it is asserted here too.
///
/// Deliberately **no LAN address literals in this file**: the ordering cases
/// run against a synthetic pair, and the bundle case reads the expected values
/// out of `Info.plist` itself. That way the suite says nothing about anybody's
/// house, and it keeps passing when the plist is edited for another network.
///
/// Only the ordering and the parsing are tested — that is the whole of the
/// logic. The probe itself is one `URLSession` call per candidate and is
/// exercised for real by the device gate (5C-g2) rather than pretended at here.
final class BackendLocatorTests: XCTestCase {

    private let localhost = URL(string: "http://localhost:3334")!
    /// Stand-ins for "the first host to try" and "the second host to try".
    private let first = URL(string: "http://10.1.2.3:3334")!
    private let second = URL(string: "http://10.1.2.4:3334")!
    private var pair: [URL] { [first, second] }

    // MARK: - Where the list comes from (Q7)

    func testTheCandidateListIsReadFromInfoPlistRatherThanFromSource() {
        // The suite is hosted by the app, so `Bundle.main` is the app bundle
        // and this is the very array a device build would probe.
        let raw = Bundle.main.object(forInfoDictionaryKey: BackendLocator.candidatesInfoKey)
        let declared = raw as? [String]
        XCTAssertNotNil(
            declared,
            "Info.plist must carry a \(BackendLocator.candidatesInfoKey) array of host URLs"
        )
        XCTAssertFalse(declared?.isEmpty ?? true, "a build with no candidates can never find a LAN host")

        XCTAssertEqual(
            BackendLocator.lanCandidates.map(\.absoluteString),
            declared,
            "the probed list must be exactly the plist's, in the plist's order"
        )
    }

    func testEveryCandidateInThisBuildIsAUsablePlainURL() {
        for url in BackendLocator.lanCandidates {
            XCTAssertNotNil(url.scheme, "\(url) has no scheme")
            XCTAssertNotNil(url.host, "\(url) has no host")
            XCTAssertFalse(
                BackendLocator.isLoopback(url),
                "\(url) is loopback — it can never answer on a phone, so it belongs in BackendURL"
            )
        }
    }

    func testAMissingOrMalformedPlistEntryMeansNoCandidatesRatherThanACrash() {
        XCTAssertEqual(BackendLocator.parseCandidates(nil), [])
        XCTAssertEqual(BackendLocator.parseCandidates([String]()), [])
        XCTAssertEqual(BackendLocator.parseCandidates("http://10.1.2.3:3334"), [], "a bare string is not a list")
        XCTAssertEqual(BackendLocator.parseCandidates([1, 2, 3]), [], "a list of non-strings is not a list of URLs")
        XCTAssertEqual(BackendLocator.parseCandidates(["", "   ", "not a url", "/relative/path"]), [])
    }

    func testParsingKeepsOrderTrimsWhitespaceAndDropsOnlyTheJunk() {
        XCTAssertEqual(
            BackendLocator.parseCandidates([
                "  http://10.1.2.3:3334  ",
                "nonsense",
                "http://10.1.2.4:3334",
            ]),
            pair
        )
    }

    // MARK: - Ordering

    func testTheSimulatorOnlyEverTriesTheConfiguredURL() {
        // localhost in the Simulator *is* the Mac running the backend, so
        // reaching for the LAN would be slower and pointless.
        XCTAssertEqual(
            BackendLocator.candidates(configured: localhost, isSimulator: true, lan: pair),
            [localhost]
        )
    }

    func testOnDeviceTheConfiguredCandidatesComeFirstInTheirDeclaredOrder() {
        // The bundled localhost cannot possibly answer on a phone, so it goes
        // last rather than being dropped — if someone ever runs the backend on
        // the device itself, it still works.
        XCTAssertEqual(
            BackendLocator.candidates(configured: localhost, isSimulator: false, lan: pair),
            [first, second, localhost]
        )
    }

    func testWithNoCandidatesConfiguredTheAppJustUsesBackendURL() {
        XCTAssertEqual(
            BackendLocator.candidates(configured: localhost, isSimulator: false, lan: []),
            [localhost]
        )
    }

    func testADeliberatelyConfiguredHostWinsAndIsNotDuplicated() {
        // Someone pointing BackendURL at a real host means it, so it is tried
        // first; and when that host is already one of the candidates it must
        // appear once, not twice.
        XCTAssertEqual(
            BackendLocator.candidates(configured: second, isSimulator: false, lan: pair),
            [second, first]
        )

        let elsewhere = URL(string: "http://10.0.0.7:3334")!
        XCTAssertEqual(
            BackendLocator.candidates(configured: elsewhere, isSimulator: false, lan: pair),
            [elsewhere, first, second]
        )
    }

    func testTheDefaultCandidateListIsTheBundlesOne() {
        // The `lan:` parameter exists for these tests; production callers omit
        // it and must get the plist's list.
        XCTAssertEqual(
            BackendLocator.candidates(configured: localhost, isSimulator: false),
            BackendLocator.lanCandidates + [localhost]
        )
    }

    func testLoopbackIsRecognisedInEveryFormAndPrivateIPsAreNot() {
        for string in [
            "http://localhost:3334",
            "http://LOCALHOST:3334",
            "http://127.0.0.1:3334",
        ] {
            XCTAssertTrue(BackendLocator.isLoopback(URL(string: string)!), string)
        }
        for string in [
            "http://10.1.2.3:3334",
            "http://10.0.0.7:3334",
            "https://api.example.com",
        ] {
            XCTAssertFalse(BackendLocator.isLoopback(URL(string: string)!), string)
        }
    }

    // MARK: - Probing

    func testTheHealthPathIsAppendedWithoutDoublingSlashes() {
        XCTAssertEqual(
            BackendLocator.healthURL(for: first).absoluteString,
            "http://10.1.2.3:3334/health"
        )
        XCTAssertEqual(
            BackendLocator.healthURL(for: URL(string: "http://10.1.2.3:3334/")!).absoluteString,
            "http://10.1.2.3:3334/health"
        )
    }

    func testTheProbeTimeoutIsShortEnoughNotToStallTheLaunch() {
        // Every candidate × the timeout is the worst case a player waits
        // before the app gives up and shows its offline state. Q8 made the
        // first request wait for this, so the bound now matters twice over.
        let worstCase = BackendLocator.defaultTimeout
            * Double(BackendLocator.lanCandidates.count + 1)
        XCTAssertLessThanOrEqual(worstCase, 5)
        XCTAssertGreaterThan(BackendLocator.defaultTimeout, 0.5, "a busy LAN needs some slack")
    }

    func testAnEmptyCandidateListResolvesToNothingWithoutTouchingTheNetwork() async {
        let found = await BackendLocator.probe([], timeout: 0.1)
        XCTAssertNil(found)
    }
}
