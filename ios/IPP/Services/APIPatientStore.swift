import Foundation

// HTTP-backed PatientStore. Reads/writes the full Patient record via the
// IPP backend, which persists to Neon Postgres. The backend extracts id, RUT
// and coords for indexing; the full record lives in a JSONB column.
final class APIPatientStore: PatientStore {
    /// Mutable so `AppEnvironment.resolveBackend()` can re-point the app at the
    /// LAN host it found at launch (Phase 5C). Written once, from the main
    /// actor, before the first request — same convention as the two provider
    /// closures below.
    var baseURL: URL
    /// Closure returning the current doctor name (or nil). Read lazily so a
    /// rename via the leaderboard UI takes effect on the next save.
    var doctorNameProvider: () -> String? = { nil }

    /// Closure returning the current doctor's request signer (or nil for an
    /// anonymous viewer). Used to sign the gated doctor-scope endpoints.
    var signerProvider: () -> DoctorSigner? = { nil }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(baseURL: URL) { self.baseURL = baseURL }

    func fetchLeaderboard() async throws -> [LeaderboardEntry] {
        let res: LeaderboardResponse = try await get("api/v1/leaderboard")
        return res.entries
    }

    /// Per-field local/country/world aggregates for the discreet form
    /// comparison. Doctor-scope; best-effort (nil for viewers or on error).
    func fetchFieldStats(lat: Double?, lng: Double?, radiusKm: Double = 10) async -> FieldStatsBundle? {
        guard signerProvider() != nil else { return nil }
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/field-stats"),
            resolvingAgainstBaseURL: false
        )
        var items = [URLQueryItem(name: "radiusKm", value: String(radiusKm))]
        if let lat, let lng {
            items.append(URLQueryItem(name: "lat", value: String(lat)))
            items.append(URLQueryItem(name: "lng", value: String(lng)))
        }
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        addAuth(&req)  // signs the path only (query excluded), matching the backend
        return try? await send(req)
    }

    /// Best-effort log of a search action for ranking points. No-op for viewers
    /// (no signer → the backend would 401 anyway). Failures are ignored.
    func logSearchEvent() async {
        guard signerProvider() != nil else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/v1/events"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? encoder.encode(["type": "search"])
        addAuth(&req)
        _ = try? await URLSession.shared.data(for: req)
    }

    func list() async throws -> [Patient] {
        let res: ListResponse = try await get("api/v1/patients")
        return res.patients.map { $0.toPatient() }
    }

    func get(id: String) async throws -> Patient? {
        do {
            let envelope: PatientEnvelope = try await get("api/v1/patients/\(id)")
            return envelope.toPatient()
        } catch APIError.httpStatus(404, _) {
            return nil
        }
    }

    func save(_ patient: Patient) async throws -> Patient {
        var p = patient
        p.updatedAt = Date()
        // Send the canonical (passcode-stripped) copy in `data` so the
        // hash-anchor path computes the same digest server-side later.
        let body = UpsertRequest(
            id: p.id,
            rut: p.rut,
            doctorName: doctorNameProvider(),
            latitude: p.latitude,
            longitude: p.longitude,
            data: p.canonicalCopy()
        )
        let envelope: PatientEnvelope = try await post("api/v1/patients", body: body)
        return envelope.toPatient()
    }

    func delete(id: String) async throws {
        try await sendDelete("api/v1/patients/\(id)")
    }

    // MARK: - HTTP helpers

    // Attach signed-request auth headers (when a doctor is logged in). The
    // signed path must be exactly the URL path the backend sees.
    private func addAuth(_ req: inout URLRequest) {
        guard let signer = signerProvider() else { return }
        let method = req.httpMethod ?? "GET"
        let path = req.url?.path ?? ""
        for (k, v) in signer.headers(method: method, path: path, body: req.httpBody) {
            req.setValue(v, forHTTPHeaderField: k)
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        addAuth(&req)
        return try await send(req)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        addAuth(&req)
        return try await send(req)
    }

    private func sendDelete(_ path: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "DELETE"
        addAuth(&req)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, "")
        }
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpStatus(http.statusCode, body)
        }
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Wire formats

private struct UpsertRequest: Encodable {
    let id: String
    let rut: String
    let doctorName: String?
    let latitude: Double?
    let longitude: Double?
    let data: Patient
}

private struct ListResponse: Decodable {
    let patients: [PatientEnvelope]
}

private struct PatientEnvelope: Decodable {
    let id: String
    let rut: String
    // Plaintext passcode is only present in the POST response for a brand-new
    // patient (shown once). Reads/lookup no longer return it.
    let passcode: String?
    let latitude: Double?
    let longitude: Double?
    let data: Patient

    func toPatient() -> Patient {
        var p = data
        p.passcode = passcode
        // Keep the server's identity in case the JSON inside `data` somehow drifted.
        p.id = id
        return p
    }
}

enum APIError: Error, LocalizedError {
    case malformedResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .malformedResponse: return "Respuesta del servidor inválida."
        case .httpStatus(let code, let body):
            return body.isEmpty ? "Servidor respondió \(code)." : "Servidor respondió \(code): \(body)"
        }
    }
}

struct LeaderboardEntry: Decodable, Identifiable, Hashable {
    let doctor: String
    let total: Int
    let last30: Int
    let fields: Int
    let searches: Int
    let points: Int

    var id: String { doctor }
}

private struct LeaderboardResponse: Decodable {
    let entries: [LeaderboardEntry]
}
