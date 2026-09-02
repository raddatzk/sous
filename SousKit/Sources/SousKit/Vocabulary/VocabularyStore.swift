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

/// What a vocabulary store refuses to write.
public enum VocabularyStoreError: LocalizedError, Equatable {
    /// Filing `child` under `parent` would make the chain run in a circle.
    ///
    /// The relation may be any depth (catalog target, decision A), which is
    /// exactly why this has to be loud: the old rule — a variety of a variety
    /// is refused — made a loop impossible as a side effect, and it refused
    /// *silently*, by handing back nil and dropping the relation with nobody
    /// told. A cycle check that failed the same way would be a relation that
    /// vanishes for a reason the cook cannot see.
    case wouldCycle(child: String, parent: String)

    public var errorDescription: String? {
        switch self {
        case .wouldCycle(let child, let parent):
            "„\(parent)“ ist selbst eine Sorte von „\(child)“ — die Zuordnung würde im Kreis laufen."
        }
    }
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
        // The parent first, before anything about the row is touched: a
        // refused parent must leave the entry exactly as it was, not half
        // applied with the one field that failed left out.
        let parentID: UUID?
        do {
            // A parent named but not yet written comes into being here: the
            // relation is what makes it part of the vocabulary, and the cook
            // should not have to open a second form to say so.
            parentID = try entry.parentName.flatMap { try self.parentID(named: $0, of: row) }
        } catch {
            modelContext.rollback()
            throw error
        }
        row.apply(entry)
        row.parentID = parentID
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
    /// Any depth, but never a loop: walking up from the proposed parent must
    /// not arrive back at the child. An entry as its own parent is the
    /// shortest loop and is refused the same way. The walk is capped so that
    /// a store somehow already holding a cycle cannot hang the write.
    private func parentID(named name: String, of child: StoredIngredientVocabulary) throws -> UUID? {
        let key = IngredientCatalog.normalize(name)
        guard !key.isEmpty else { return nil }
        guard key != child.key else {
            throw VocabularyStoreError.wouldCycle(child: child.name, parent: name)
        }
        if let existing = try row(key: key) {
            var ancestor: StoredIngredientVocabulary? = existing
            var steps = 0
            while let current = ancestor, steps < 64 {
                if current.id == child.id {
                    throw VocabularyStoreError.wouldCycle(child: child.name, parent: name)
                }
                ancestor = try current.parentID.flatMap { try row(id: $0) }
                steps += 1
            }
            return existing.id
        }
        let made = StoredIngredientVocabulary(key: key, name: name)
        modelContext.insert(made)
        return made.id
    }

    private func row(id: UUID) throws -> StoredIngredientVocabulary? {
        var descriptor = FetchDescriptor<StoredIngredientVocabulary>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
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
