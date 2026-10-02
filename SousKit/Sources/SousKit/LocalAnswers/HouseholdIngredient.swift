import Foundation

/// What one household says about an ingredient as a fact about itself, not
/// about the ingredient (INGREDIENTS-DATA §3 C): that it is a shelf staple
/// here, where it is bought, what to know at the shelf.
///
/// Keyed like a ``LocalAnswer``: by the catalog id where the catalog knows
/// the ingredient, so a rename in a newer data set detaches nothing, and by
/// the normalized written name otherwise. A name counted as Tofu by a local
/// answer has no id of its own and so keeps its own fields — Tofu's pantry
/// flag and store do not reach it (R2).
///
/// Everything an ingredient *is* — spellings, varieties, aisle, values —
/// belongs to the catalog and is not here.
public struct HouseholdIngredient: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// The catalog word this is about, for an ingredient the catalog knew
    /// when it was written. A rename is followed on read.
    public var catalogID: String?
    /// The name as written: the key where there is no ``catalogID``, and
    /// what the row is shown as either way.
    public var name: String
    public var isPantry: Bool
    public var preferredStore: String?
    public var shoppingNote: String?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        catalogID: String? = nil,
        name: String,
        isPantry: Bool = false,
        preferredStore: String? = nil,
        shoppingNote: String? = nil,
        updatedAt: Date = .nowInSyncPrecision
    ) {
        self.id = id
        self.catalogID = catalogID
        self.name = name
        self.isPantry = isPantry
        self.preferredStore = preferredStore
        self.shoppingNote = shoppingNote
        self.updatedAt = updatedAt
    }

    /// "id:<catalog id>" or "name:<normalized name>", as ``LocalAnswer/key``.
    public var key: String {
        catalogID.map { "id:\($0)" } ?? "name:\(IngredientCatalog.normalize(name))"
    }

    /// A row that says nothing — what a store deletes rather than keeps.
    public var isEmpty: Bool {
        !isPantry && preferredStore == nil && shoppingNote == nil
    }
}

/// Where a household keeps its ingredient fields.
public protocol HouseholdIngredientStore: Sendable {
    /// Every row of the active household, twins included — the library folds
    /// them, newest first.
    func entries() async throws -> [HouseholdIngredient]
    /// Upserts by key and folds away any twin of it. An empty row is deleted
    /// instead, and `nil` returned.
    @discardableResult
    func save(_ entry: HouseholdIngredient) async throws -> HouseholdIngredient?
}

/// A store that keeps nothing beyond the process — for tests, and for a
/// library built where no household store exists.
public actor InMemoryHouseholdIngredientStore: HouseholdIngredientStore {
    private var rows: [HouseholdIngredient]

    public init(_ entries: [HouseholdIngredient] = []) {
        rows = entries
    }

    public func entries() -> [HouseholdIngredient] { rows }

    @discardableResult
    public func save(_ entry: HouseholdIngredient) -> HouseholdIngredient? {
        rows.removeAll { $0.key == entry.key || $0.id == entry.id }
        guard !entry.isEmpty else { return nil }
        var saved = entry
        saved.updatedAt = .nowInSyncPrecision
        rows.append(saved)
        return saved
    }
}
