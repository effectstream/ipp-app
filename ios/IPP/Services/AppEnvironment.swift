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
        let candidates = BackendLocator.candidates(
            configured: configuredBackendURL,
            isSimulator: BackendLocator.isSimulator
        )
        guard let found = await BackendLocator.probe(candidates),
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
        await mapPins.fetch(baseURL: backendURL)
    }

    func saveAndAnchor(_ patient: Patient) async -> Patient? {
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
        try await apiStore.fetchLeaderboard()
    }

    /// Records a search for ranking points (+10). Best-effort, viewer-safe.
    func recordSearch() async {
        await apiStore.logSearchEvent()
    }

    /// Per-field comparison stats for the patient form (nil for viewers/errors).
    func fetchFieldStats(lat: Double?, lng: Double?) async -> FieldStatsBundle? {
        await apiStore.fetchFieldStats(lat: lat, lng: lng)
    }
}
