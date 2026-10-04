import Foundation
import Observation

/// A request a household keeps for chat models: "make this vegan, keep the
/// nutrition balanced". Only the task lives here — Sous adds the rules, the
/// catalog and the recipe when the cook copies it (see
/// ``RecipeReplacementPrompt``). A `{{recipe}}` in the text says where the
/// recipe goes.
public struct PromptTemplate: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String
    public var sortOrder: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        text: String,
        sortOrder: Int = 0,
        updatedAt: Date = .nowInSyncPrecision
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }

    /// Nothing worth keeping: no title, or no task.
    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Where a household's templates are kept.
public protocol PromptTemplateStore: Sendable {
    /// Every template of the active household.
    func templates() async throws -> [PromptTemplate]
    /// Upserts by id.
    func save(_ template: PromptTemplate) async throws
    func delete(id: UUID) async throws
}

public actor InMemoryPromptTemplateStore: PromptTemplateStore {
    private var rows: [PromptTemplate]

    public init(_ templates: [PromptTemplate] = []) { rows = templates }

    public func templates() -> [PromptTemplate] { rows }

    public func save(_ template: PromptTemplate) {
        rows.removeAll { $0.id == template.id }
        rows.append(template)
    }

    public func delete(id: UUID) { rows.removeAll { $0.id == id } }
}

extension PromptTemplate {
    /// Templates every household has, in code rather than in the store: two
    /// members opening the app for the first time would otherwise both seed
    /// them, and a household would carry every one twice. They are not
    /// edited; the cook copies one into their own to change it.
    public static let builtIn: [PromptTemplate] = [
        PromptTemplate(
            id: UUID(uuidString: "5B0F2A10-0000-4000-8000-000000000001")!,
            title: "Vegan machen",
            text: "Mache dieses Rezept vegan und achte dabei auf eine ausgewogene Nährwertverteilung.\n\n{{recipe}}"
        ),
        PromptTemplate(
            id: UUID(uuidString: "5B0F2A10-0000-4000-8000-000000000002")!,
            title: "Glutenfrei machen",
            text: "Mache dieses Rezept glutenfrei. Ersetze nur, was nötig ist, und nenne mir, worauf ich beim Einkauf achten muss.\n\n{{recipe}}"
        ),
        PromptTemplate(
            id: UUID(uuidString: "5B0F2A10-0000-4000-8000-000000000003")!,
            title: "Schneller kochen",
            text: "Wie lässt sich dieses Rezept in deutlich kürzerer Zeit zubereiten, ohne dass der Geschmack leidet? Passe die Schritte entsprechend an.\n\n{{recipe}}"
        ),
        PromptTemplate(
            id: UUID(uuidString: "5B0F2A10-0000-4000-8000-000000000004")!,
            title: "Für vier Personen",
            text: "Rechne dieses Rezept auf vier Portionen um. Passe auch Garzeiten und Topfgrößen an, wo es nötig ist.\n\n{{recipe}}"
        ),
    ]
}

/// A household's templates, with the built-in ones in front.
@MainActor
@Observable
public final class PromptTemplateLibrary {
    /// The household's own, in the order they were arranged.
    public private(set) var own: [PromptTemplate] = []
    public var errorMessage: String?

    private let store: any PromptTemplateStore

    public init(store: any PromptTemplateStore = InMemoryPromptTemplateStore()) {
        self.store = store
    }

    /// What the cook can pick from: the built-in templates, then their own.
    public var all: [PromptTemplate] { PromptTemplate.builtIn + own }

    public func reload() async {
        do {
            own = try await store.templates().sorted {
                ($0.sortOrder, $0.updatedAt, $0.id.uuidString) < ($1.sortOrder, $1.updatedAt, $1.id.uuidString)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Adds or changes one. An empty one is not kept.
    public func save(_ template: PromptTemplate) async {
        guard !template.isEmpty else { return }
        var saved = template
        saved.title = template.title.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.text = template.text.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.updatedAt = .nowInSyncPrecision
        if !own.contains(where: { $0.id == saved.id }) {
            saved.sortOrder = (own.map(\.sortOrder).max() ?? -1) + 1
        }
        do {
            try await store.save(saved)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ template: PromptTemplate) async {
        do {
            try await store.delete(id: template.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
