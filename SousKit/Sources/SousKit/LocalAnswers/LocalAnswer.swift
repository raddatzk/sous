import Foundation

/// What one household says about one ingredient name, for the case the
/// catalog cannot answer yet (INGREDIENTS-DATA §3 B): the cook has a packet
/// in hand, and the next data update is days away.
///
/// It can say three things, which combine:
/// - **"zählt wie"** / **a product**: the name counts as a catalog word, for
///   nutrition, weights and aisle (``kind``, ``targetID``);
/// - **own values** per 100 g, with where they were read (``values``);
/// - **own weights** per unit, each with the state it is weighed in
///   (``weights``).
///
/// Brand and EAN make the answer a local product (§3 I). What it never says
/// is what the name *is*: the shopping list keeps the written name, its own
/// pantry flag and its own row (R2). See ``LocalAnswerSet`` for the
/// precedence.
public struct LocalAnswer: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// The name counts as an ordinary catalog ingredient. A fallback by
        /// nature: it applies only while the catalog does not know the name,
        /// and falls silent, with a trace, once it does.
        case countsAs
        /// The household buys this product for the name. A purchase choice,
        /// and so an override: it stays when the catalog learns the name.
        case product
    }

    /// What one of a unit weighs, and in which state — "1 Dose = 240 g,
    /// abgetropft".
    public struct Weight: Codable, Hashable, Sendable {
        public var grams: Double
        public var state: IngredientState?

        public init(grams: Double, state: IngredientState? = nil) {
            self.grams = grams
            self.state = state
        }
    }

    public var id: UUID
    /// The catalog word the answer is about, for a name the catalog knew
    /// when it was written. A rename is followed on read and written back
    /// on the next save (``IngredientCatalog/currentID(for:)``).
    public var catalogID: String?
    /// The name as written: the key where there is no ``catalogID``, and
    /// what the answer is shown as either way.
    public var name: String
    public var kind: Kind?
    /// The catalog word the name counts as, or the product chosen for it.
    /// `nil` on a product means the answer itself is the product: its own
    /// values, brand and EAN.
    public var targetID: String?
    public var values: NutritionInfo?
    /// Where the values were read: "Packung, Marke X".
    public var valuesSource: String?
    /// By unit symbol.
    public var weights: [String: Weight]
    public var brand: String?
    public var ean: String?
    /// When the answer was last sent to the curator; `nil` while unshared.
    public var sharedAt: Date?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        catalogID: String? = nil,
        name: String,
        kind: Kind? = nil,
        targetID: String? = nil,
        values: NutritionInfo? = nil,
        valuesSource: String? = nil,
        weights: [String: Weight] = [:],
        brand: String? = nil,
        ean: String? = nil,
        sharedAt: Date? = nil,
        updatedAt: Date = .nowInSyncPrecision
    ) {
        self.id = id
        self.catalogID = catalogID
        self.name = name
        self.kind = kind
        self.targetID = targetID
        self.values = values
        self.valuesSource = valuesSource
        self.weights = weights
        self.brand = brand
        self.ean = ean
        self.sharedAt = sharedAt
        self.updatedAt = updatedAt
    }

    /// What two rows of one household are the same answer by: the catalog
    /// id where there is one, the normalized written name otherwise. Kept
    /// apart by a prefix, since an id ("tofu") and a name can be spelled
    /// alike.
    public var key: String {
        catalogID.map { "id:\($0)" } ?? "name:\(writtenKey)"
    }

    /// The written name as it is compared.
    public var writtenKey: String { IngredientCatalog.normalize(name) }

    /// An answer that says nothing — what a store deletes rather than keeps.
    public var isEmpty: Bool {
        kind == nil && targetID == nil && values == nil && weights.isEmpty
            && brand == nil && ean == nil
    }

    /// Whether the answer describes a product of its own (§3 I).
    public var isLocalProduct: Bool { brand != nil || ean != nil }
}
