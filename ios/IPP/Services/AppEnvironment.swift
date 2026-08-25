import Foundation
import SwiftUI

@MainActor
final class AppEnvironment: ObservableObject {
    let apiStore: APIPatientStore
    let effectStream: EffectStreamClient
    let session: SessionService
    let schemaService: SchemaService
    /// URL of the web dashboard (map + búsqueda + feedback) embedded in-app.
    let webURL: URL
    /// Reads the backend's anonymized pins for the mini-game's floor map.
    /// Lives here, not in the game, so `ios/IPP/Game/` stays network-free
    /// (FR-008, question Q5 option A).
    let mapPins = MapPinsService()

    var store: PatientStore { apiStore }
    var schema: FormSchema { schemaService.schema }

    @Published var lastAnchor: AnchorResponse?
    @Published var lastError: String?

    /// What `Info.plist` asked for — `http://localhost:3334` in a stock build.
    /// Kept so the launch probe can tell "the user configured a host" from
    /// "nobody configured anything" (see `BackendLocator.candidates`).
    private let configuredBackendURL: URL
    /// The base URL every client is actually using right now. Starts at the
    /// configured value and moves once, if the launch probe finds a LAN host.
    @Published private(set) var backendURL: URL

    /// The one and only backend resolution, kept so that anything that needs a
    /// URL can *wait* for it instead of racing it (question Q8).
    private var resolution: Task<Void, Never>?

    /// What the resolution actually asks the network. A stored closure only so
    /// a test can hold resolution open and prove that dependent work waits;
    /// production never replaces it.
    var probeBackend: @Sendable (_ configured: URL, _ isSimulator: Bool) async -> URL? = {
        configured, isSimulator in
        await BackendLocator.probe(
            BackendLocator.candidates(configured: configured, isSimulator: isSimulator)
        )
    }

    init(
        apiStore: APIPatientStore,
        effectStream: EffectStreamClient,
        session: SessionService,
        schemaService: SchemaService,
        webURL: URL,
        backendURL: URL
    ) {
        self.apiStore = apiStore
        self.effectStream = effectStream
        self.session = session
        self.schemaService = schemaService
        self.webURL = webURL
        self.configuredBackendURL = backendURL
        self.backendURL = backendURL
        // Doctor name on every save comes from the session - the username
        // becomes the leaderboard attribution. Read via a nonisolated,
        // thread-safe snapshot so the API store can call it off the main actor.
        apiStore.doctorNameProvider = { [weak session] in
            session?.currentDoctorName()
        }
        // Sign doctor-scope requests with the logged-in account's ed25519 key.
        // currentSigner() is nonisolated + thread-safe, so the API store can
        // call it while building a request on a background executor.
        apiStore.signerProvider = { [weak session] in
            session?.currentSigner()
        }
    }

    static func live() -> AppEnvironment {
        let backendURLString = Bundle.main.object(forInfoDictionaryKey: "BackendURL") as? String
            ?? "http://localhost:3334"
        let url = URL(string: backendURLString) ?? URL(string: "http://localhost:3334")!
        let webURLString = Bundle.main.object(forInfoDictionaryKey: "WebURL") as? String
            ?? "http://localhost:5174"
        let webURL = URL(string: webURLString) ?? URL(string: "http://localhost:5174")!
        return AppEnvironment(
            apiStore: APIPatientStore(baseURL: url),
            effectStream: EffectStreamClient(baseURL: url),
            session: SessionService(),
            schemaService: SchemaService(baseURL: url),
            webURL: webURL,
            backendURL: url
        )
    }

    // MARK: - Finding the backend on the LAN (Phase 5C)

    /// Probes the candidate hosts once at launch and re-points every client at
    /// whichever answers `/health` first.
    ///
    /// On a phone the bundled `http://localhost:3334` can never work, so this
    /// is what makes the *whole* app — login, patients, field stats, schema,
    /// leaderboard — reach the Mac running the backend. In the Simulator the
    /// candidate list is just the configured URL, so behaviour there is
    /// unchanged.
    ///
    /// Failure is silent and harmless: nothing moves, the app keeps the
    /// configured URL, and every screen shows the offline state it always did.
    func resolveBackend() async {
        await backendReady()
    }

    /// Waits until the backend URL is settled, starting the probe if nobody
    /// has yet, and returns immediately once it is (question Q8).
    ///
    /// Every request in the app goes through this first, so the launch window
    /// in which a screen could fire a request at the *unresolved* URL is
    /// closed: a user who taps straight into Ranking from a cold launch waits
    /// out the probe (~10 ms when the first host answers) instead of sending
    /// one doomed request to `localhost` and self-healing on refresh.
    ///
    /// Resolution happens exactly once per app run — the first caller starts
    /// the task, everyone else awaits the same one — so this is free after
    /// launch.
    func backendReady() async {
        if let resolution {
            return await resolution.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performResolution()
        }
        resolution = task
        await task.value
    }

    private func performResolution() async {
        guard let found = await probeBackend(configuredBackendURL, BackendLocator.isSimulator),
              found != backendURL
        else { return }

        apiStore.baseURL = found
        effectStream.baseURL = found
        schemaService.baseURL = found
        backendURL = found
    }

    /// Read-only fetch of the anonymized map pins for the mini-game's floor
    /// map. `nil` when the backend is unreachable — the caller substitutes the
    /// offline sample (`MapPinsService.resolve`).
    func fetchMapPins() async -> [GeoPin]? {
        await backendReady()
        return await mapPins.fetch(baseURL: backendURL)
    }

    func saveAndAnchor(_ patient: Patient) async -> Patient? {
        await backendReady()
        do {
            guard let wallet = session.wallet else {
                lastError = "Inicia sesión para guardar y anclar."
                return nil
            }
            let saved = try await store.save(patient)
            let hash = try PatientHasher.sha256Hex(saved)
            let response = try await effectStream.anchorPatientHash(
                patientId: saved.id,
                hashHex: hash,
                wallet: wallet
            )
            lastAnchor = response
            lastError = nil
            return saved
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func fetchLeaderboard() async throws -> [LeaderboardEntry] {
        await backendReady()
        return try await apiStore.fetchLeaderboard()
    }

    /// Records a search for ranking points (+10). Best-effort, viewer-safe.
    func recordSearch() async {
        await backendReady()
        await apiStore.logSearchEvent()
    }

    /// Per-field comparison stats for the patient form (nil for viewers/errors).
    func fetchFieldStats(lat: Double?, lng: Double?) async -> FieldStatsBundle? {
        await backendReady()
        return await apiStore.fetchFieldStats(lat: lat, lng: lng)
    }
}
