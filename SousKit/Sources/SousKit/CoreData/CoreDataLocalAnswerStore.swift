import CoreData
import Foundation

/// The Core Data form of a local answer (INGREDIENTS-DATA §3 B), a member of
/// its household like every other row.
///
/// Its own entity rather than new fields on `CDVocabularyEntry` (R8): the
/// vocabulary's `isEmpty` knows only its own fields, and the curation it
/// holds retires in phase 6b. Each part of the answer is its own attribute,
/// so CloudKit merges two members' edits field by field; the values and the
/// weights are one blob each, the shapes being dictionaries.
@objc(CDLocalAnswer)
final class CDLocalAnswer: CDHouseholdMember {
    @NSManaged var id: UUID?
    /// ``LocalAnswer/key``: "id:<catalog id>" or "name:<normalized name>".
    @NSManaged var key: String
    @NSManaged var catalogID: String?
    @NSManaged var name: String
    @NSManaged var kindRaw: String?
    @NSManaged var targetID: String?
    @NSManaged var valuesData: Data?
    @NSManaged var valuesSource: String?
    @NSManaged var weightsData: Data?
    @NSManaged var brand: String?
    @NSManaged var ean: String?
    @NSManaged var categoryRaw: String?
    @NSManaged var parentID: String?
    @NSManaged var spellingsData: Data?
    @NSManaged var displayName: String?
    @NSManaged var baselineData: Data?
    @NSManaged var sharedAt: Date?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?

    func apply(_ answer: LocalAnswer) {
        key = answer.key
        catalogID = answer.catalogID
        name = answer.name
        kindRaw = answer.kind?.rawValue
        targetID = answer.targetID
        valuesData = answer.values.flatMap { try? SousCoding.encoder.encode($0) }
        valuesSource = answer.valuesSource
        weightsData = answer.weights.isEmpty ? nil : try? SousCoding.encoder.encode(answer.weights)
        brand = answer.brand
        ean = answer.ean
        categoryRaw = answer.category?.rawValue
        parentID = answer.parentID
        spellingsData = answer.spellings.isEmpty ? nil : try? SousCoding.encoder.encode(answer.spellings)
        displayName = answer.displayName
        baselineData = answer.baseline.flatMap { $0.isEmpty ? nil : try? SousCoding.encoder.encode($0) }
        sharedAt = answer.sharedAt
        updatedAt = .nowInSyncPrecision
    }

    var domainValue: LocalAnswer {
        LocalAnswer(
            id: id ?? UUID(),
            catalogID: catalogID,
            name: name,
            kind: kindRaw.flatMap(LocalAnswer.Kind.init(rawValue:)),
            targetID: targetID,
            values: valuesData.flatMap { try? SousCoding.decoder.decode(NutritionInfo.self, from: $0) },
            valuesSource: valuesSource,
            weights: weightsData.flatMap {
                try? SousCoding.decoder.decode([String: LocalAnswer.Weight].self, from: $0)
            } ?? [:],
            brand: brand,
            ean: ean,
            category: categoryRaw.flatMap(IngredientCategory.init(rawValue:)),
            parentID: parentID,
            spellings: spellingsData.flatMap { try? SousCoding.decoder.decode([String].self, from: $0) } ?? [],
            displayName: displayName,
            baseline: baselineData.flatMap { try? SousCoding.decoder.decode(CatalogBaseline.self, from: $0) },
            sharedAt: sharedAt,
            updatedAt: updatedAt ?? .distantPast
        )
    }
}

/// A ``LocalAnswerStore`` backed by Core Data, reading and writing the active
/// household.
public final class CoreDataLocalAnswerStore: LocalAnswerStore, @unchecked Sendable {
    private let context: NSManagedObjectContext

    public init(container: NSPersistentContainer) {
        context = SousPersistentContainer.backgroundContext(for: container)
    }

    public func answers() async throws -> [LocalAnswer] {
        try await context.perform {
            let request = CDLocalAnswer.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "key", ascending: true)]
            return try self.context.fetchInActiveHousehold(request).map(\.domainValue)
        }
    }

    @discardableResult
    public func save(_ answer: LocalAnswer) async throws -> LocalAnswer? {
        try await context.perform {
            var rows = try self.rows(key: answer.key)
            // A row found by id whose key changed (a rename written back)
            // is the same answer; it moves rather than leaving a twin.
            for row in try self.rows(id: answer.id) where !rows.contains(row) { rows.append(row) }

            guard !answer.isEmpty else {
                rows.forEach(self.context.delete)
                try self.context.save()
                return nil
            }
            // The newest row is kept and the twins folded into it — the
            // cleanup half of "merged when read".
            rows.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            let row = rows.first ?? {
                let made = CDLocalAnswer(context: self.context)
                made.id = answer.id
                made.createdAt = .nowInSyncPrecision
                return made
            }()
            rows.dropFirst().forEach(self.context.delete)
            row.apply(answer)
            try self.context.save()
            return row.domainValue
        }
    }

    public func delete(_ answer: LocalAnswer) async throws {
        try await context.perform {
            let rows = try self.rows(key: answer.key) + self.rows(id: answer.id)
            guard !rows.isEmpty else { return }
            Set(rows).forEach(self.context.delete)
            try self.context.save()
        }
    }

    public func markShared(keys: Set<String>, at date: Date) async throws {
        try await context.perform {
            let request = CDLocalAnswer.fetchRequest()
            request.predicate = NSPredicate(format: "key IN %@", Array(keys))
            let rows = try self.context.fetchInActiveHousehold(request)
            guard !rows.isEmpty else { return }
            for row in rows { row.sharedAt = date }
            try self.context.save()
        }
    }

    private func rows(key: String) throws -> [CDLocalAnswer] {
        let request = CDLocalAnswer.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", key)
        return try context.fetchInActiveHousehold(request)
    }

    private func rows(id: UUID) throws -> [CDLocalAnswer] {
        let request = CDLocalAnswer.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        return try context.fetchInActiveHousehold(request)
    }
}

extension CDLocalAnswer {
    static func fetchRequest() -> NSFetchRequest<CDLocalAnswer> {
        NSFetchRequest<CDLocalAnswer>(entityName: SousManagedObjectModel.localAnswerEntityName)
    }
}
