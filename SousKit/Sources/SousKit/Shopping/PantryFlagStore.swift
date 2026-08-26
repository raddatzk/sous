import Foundation
import SwiftData

/// Storage for which ingredients the cook declared pantry staples.
public protocol PantryFlagStore: Sendable {
    func flaggedKeys() async throws -> Set<String>
    func setFlagged(_ flagged: Bool, key: String) async throws
}

/// A ``PantryFlagStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataPantryFlagStore: PantryFlagStore {
    public func flaggedKeys() async throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<StoredPantryFlag>()).map(\.key))
    }

    public func setFlagged(_ flagged: Bool, key: String) async throws {
        guard !key.isEmpty else { return }
        var descriptor = FetchDescriptor<StoredPantryFlag>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first

        if flagged, existing == nil {
            modelContext.insert(StoredPantryFlag(key: key))
        } else if !flagged, let existing {
            modelContext.delete(existing)
        } else {
            return
        }
        try modelContext.save()
    }
}
