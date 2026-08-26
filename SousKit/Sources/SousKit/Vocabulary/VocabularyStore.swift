import Foundation
import SwiftData

/// Storage for the cook's vocabulary — the one table that used to be four.
public protocol VocabularyStore: Sendable {
    func entries() async throws -> [IngredientVocabularyEntry]
    /// Upserts by normalized name and hands back what was stored, so a caller
    /// that created an entry learns its identity.
    ///
    /// An entry that no longer says anything is deleted instead: the concept
    /// asks for "silent cleanup of unused, never-confirmed entries", and the
    /// cheapest moment for it is the write that emptied it.
    @discardableResult
    func save(_ entry: IngredientVocabularyEntry) async throws -> IngredientVocabularyEntry?
    func delete(key: String) async throws
}

/// A ``VocabularyStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataVocabularyStore: VocabularyStore {
    public func entries() async throws -> [IngredientVocabularyEntry] {
        let rows = try all()
        let nameByID = Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return rows.map { $0.domainValue(parentName: $0.parentID.flatMap { nameByID[$0] }) }
    }

    @discardableResult
    public func save(_ entry: IngredientVocabularyEntry) async throws -> IngredientVocabularyEntry? {
        guard !entry.key.isEmpty else { return nil }
        let existing = try row(key: entry.key)

        guard !entry.isEmpty else {
            if let existing {
                try detachChildren(of: existing.id)
                modelContext.delete(existing)
                try modelContext.save()
            }
            return nil
        }

        let row = existing ?? {
            let made = StoredIngredientVocabulary(key: entry.key, name: entry.name)
            made.id = entry.id
            modelContext.insert(made)
            return made
        }()
        row.apply(entry)
        // A parent named but not yet written comes into being here: the
        // relation is what makes it part of the vocabulary, and the cook
        // should not have to open a second form to say so.
        row.parentID = try entry.parentName.flatMap { try parentID(named: $0, of: row) }
        try modelContext.save()
        return row.domainValue(parentName: entry.parentName)
    }

    public func delete(key: String) async throws {
        guard let row = try row(key: key) else { return }
        try detachChildren(of: row.id)
        modelContext.delete(row)
        try modelContext.save()
    }

    /// The id of the entry `name` refers to, creating a bare row for it if
    /// the cook has never said anything else about it.
    ///
    /// Refuses to make a variety of a variety — the relation is one level
    /// deep by design — and refuses to make an entry its own parent.
    private func parentID(named name: String, of child: StoredIngredientVocabulary) throws -> UUID? {
        let key = IngredientCatalog.normalize(name)
        guard !key.isEmpty, key != child.key else { return nil }
        if let existing = try row(key: key) {
            guard existing.parentID == nil else { return nil }
            return existing.id
        }
        let made = StoredIngredientVocabulary(key: key, name: name)
        modelContext.insert(made)
        return made.id
    }

    /// A deleted entry must not leave its varieties pointing at nothing.
    private func detachChildren(of id: UUID) throws {
        for child in try modelContext.fetch(
            FetchDescriptor<StoredIngredientVocabulary>(predicate: #Predicate { $0.parentID == id })
        ) {
            child.parentID = nil
            child.updatedAt = .nowInSyncPrecision
        }
    }

    private func all() throws -> [StoredIngredientVocabulary] {
        var descriptor = FetchDescriptor<StoredIngredientVocabulary>()
        descriptor.sortBy = [SortDescriptor(\.name)]
        return try modelContext.fetch(descriptor)
    }

    private func row(key: String) throws -> StoredIngredientVocabulary? {
        var descriptor = FetchDescriptor<StoredIngredientVocabulary>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
