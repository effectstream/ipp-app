import XCTest

@testable import IPP

/// Throwaway harness used during Phase 4 to exercise `GameRound` for real on a
/// Simulator. Phase 6a adds the permanent test target; this file lives outside
/// the repo on purpose.
///
/// `GameRound` imports nothing but Foundation and reads no clock, so every rule
/// about time can be driven exactly rather than waited for.
final class GameRoundTests: XCTestCase {

    private func round(duration: TimeInterval = 60) -> GameRound {
        var rules = GameRound.Rules()
        rules.duration = duration
        return GameRound(rules: rules)
    }

    // MARK: - Starting

    func testANewRoundIsIdleAndAcceptsFreePractice() {
        let round = self.round()
        XCTAssertEqual(round.state, .idle)
        XCTAssertTrue(round.isIdle)
        XCTAssertFalse(round.isRunning)
        XCTAssertEqual(round.score, 0)
        XCTAssertTrue(round.canStart)
        // Free practice: balls may be thrown, but nothing counts for a round.
        XCTAssertTrue(round.acceptsFlicks)
        XCTAssertFalse(round.countsScores)
    }

    func testStartingPutsTheFullDurationOnTheClock() {
        var round = self.round(duration: 45)
        XCTAssertTrue(round.start())
        XCTAssertEqual(round.state, .running(remaining: 45))
        XCTAssertEqual(round.remaining, 45, accuracy: 1e-9)
        XCTAssertTrue(round.isRunning)
        XCTAssertTrue(round.isTicking)
        XCTAssertTrue(round.acceptsFlicks)
        XCTAssertTrue(round.countsScores)
    }

    func testTheDefaultRoundIsSixtySeconds() {
        var round = GameRound()
        round.start()
        XCTAssertEqual(round.remaining, 60, accuracy: 1e-9)
    }

    func testStartingAgainMidRoundIsRefused() {
        var round = self.round()
        round.start()
        round.tick(10)
        XCTAssertFalse(round.canStart)
        XCTAssertFalse(round.start(), "a running round must not be restarted from under the player")
        XCTAssertEqual(round.remaining, 50, accuracy: 1e-9)
    }

    // MARK: - Ticking down

    func testTickingConsumesTime() {
        var round = self.round(duration: 10)
        round.start()
        XCTAssertFalse(round.tick(3))
        XCTAssertEqual(round.remaining, 7, accuracy: 1e-9)
        XCTAssertFalse(round.tick(3))
        XCTAssertEqual(round.remaining, 4, accuracy: 1e-9)
    }

    func testTickingToZeroEndsTheRoundWithItsScore() {
        var round = self.round(duration: 2)
        round.start()
        round.registerScore()
        round.registerScore()
        round.registerScore()

        XCTAssertFalse(round.tick(1.5))
        XCTAssertTrue(round.tick(0.5), "the tick that empties the clock reports the end")
        XCTAssertEqual(round.state, .ended(score: 3))
        XCTAssertEqual(round.finalScore, 3)
        XCTAssertTrue(round.hasEnded)
        XCTAssertFalse(round.isRunning)
    }

    func testTheEndIsReportedExactlyOnce() {
        var round = self.round(duration: 1)
        round.start()
        XCTAssertTrue(round.tick(5), "an overshooting tick still ends the round")
        XCTAssertFalse(round.tick(5), "…and never ends it a second time")
        XCTAssertFalse(round.tick(5))
    }

    func testTickingDoesNothingBeforeAndAfterARound() {
        var round = self.round(duration: 10)
        XCTAssertFalse(round.tick(5))
        XCTAssertEqual(round.state, .idle)

        round.start()
        round.tick(10)
        XCTAssertEqual(round.state, .ended(score: 0))
        XCTAssertFalse(round.tick(5))
        XCTAssertEqual(round.state, .ended(score: 0), "the summary must not change under the player")
    }

    func testANonPositiveTickIsIgnored() {
        var round = self.round(duration: 10)
        round.start()
        XCTAssertFalse(round.tick(0))
        XCTAssertFalse(round.tick(-4), "a clock that ran backwards must not hand back time")
        XCTAssertEqual(round.remaining, 10, accuracy: 1e-9)
    }

    // MARK: - Pausing (edge cases "tracking loss" and "backgrounding")

    func testPausedTimeIsNotChargedToThePlayer() {
        var round = self.round(duration: 30)
        round.start()
        round.tick(5)

        round.setPaused(true, reason: .trackingLimited)
        XCTAssertTrue(round.isPaused)
        XCTAssertFalse(round.isTicking)

        for _ in 0..<100 {
            XCTAssertFalse(round.tick(1))
        }
        XCTAssertEqual(round.remaining, 25, accuracy: 1e-9, "100 s of paused time consumed the clock")

        round.setPaused(false, reason: .trackingLimited)
        XCTAssertTrue(round.isTicking)
        round.tick(5)
        XCTAssertEqual(round.remaining, 20, accuracy: 1e-9)
    }

    func testAPausedRoundAcceptsNoFlicksAndScoresNothing() {
        var round = self.round()
        round.start()
        round.setPaused(true, reason: .backgrounded)

        XCTAssertFalse(round.acceptsFlicks)
        XCTAssertFalse(round.countsScores)
        XCTAssertFalse(round.registerScore(), "a ball landing while paused must not score")
        XCTAssertEqual(round.score, 0)
    }

