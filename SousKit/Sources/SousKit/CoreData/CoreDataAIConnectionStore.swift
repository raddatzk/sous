import CoreData
import Foundation

/// The Core Data form of the household's ``AIConnection``, a member of its
/// household like every other row.
@objc(CDAIConnection)
final class CDAIConnection: CDHouseholdMember {
    @NSManaged var providerName: String
    @NSManaged var kindRaw: String
    @NSManaged var baseURL: String
    @NSManaged var model: String
    @NSManaged var effort: String?
    @NSManaged var disablesThinking: Bool
    @NSManaged var apiKey: String
    @NSManaged var updatedAt: Date?

    func apply(_ connection: AIConnection) {
        providerName = connection.provider.name
        kindRaw = connection.provider.kind.rawValue
        baseURL = connection.provider.baseURL.absoluteString
        model = connection.provider.model
        effort = connection.provider.effort
        disablesThinking = connection.provider.disablesThinking ?? false
        apiKey = connection.apiKey
        updatedAt = .nowInSyncPrecision
    }

    /// `nil` where the row holds no address, or one that is none.
    var domainValue: AIConnection? {
        guard let url = URL(string: baseURL), url.host() != nil else { return nil }
        return AIConnection(
            provider: LLMProvider(
                name: providerName,
                kind: LLMProviderKind(rawValue: kindRaw) ?? .openAICompatible,
                baseURL: url, model: model, effort: effort,
                disablesThinking: disablesThinking ? true : nil),
            apiKey: apiKey)
    }
}

extension CDAIConnection {
    static func fetchRequest() -> NSFetchRequest<CDAIConnection> {
        NSFetchRequest<CDAIConnection>(entityName: SousManagedObjectModel.aiConnectionEntityName)
    }
}

/// A ``HouseholdAIConnectionStore`` backed by Core Data, reading and writing
/// the active household.
public final class CoreDataAIConnectionStore: HouseholdAIConnectionStore, @unchecked Sendable {
    private let context: NSManagedObjectContext

    public init(container: NSPersistentContainer) {
        context = SousPersistentContainer.backgroundContext(for: container)
    }

    public func load() async throws -> AIConnection? {
        try await context.perform {
            try self.rows().first?.domainValue
        }
    }

    public func save(_ connection: AIConnection) async throws {
        try await context.perform {
            // Two members saving at once leave twins; the newest is kept.
            let rows = try self.rows()
            let row = rows.first ?? CDAIConnection(context: self.context)
            rows.dropFirst().forEach(self.context.delete)
            row.apply(connection)
            try self.context.save()
        }
    }

    public func delete() async throws {
        try await context.perform {
            try self.rows().forEach(self.context.delete)
            try self.context.save()
        }
    }

    /// Newest first.
    private func rows() throws -> [CDAIConnection] {
        try context.fetchInActiveHousehold(CDAIConnection.fetchRequest())
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }
}
