import Foundation
import XCTest

@testable import IPP

/// Question Q8 — the launch window in which a request could leave with the
/// *unresolved* backend URL.
///
/// Before the fix, `resolveBackend()` was started and forgotten: a user who
/// tapped straight into Ranking within the probe's window sent one request to
/// the bundled `localhost` and got `-1004` before the app self-healed. The fix
/// is `backendReady()`, awaited by every request path.
///
/// These tests hold the probe open on purpose, so "the request waited" is a
/// fact about ordering rather than a race that happens to come out right.
@MainActor
final class AppEnvironmentBackendReadyTests: XCTestCase {

    /// Nothing listens here, in either direction — a request to `resolved`
    /// fails instantly with "connection refused" rather than waiting on a
    /// timeout, which keeps these tests fast and offline.
    private let configured = URL(string: "http://127.0.0.1:2")!
    private let resolved = URL(string: "http://127.0.0.1:1")!

    private func makeEnvironment() -> AppEnvironment {
        AppEnvironment(
            apiStore: APIPatientStore(baseURL: configured),
            effectStream: EffectStreamClient(baseURL: configured),
            session: SessionService(),
            schemaService: SchemaService(baseURL: configured),
            webURL: URL(string: "http://127.0.0.1:3")!,
            backendURL: configured
        )
    }

    /// Installs a probe that answers only once `gate.release()` is called.
    private func gate(_ env: AppEnvironment, answering answer: URL?) -> ProbeGate {
        let gate = ProbeGate()
        env.probeBackend = { _, _ in
            await gate.noteProbe()
            await gate.wait()
            return answer
        }
        return gate
    }

    /// Enough hops for anything that was *not* waiting to have finished.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - The window itself

    func testBackendReadyDoesNotReturnUntilTheProbeHasAnswered() async {
        let env = makeEnvironment()
        let gate = gate(env, answering: resolved)
        let done = Flag()

        let waiter = Task { @MainActor in
            await env.backendReady()
            done.value = true
        }
        await settle()

        XCTAssertFalse(done.value, "backendReady() returned while the probe was still in flight")
        XCTAssertEqual(env.backendURL, configured, "the URL moved before the probe answered")

        await gate.release()
        await waiter.value

        XCTAssertTrue(done.value)
        XCTAssertEqual(env.backendURL, resolved)
        XCTAssertEqual(env.apiStore.baseURL, resolved)
        XCTAssertEqual(env.effectStream.baseURL, resolved)
        XCTAssertEqual(env.schemaService.baseURL, resolved)
    }

    func testARequestStartedMidProbeWaitsForItRatherThanUsingTheStaleURL() async {
        // This is the exact Q8 scenario: an already-authenticated user taps a
        // data screen while the launch probe is still running. Without the
        // await, this call would have completed against `configured` long
        // before the gate opened.
        let env = makeEnvironment()
        let gate = gate(env, answering: resolved)
        let done = Flag()

        let request = Task { @MainActor in
            _ = await env.fetchMapPins()
            done.value = true
        }
        await settle()

        XCTAssertFalse(done.value, "a map-pin fetch outran the probe")
        XCTAssertEqual(env.backendURL, configured)

        await gate.release()
        await request.value

        XCTAssertTrue(done.value)
        XCTAssertEqual(env.backendURL, resolved, "the fetch ran against the resolved URL")
        let probes = await gate.probeCount
        XCTAssertEqual(probes, 1)
    }

    func testTheLeaderboardFetchAlsoWaits() async {
        // The screen the owner actually hit the -1004 on.
        let env = makeEnvironment()
        let gate = gate(env, answering: resolved)
        let done = Flag()

        let request = Task { @MainActor in
            _ = try? await env.fetchLeaderboard()
            done.value = true
        }
        await settle()

        XCTAssertFalse(done.value, "the leaderboard fetch outran the probe")

        await gate.release()
        await request.value
        XCTAssertEqual(env.backendURL, resolved)
    }

    // MARK: - Resolution happens once

    func testConcurrentCallersShareASingleProbe() async {
        let env = makeEnvironment()
        let gate = gate(env, answering: resolved)

        let waiters = (0..<8).map { _ in
            Task { @MainActor in await env.backendReady() }
        }
        await settle()
        await gate.release()
        for waiter in waiters { await waiter.value }

        let probes = await gate.probeCount
        XCTAssertEqual(probes, 1, "the launch probe must run once per app run, not once per caller")
        XCTAssertEqual(env.backendURL, resolved)
    }

    func testOnceResolvedFurtherCallsReturnImmediatelyAndReProbeNothing() async {
        let env = makeEnvironment()
        let gate = gate(env, answering: resolved)

        let first = Task { @MainActor in await env.backendReady() }
        await gate.release()
        await first.value

        // The gate is open now, so a second probe *would* succeed — the point
        // is that it never happens.
        await env.backendReady()
        await env.resolveBackend()
        _ = await env.fetchMapPins()

        let probes = await gate.probeCount
        XCTAssertEqual(probes, 1)
    }

    func testResolveBackendIsJustTheLaunchSpellingOfBackendReady() async {
        // `IPPApp` still calls `resolveBackend()`; it must be the same single
        // resolution the request paths await.
        let env = makeEnvironment()
        let gate = gate(env, answering: resolved)

        let launch = Task { @MainActor in await env.resolveBackend() }
        let request = Task { @MainActor in await env.backendReady() }
        await settle()
        await gate.release()
        await launch.value
        await request.value

        let probes = await gate.probeCount
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(env.backendURL, resolved)
    }

    // MARK: - Nothing reachable

    func testAFailedProbeLeavesTheConfiguredURLInPlaceAndIsNotRetried() async {
        // Offline is a sanctioned outcome, not an error: every screen shows
        // the offline state it always did, and the app does not re-probe on
        // each request (which would make every later request pay the timeout).
        let env = makeEnvironment()
        let gate = gate(env, answering: nil)

        let waiter = Task { @MainActor in await env.backendReady() }
        await gate.release()
        await waiter.value

        XCTAssertEqual(env.backendURL, configured)
        XCTAssertEqual(env.apiStore.baseURL, configured)

        await env.backendReady()
        let probes = await gate.probeCount
        XCTAssertEqual(probes, 1)
    }

    func testAProbeAnsweringTheURLWeAlreadyHaveChangesNothing() async {
        let env = makeEnvironment()
        let gate = gate(env, answering: configured)

        let waiter = Task { @MainActor in await env.backendReady() }
        await gate.release()
        await waiter.value

        XCTAssertEqual(env.backendURL, configured)
        XCTAssertEqual(env.schemaService.baseURL, configured)
    }
}

// MARK: - Helpers

/// A probe that answers only when the test says so.
private actor ProbeGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var probeCount = 0

    func noteProbe() { probeCount += 1 }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }
}

/// A main-actor box, so "did that task finish?" is readable without racing.
@MainActor
private final class Flag {
    var value = false
}