    func testEveryPauseReasonMustClearBeforeTheClockRestarts() {
        var round = self.round(duration: 20)
        round.start()
        round.setPaused(true, reason: .trackingLimited)
        round.setPaused(true, reason: .backgrounded)

        round.setPaused(false, reason: .trackingLimited)
        XCTAssertTrue(round.isPaused, "the app is still in the background")
        round.tick(5)
        XCTAssertEqual(round.remaining, 20, accuracy: 1e-9)

        round.setPaused(false, reason: .backgrounded)
        XCTAssertTrue(round.isTicking)
        round.tick(5)
        XCTAssertEqual(round.remaining, 15, accuracy: 1e-9)
    }

    func testPausingIsIdempotent() {
        var round = self.round(duration: 20)
        round.start()
        for _ in 0..<5 { round.setPaused(true, reason: .trackingLimited) }
        round.setPaused(false, reason: .trackingLimited)
        XCTAssertTrue(round.isTicking, "one clear must undo any number of identical pauses")
    }

    func testARoundStartedWhileTrackingIsLostBeginsPaused() {
        var round = self.round(duration: 20)
        round.setPaused(true, reason: .trackingLimited)
        round.start()
        XCTAssertTrue(round.isPaused, "starting must not silently clear a live pause reason")
        round.tick(5)
        XCTAssertEqual(round.remaining, 20, accuracy: 1e-9)
    }

    // MARK: - Flick and score gating (FR-007)

    func testScoresOnlyCountWhileARoundIsTicking() {
        var round = self.round()

        // idle — free practice, counts for no round
        XCTAssertFalse(round.registerScore())
        XCTAssertEqual(round.score, 0)

        round.start()
        XCTAssertTrue(round.registerScore())
        XCTAssertTrue(round.registerScore())
        XCTAssertEqual(round.score, 2)

        round.tick(1000)
        // ended — the summary is frozen
        XCTAssertFalse(round.registerScore())
        XCTAssertEqual(round.finalScore, 2)
    }

    /// Phase 5: the round takes the *amount*, because the tier that earned it
    /// (+1 for touching the cup, the balance of +10 for landing in it) is
    /// `TossController`'s business, not the clock's.
    func testTheRoundBanksWhateverAmountItIsHandedAndOnlyWhileTicking() {
        var round = self.round()
        round.start()

        XCTAssertTrue(round.registerScore(1))
        XCTAssertEqual(round.score, 1)
        XCTAssertTrue(round.registerScore(9), "the make's remainder after an absorbed hit")
        XCTAssertEqual(round.score, 10, "a made ball is worth ten in total")
        XCTAssertTrue(round.registerScore(10), "a clean make with no prior hit")
        XCTAssertEqual(round.score, 20)

        // The default is still the single point, so nothing that predates the
        // two-tier rule changed meaning.
        XCTAssertTrue(round.registerScore())
        XCTAssertEqual(round.score, 21)

        round.setPaused(true, reason: .trackingLimited)
        XCTAssertFalse(round.registerScore(10), "a ball landing while paused pays nobody")
        XCTAssertEqual(round.score, 21)
    }

    func testTheSummaryRefusesFlicksButFreePracticeDoesNot() {
        var round = self.round(duration: 1)
        XCTAssertTrue(round.acceptsFlicks, "free practice before the first round")
        round.start()
        XCTAssertTrue(round.acceptsFlicks)
        round.tick(1)
        XCTAssertFalse(round.acceptsFlicks, "no throwing behind the end-of-round card")
        round.reset()
        XCTAssertTrue(round.acceptsFlicks, "dismissing the summary returns to free practice")
    }

    // MARK: - Replay and reset

    func testPlayingAgainStartsFromAFullClockAndAZeroScore() {
        var round = self.round(duration: 10)
        round.start()
        round.registerScore()
        round.tick(10)
        XCTAssertEqual(round.finalScore, 1)

        XCTAssertTrue(round.start())
        XCTAssertEqual(round.remaining, 10, accuracy: 1e-9)
        XCTAssertEqual(round.score, 0)
        XCTAssertTrue(round.isTicking)
    }

    func testResetReturnsToIdle() {
        var round = self.round(duration: 10)
        round.start()
        round.registerScore()
        round.reset()
        XCTAssertEqual(round.state, .idle)
        XCTAssertEqual(round.score, 0)
        XCTAssertTrue(round.canStart)
    }

    // MARK: - Countdown text

    func testCountdownTextRoundsUpSoTheHudNeverShowsZeroEarly() {
        XCTAssertEqual(GameRound.countdownText(60), "1:00")
        XCTAssertEqual(GameRound.countdownText(59.4), "1:00")
        XCTAssertEqual(GameRound.countdownText(59), "0:59")
        XCTAssertEqual(GameRound.countdownText(9.2), "0:10")
        XCTAssertEqual(GameRound.countdownText(0.1), "0:01")
        XCTAssertEqual(GameRound.countdownText(0), "0:00")
        XCTAssertEqual(GameRound.countdownText(-3), "0:00", "a finished round never shows a negative clock")
    }

    func testCountdownTextTracksTheRound() {
        var round = self.round(duration: 60)
        round.start()
        XCTAssertEqual(round.countdownText, "1:00")
        round.tick(15)
        XCTAssertEqual(round.countdownText, "0:45")
    }

    // MARK: - Rules are the single knob

    func testTheRoundLengthIsASingleConstant() {
        var rules = GameRound.Rules()
        rules.duration = 30
        var round = GameRound(rules: rules)
        round.start()
        XCTAssertEqual(round.remaining, 30, accuracy: 1e-9)
        XCTAssertTrue(round.tick(30))
    }
}
