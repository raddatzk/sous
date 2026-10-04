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
    /// Set on the row that stands for a built-in template the household
    /// took away — see ``PromptTemplateLibrary/delete(_:)``.
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        text: String,
        sortOrder: Int = 0,
        updatedAt: Date = .nowInSyncPrecision,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// The text without the placeholder, for a preview line.
    public var preview: String {
        text.replacingOccurrences(of: RecipeReplacementPrompt.placeholder, with: "")
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this is (a version of) one of the templates every household starts with.
    public var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }

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

/// A household's templates. The built-in ones are ordinary templates until
/// the household changes them: editing one stores a row under its id that
/// takes its place, deleting one stores a row that hides it, and either can
/// be taken back to the default.
@MainActor
@Observable
public final class PromptTemplateLibrary {
    /// Every row the household stored, built-in overrides and hiding rows included.
    private var stored: [PromptTemplate] = []
    public var errorMessage: String?

    private let store: any PromptTemplateStore

    public init(store: any PromptTemplateStore = InMemoryPromptTemplateStore()) {
        self.store = store
    }

    /// What the cook can pick from: the built-in templates (changed or as
    /// shipped, unless taken away), then the household's own in the order
    /// they were arranged.
    public var all: [PromptTemplate] {
        let builtInIDs = Set(PromptTemplate.builtIn.map(\.id))
        let builtIns = PromptTemplate.builtIn.compactMap { builtIn -> PromptTemplate? in
            guard let row = stored.first(where: { $0.id == builtIn.id }) else { return builtIn }
            return row.deletedAt == nil ? row : nil
        }
        return builtIns + stored.filter { !builtInIDs.contains($0.id) }
    }

    /// Whether a built-in template was changed or taken away.
    public var hasChangedBuiltIns: Bool {
        stored.contains { row in PromptTemplate.builtIn.contains { $0.id == row.id } }
    }

    public func reload() async {
        do {
            stored = try await store.templates().sorted {
                ($0.sortOrder, $0.updatedAt, $0.id.uuidString) < ($1.sortOrder, $1.updatedAt, $1.id.uuidString)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Back to what every household starts with: changed built-in templates
    /// as shipped, taken-away ones back. The household's own stay.
    public func restoreBuiltIns() async {
        do {
            for builtIn in PromptTemplate.builtIn where stored.contains(where: { $0.id == builtIn.id }) {
                try await store.delete(id: builtIn.id)
            }
            await reload()
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
        saved.deletedAt = nil
        if !stored.contains(where: { $0.id == saved.id }) {
            saved.sortOrder = (stored.map(\.sortOrder).max() ?? -1) + 1
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
            if template.isBuiltIn {
                // Not deleted: a row that says "taken away" keeps it from coming back.
                var hidden = template
                hidden.deletedAt = .nowInSyncPrecision
                hidden.updatedAt = .nowInSyncPrecision
                try await store.save(hidden)
            } else {
                try await store.delete(id: template.id)
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
