import Foundation
import SwiftUI

// Manages the form schema's lifecycle: bundled default on first launch,
// disk cache for subsequent launches, network refresh on every launch.
// The UI binds to `@Published var schema` and re-renders when a fresher
// version arrives - but the cached value is always usable, so the form
// keeps working offline.
@MainActor
final class SchemaService: ObservableObject {
    @Published private(set) var schema: FormSchema
    /// Mutable so `AppEnvironment.resolveBackend()` can re-point the schema
    /// refresh at the LAN host discovered at launch (Phase 5C). Set before the
    /// first `refresh()`.
    var baseURL: URL
    private static let cacheKey = "ipp.schema.v1"

    private static var cachedFromDisk: FormSchema? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(FormSchema.self, from: data)
    }

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.schema = Self.cachedFromDisk ?? BundledSchema.value
    }

    func refresh() async {
        do {
            let url = baseURL.appendingPathComponent("api/v1/schema")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                NSLog("SchemaService: non-200 response")
                return
            }
            NSLog("SchemaService: got \(data.count) bytes, decoding...")
            let fetched = try JSONDecoder().decode(FormSchema.self, from: data)
            NSLog("SchemaService: decoded v\(fetched.version) with \(fetched.questions.count) questions")
            schema = fetched
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            NSLog("SchemaService: cached and applied")
        } catch {
            NSLog("SchemaService: refresh failed: \(error)")
        }
    }
}
