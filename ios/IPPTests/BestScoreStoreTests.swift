import XCTest

@testable import IPP

/// Throwaway harness used during Phase 4 to exercise `BestScoreStore` for real
/// on a Simulator. Phase 6a adds the permanent test target; this file lives
/// outside the repo on purpose.
///
/// Every case runs against its own `UserDefaults` suite, so the app's real
/// defaults are never touched and the suite can be thrown away afterwards.
final class BestScoreStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "ipp.tests.bestScore.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func store(key: String = BestScoreStore.defaultKey) -> BestScoreStore {
        BestScoreStore(defaults: defaults, key: key)
    }

    func testAFreshStoreHasNoBestScore() {
        XCTAssertEqual(store().best, 0)
    }

    func testTheFirstRealScoreBecomesTheBest() {
        let store = self.store()
        XCTAssertTrue(store.submit(4))
        XCTAssertEqual(store.best, 4)
    }

    func testOnlyAHigherScoreUpdatesTheBest() {
        let store = self.store()
        store.submit(7)

        XCTAssertFalse(store.submit(3), "a worse round must not overwrite the record")
        XCTAssertEqual(store.best, 7)

        XCTAssertFalse(store.submit(7), "matching the record is not beating it")
        XCTAssertEqual(store.best, 7)

        XCTAssertTrue(store.submit(8))
        XCTAssertEqual(store.best, 8)
    }

    func testAScorelessRoundNeverWrites() {
        let store = self.store()
        XCTAssertFalse(store.submit(0))
        XCTAssertFalse(store.submit(-2))
        XCTAssertEqual(store.best, 0)
        XCTAssertNil(defaults.object(forKey: BestScoreStore.defaultKey))
    }

    /// US2 / gate row 4.3: the best score has to survive the app being killed.
    /// A second instance reading the same suite is exactly that — the store
    /// caches nothing, so every read comes back from `UserDefaults`.
    func testTheBestScorePersistsAcrossInstances() {
        store().submit(11)

        let reopened = store()
        XCTAssertEqual(reopened.best, 11)

        XCTAssertFalse(reopened.submit(9))
        XCTAssertTrue(reopened.submit(12))
        XCTAssertEqual(store().best, 12)
    }

    func testStoresOnDifferentKeysDoNotSeeEachOther() {
        let mine = store(key: "ipp.tests.a")
        let theirs = store(key: "ipp.tests.b")
        mine.submit(5)
        XCTAssertEqual(mine.best, 5)
        XCTAssertEqual(theirs.best, 0)
    }

    func testClearingForgetsTheBest() {
        let store = self.store()
        store.submit(6)
        store.clear()
        XCTAssertEqual(store.best, 0)
    }

    /// FR-008: the key is namespaced to the game, so nothing else in the app
    /// can be clobbered by it.
    func testTheDefaultKeyIsNamespacedToTheGame() {
        XCTAssertTrue(BestScoreStore.defaultKey.contains("trophyToss"))
        XCTAssertTrue(BestScoreStore.defaultKey.hasPrefix("com.nonturing.ipp"))
    }
}
