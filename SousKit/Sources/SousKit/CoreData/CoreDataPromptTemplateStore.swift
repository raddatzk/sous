import CoreData
import Foundation

/// The Core Data form of a ``PromptTemplate``, a member of its household like
/// every other row. Each field its own attribute, so CloudKit merges two
/// members' edits field by field.
@objc(CDPromptTemplate)
final class CDPromptTemplate: CDHouseholdMember {
    @NSManaged var id: UUID?
    @NSManaged var title: String
    @NSManaged var body: String
    @NSManaged var sortOrder: Int64
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?

    func apply(_ template: PromptTemplate) {
        title = template.title
        body = template.text
        sortOrder = Int64(template.sortOrder)
        updatedAt = template.updatedAt
        deletedAt = template.deletedAt
    }

    var domainValue: PromptTemplate {
        PromptTemplate(
            id: id ?? UUID(),
            title: title,
            text: body,
            sortOrder: Int(sortOrder),
            updatedAt: updatedAt ?? .distantPast,
            deletedAt: deletedAt
        )
    }
}

extension CDPromptTemplate {
    static func fetchRequest() -> NSFetchRequest<CDPromptTemplate> {
        NSFetchRequest<CDPromptTemplate>(entityName: SousManagedObjectModel.promptTemplateEntityName)
    }
}

/// A ``PromptTemplateStore`` backed by Core Data, reading and writing the
/// active household.
public final class CoreDataPromptTemplateStore: PromptTemplateStore, @unchecked Sendable {
    private let context: NSManagedObjectContext

    public init(container: NSPersistentContainer) {
        context = SousPersistentContainer.backgroundContext(for: container)
    }

    public func templates() async throws -> [PromptTemplate] {
        try await context.perform {
            try self.context.fetchInActiveHousehold(CDPromptTemplate.fetchRequest()).map(\.domainValue)
        }
    }

    public func save(_ template: PromptTemplate) async throws {
        try await context.perform {
            let rows = try self.rows(id: template.id)
            // Two members saving the same template at once leave twins; the
            // newest is kept.
            let sorted = rows.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            let row = sorted.first ?? {
                let made = CDPromptTemplate(context: self.context)
                made.id = template.id
                made.createdAt = .nowInSyncPrecision
                return made
            }()
            sorted.dropFirst().forEach(self.context.delete)
            row.apply(template)
            try self.context.save()
        }
    }

    public func delete(id: UUID) async throws {
        try await context.perform {
            try self.rows(id: id).forEach(self.context.delete)
            try self.context.save()
        }
    }

    private func rows(id: UUID) throws -> [CDPromptTemplate] {
        let request = CDPromptTemplate.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        return try context.fetchInActiveHousehold(request)
    }
}
