import CoreData
import Foundation

/// The Core Data form of a vocabulary entry — the counterpart to
/// ``StoredIngredientVocabulary``.
@objc(CDVocabularyEntry)
final class CDVocabularyEntry: CDHouseholdMember {
    @NSManaged var id: UUID?
    @NSManaged var key: String
    @NSManaged var name: String
    @NSManaged var aliasesJSON: String
    @NSManaged var categoryRaw: String?
    @NSManaged var parentID: UUID?
    @NSManaged var isOwnIngredient: Bool
    @NSManaged var isPantry: Bool
    @NSManaged var needsBasisReview: Bool
    @NSManaged var basisData: Data?
    @NSManaged var unitWeightData: Data?
    @NSManaged var preferredStore: String?
    @NSManaged var shoppingNote: String?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?

    var bases: [String: BasisAssignment] {
        get {
            guard let basisData, !basisData.isEmpty else { return [:] }
            // Loudly in debug, and empty in release — see
            // `StoredIngredientVocabulary.bases` for why that pairing.
            do { return try SousCoding.decoder.decode([String: BasisAssignment].self, from: basisData) }
            catch {
                assertionFailure("Unreadable basis blob: \(error)")
                return [:]
            }
        }
        set { basisData = try? SousCoding.encoder.encode(newValue) }
    }

    var unitWeightsGrams: [String: Double] {
        get {
            guard let unitWeightData else { return [:] }
            return (try? SousCoding.decoder.decode([String: Double].self, from: unitWeightData)) ?? [:]
        }
        set { unitWeightData = try? SousCoding.encoder.encode(newValue) }
    }

    /// Writes everything but the identity and the parent join, which the
    /// store owns.
    func apply(_ entry: IngredientVocabularyEntry) {
        key = entry.key
        name = entry.name
        aliasesJSON = JSONField.encode(entry.aliases)
        categoryRaw = entry.category?.rawValue
        isOwnIngredient = entry.isOwnIngredient
        isPantry = entry.isPantry
        needsBasisReview = entry.needsBasisReview
        bases = entry.bases
        unitWeightsGrams = entry.unitWeightsGrams
        preferredStore = entry.preferredStore
        shoppingNote = entry.shoppingNote
        updatedAt = .nowInSyncPrecision
    }

    /// The domain reading. The parent's *name* is resolved by the store,
    /// which is the only place that can see the other row.
    func domainValue(parentName: String?) -> IngredientVocabularyEntry {
        IngredientVocabularyEntry(
            id: id ?? UUID(),
            name: name,
            aliases: JSONField.decode(aliasesJSON),
            category: categoryRaw.flatMap(IngredientCategory.init(rawValue:)),
            parentName: parentName,
            isOwnIngredient: isOwnIngredient,
            isPantry: isPantry,
            unitWeightsGrams: unitWeightsGrams,
            bases: bases,
            needsBasisReview: needsBasisReview,
            preferredStore: preferredStore,
            shoppingNote: shoppingNote,
            updatedAt: updatedAt ?? .distantPast
        )
    }
}

/// A ``VocabularyStore`` backed by Core Data.
public final class CoreDataVocabularyStore: VocabularyStore, @unchecked Sendable {
    private let context: NSManagedObjectContext

    public init(container: NSPersistentContainer) {
        context = SousPersistentContainer.backgroundContext(for: container)
    }

    public func entries() async throws -> [IngredientVocabularyEntry] {
        try await context.perform {
            let rows = try self.all()
            // The parent's name, resolved in one pass rather than a fetch per
            // row: the relation is stored as an id, and only the store can see
            // across it.
            let nameByID = Dictionary(
                rows.compactMap { row in row.id.map { ($0, row.name) } },
                uniquingKeysWith: { first, _ in first }
            )
            return rows.map { $0.domainValue(parentName: $0.parentID.flatMap { nameByID[$0] }) }
        }
    }

