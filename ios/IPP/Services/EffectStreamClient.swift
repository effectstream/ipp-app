import Foundation

struct AnchorResponse: Codable {
    let ok: Bool
    let txId: String?
    let chain: String?
}

// Result of GET /api/v1/verify/:rut - on-chain anchor verification.
struct VerifyResult: Codable {
    let rut: String
    let keyHex: String
    let chain: String
    let found: Bool
    let onChainHash: String?
    let anchoredHash: String?
    let localHash: String?
    let chainMatch: Bool
    let recordMatch: Bool
    let chainTxId: String?
    let chainName: String?
    let anchoredAt: String?
    let readError: String?
}

enum EffectStreamError: Error, LocalizedError {
    case badURL
    case httpStatus(Int, String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid backend URL."
        case .httpStatus(let code, let body): return "Backend returned \(code): \(body)"
        case .decoding: return "Could not decode backend response."
        }
    }
}

final class EffectStreamClient {
    /// Mutable so `AppEnvironment.resolveBackend()` can re-point the client at
    /// the LAN host discovered at launch (Phase 5C).
    var baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    convenience init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(baseURL: url)
    }

    func anchorPatientHash(patientId: String, hashHex: String, wallet: Wallet) async throws -> AnchorResponse {
        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
        let payload = "\(patientId)|\(hashHex)|\(timestampMs)"
        let signature = wallet.sign(Data(payload.utf8))

        let body: [String: Any] = [
            "patientId": patientId,
            "hash": hashHex,
            "publicKey": wallet.publicKeyHex,
            "signature": signature,
            "timestamp": timestampMs,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: baseURL.appendingPathComponent("api/v1/patient-hash"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw EffectStreamError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EffectStreamError.httpStatus(http.statusCode, body)
        }
        return try JSONDecoder().decode(AnchorResponse.self, from: data)
    }

    // Reads anchors.lookup(SHA-256(rut)) back from chain via the backend.
    func verify(rut: String) async throws -> VerifyResult {
        let url = baseURL
            .appendingPathComponent("api/v1/verify")
            .appendingPathComponent(rut)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 40

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw EffectStreamError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EffectStreamError.httpStatus(http.statusCode, body)
        }
        return try JSONDecoder().decode(VerifyResult.self, from: data)
    }
}
