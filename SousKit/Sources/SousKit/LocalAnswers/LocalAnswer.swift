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
/// Brand and EAN make the answer an **own product** (§3 I, phase 7b): an
/// entry of the household's catalog of its own ("Greenforce Sojahack"),
/// which a name links to with a product choice whose target is the
/// product's ``key``. What an answer never says is what the name *is*: the
/// shopping list keeps the written name, its own pantry flag and its own row
/// (R2). See ``LocalAnswerSet`` for the precedence.
public struct LocalAnswer: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// The name counts as an ordinary catalog ingredient. A fallback by
        /// nature: it applies only while the catalog does not know the name,
        /// and falls silent, with a trace, once it does.
        case countsAs
        /// The household buys this product for the name. A purchase choice,
        /// and so an override: it stays when the catalog learns the name.
        case product
        /// The name is a word of its own, without values yet — what the
        /// optimization proposes for a name nothing fairly stands in for
        /// ("Pandanblatt"). It is read and shopped as written and computed as
        /// "keine Nährwerte hinterlegt". A fallback like "zählt wie".
        case word

        /// Falls silent once the catalog knows the name (R3).
        public var isFallback: Bool { self != .product }
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
    /// The catalog word the name counts as, or the product chosen for it —
    /// a catalog id, or an own product's ``key`` ("name:greenforce
    /// sojahack"), which a catalog id never looks like. On an own product,
    /// the generic word it counts like until its label is in.
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

    /// Whether the target is one of the household's own products rather
    /// than a catalog word.
    public var targetsOwnProduct: Bool { targetID.map(Self.isKey) ?? false }

    /// Whether `id` is an answer's ``key`` rather than a catalog id: the
    /// key's prefix is what keeps the two apart.
    public static func isKey(_ id: String) -> Bool {
        id.hasPrefix("name:") || id.hasPrefix("id:")
    }
}