    @discardableResult
    public func save(_ entry: IngredientVocabularyEntry) async throws -> IngredientVocabularyEntry? {
        guard !entry.key.isEmpty else { return nil }

        return try await context.perform {
            let existing = try self.row(key: entry.key)

            guard !entry.isEmpty else {
                if let existing, let id = existing.id {
                    try self.detachChildren(of: id)
                    self.context.delete(existing)
                    try self.context.save()
                }
                return nil
            }

            let row: CDVocabularyEntry
            if let existing {
                row = existing
            } else {
                row = CDVocabularyEntry(context: self.context)
                row.id = entry.id
                row.createdAt = .nowInSyncPrecision
            }
            row.apply(entry)
            // A parent named but not yet written comes into being here: the
            // relation is what makes it part of the vocabulary, and the cook
            // should not have to open a second form to say so.
            row.parentID = try entry.parentName.flatMap { try self.parentID(named: $0, of: row) }
            try self.context.save()
            return row.domainValue(parentName: entry.parentName)
        }
    }

    public func delete(key: String) async throws {
        try await context.perform {
            guard let row = try self.row(key: key), let id = row.id else { return }
            try self.detachChildren(of: id)
            self.context.delete(row)
            try self.context.save()
        }
    }

    /// Writes an entry as it stands, timestamp and all. See
    /// `CoreDataRecipeStore.adopt(_:)` for why the migration needs a door of
    /// its own.
    ///
    /// The parent join is resolved the same way `save` does it, because a
    /// parent is named rather than pointed at: the entry knows the word, and
    /// only the store can turn it into the row's id.
    public func adopt(_ entry: IngredientVocabularyEntry) async throws {
        guard !entry.key.isEmpty else { return }
        try await context.perform {
            let row = try self.row(key: entry.key) ?? {
                let made = CDVocabularyEntry(context: self.context)
                made.id = entry.id
                made.createdAt = .nowInSyncPrecision
                return made
            }()
            row.apply(entry)
            row.updatedAt = entry.updatedAt
            row.parentID = try entry.parentName.flatMap { try self.parentID(named: $0, of: row) }
            try self.context.save()
        }
    }

    /// The id of the entry `name` refers to, creating a bare row for it if
    /// the cook has never said anything else about it.
    ///
    /// Refuses to make a variety of a variety — the relation is one level
    /// deep by design — and refuses to make an entry its own parent.
    private func parentID(named name: String, of child: CDVocabularyEntry) throws -> UUID? {
        let key = IngredientCatalog.normalize(name)
        guard !key.isEmpty, key != child.key else { return nil }
        if let existing = try row(key: key) {
            guard existing.parentID == nil else { return nil }
            return existing.id
        }
        let made = CDVocabularyEntry(context: context)
        let id = UUID()
        made.id = id
        made.key = key
        made.name = name
        made.aliasesJSON = "[]"
        made.createdAt = .nowInSyncPrecision
        made.updatedAt = .nowInSyncPrecision
        return id
    }

    /// A deleted entry must not leave its varieties pointing at nothing.
    private func detachChildren(of id: UUID) throws {
        let request = CDVocabularyEntry.fetchRequest()
        request.predicate = NSPredicate(format: "parentID == %@", id as NSUUID)
        for child in try context.fetchInActiveHousehold(request) {
            child.parentID = nil
            child.updatedAt = .nowInSyncPrecision
        }
    }

    private func all() throws -> [CDVocabularyEntry] {
        let request = CDVocabularyEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        return try context.fetchInActiveHousehold(request)
    }

    private func row(key: String) throws -> CDVocabularyEntry? {
        let request = CDVocabularyEntry.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", key)
        request.fetchLimit = 1
        return try context.fetchInActiveHousehold(request).first
    }
}

extension CDVocabularyEntry {
    static func fetchRequest() -> NSFetchRequest<CDVocabularyEntry> {
        NSFetchRequest<CDVocabularyEntry>(entityName: SousManagedObjectModel.vocabularyEntryEntityName)
    }
}
