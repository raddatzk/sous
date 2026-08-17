import Foundation
import Testing
@testable import SousKit

@Suite("Canonical coding")
struct SousCodingTests {
    @Test("Sync-precision timestamps survive a round trip exactly")
    func timestampRoundTrip() throws {
        let date = Date.nowInSyncPrecision
        let data = try SousCoding.encoder.encode(date)
        #expect(try SousCoding.decoder.decode(Date.self, from: data) == date)
    }

    @Test("Truncating to sync precision is idempotent")
    func truncationIsIdempotent() {
        let raw = Date(timeIntervalSince1970: 1_755_432_123.456_789)
        #expect(raw.syncPrecision.syncPrecision == raw.syncPrecision)
    }

    @Test("Equal content encodes to equal bytes")
    func deterministicEncoding() throws {
        let recipe = Recipe(title: "Brot", createdAt: .nowInSyncPrecision, updatedAt: .nowInSyncPrecision)
        let first = try SousCoding.encoder.encode(recipe)
        let second = try SousCoding.encoder.encode(recipe)
        #expect(first == second)
    }
}
