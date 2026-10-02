import CoreData
import Foundation

/// The Core Data form of a ``HouseholdIngredient`` (INGREDIENTS-DATA §3 C), a
/// member of its household like every other row. Each field its own
/// attribute, so CloudKit merges two members' edits field by field.
@objc(CDHouseholdIngredient)
final class CDHouseholdIngredient: CDHouseholdMember {
    @NSManaged var id: UUID?
    /// ``HouseholdIngredient/key``: "id:<catalog id>" or "name:<normalized name>".
    @NSManaged var key: String
    @NSManaged var catalogID: String?
    @NSManaged var name: String
    @NSManaged var isPantry: Bool
    @NSManaged var preferredStore: String?
    @NSManaged var shoppingNote: String?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?

    func apply(_ entry: HouseholdIngredient) {
        key = entry.key
        catalogID = entry.catalogID
        name = entry.name
        isPantry = entry.isPantry
        preferredStore = entry.preferredStore
        shoppingNote = entry.shoppingNote
        updatedAt = .nowInSyncPrecision
    }

    var domainValue: HouseholdIngredient {
        HouseholdIngredient(
            id: id ?? UUID(),
            catalogID: catalogID,
            name: name,
            isPantry: isPantry,
            preferredStore: preferredStore,
            shoppingNote: shoppingNote,
            updatedAt: updatedAt ?? .distantPast
        )
    }
}

/// A ``HouseholdIngredientStore`` backed by Core Data, reading and writing the
/// active household.
public final class CoreDataHouseholdIngredientStore: HouseholdIngredientStore, @unchecked Sendable {
    private let context: NSManagedObjectContext

    public init(container: NSPersistentContainer) {
        context = SousPersistentContainer.backgroundContext(for: container)
    }

    public func entries() async throws -> [HouseholdIngredient] {
        try await context.perform {
            let request = CDHouseholdIngredient.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "key", ascending: true)]
            return try self.context.fetchInActiveHousehold(request).map(\.domainValue)
        }
    }

    @discardableResult
    public func save(_ entry: HouseholdIngredient) async throws -> HouseholdIngredient? {
        try await context.perform {
            var rows = try self.rows(key: entry.key)
            // A row found by id whose key changed (a rename followed) is the
            // same row; it moves rather than leaving a twin.
            for row in try self.rows(id: entry.id) where !rows.contains(row) { rows.append(row) }

            guard !entry.isEmpty else {
                rows.forEach(self.context.delete)
                try self.context.save()
                return nil
            }
            // The newest row is kept and the twins folded into it.
            rows.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            let row = rows.first ?? {
                let made = CDHouseholdIngredient(context: self.context)
                made.id = entry.id
                made.createdAt = .nowInSyncPrecision
                return made
            }()
            rows.dropFirst().forEach(self.context.delete)
            row.apply(entry)
            try self.context.save()
            return row.domainValue
        }
    }

    private func rows(key: String) throws -> [CDHouseholdIngredient] {
        let request = CDHouseholdIngredient.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", key)
        return try context.fetchInActiveHousehold(request)
    }

    private func rows(id: UUID) throws -> [CDHouseholdIngredient] {
        let request = CDHouseholdIngredient.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        return try context.fetchInActiveHousehold(request)
    }
}

extension CDHouseholdIngredient {
    static func fetchRequest() -> NSFetchRequest<CDHouseholdIngredient> {
        NSFetchRequest<CDHouseholdIngredient>(entityName: SousManagedObjectModel.householdIngredientEntityName)
    }
}
