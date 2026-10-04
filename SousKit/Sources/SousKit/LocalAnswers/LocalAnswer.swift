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
/// product's ``key``. What a "zählt wie" never says is what the name *is*:
/// the shopping list keeps the written name, its own pantry flag and its own
/// row (R2). See ``LocalAnswerSet`` for the precedence.
///
/// **Overrides of the catalog (phase 7d).** Names differ by region —
/// Brötchen, Semmel, Schrippe — so a household may also say, for one word,
/// in which aisle it is bought (``category``), what it is a variety of
/// (``parentID``), which further spellings mean it (``spellings``), and
/// which of its spellings it is shown by (``displayName``). Unlike a "zählt
/// wie" these are overrides: local wins, and a data update never moves one
/// silently. Where the catalog later says something else at the same
/// place, ``baseline`` is what tells it apart from what the household
/// already saw (``LocalAnswerSet/Applied/conflicts``).
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
    /// The aisle the household buys the word in, over the catalog's.
    public var category: IngredientCategory?
    /// The catalog word this one is a variety of, for the household — over
    /// the catalog's parent, or for a word the catalog does not know. Like
    /// a shipped variety it then shares the parent's aisle, pantry flag,
    /// store and note on the shopping list and inherits its values, while
    /// staying an errand of its own.
    public var parentID: String?
    /// Further spellings that mean this word for the household
    /// ("Schrippe" for Brötchen). A spelling the catalog lacks is plain
    /// identity: the same row on the shopping list, the same pantry flag. A
    /// spelling the catalog gives to another word is *claimed* — said once,
    /// when it is added — and then reads as this word in the household's
    /// recipes ("Pfannkuchen" as Berliner).
    public var spellings: [String]
    /// The spelling the household shows the word by — one of its own,
    /// catalog's or local. What the catalog view, the shopping list and the
    /// suggestions show; never an identity.
    public var displayName: String?
    /// What the catalog said at the overridden places when the household
    /// last decided — at writing, or at "Meine behalten".
    public var baseline: CatalogBaseline?
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
        category: IngredientCategory? = nil,
        parentID: String? = nil,
        spellings: [String] = [],
        displayName: String? = nil,
        baseline: CatalogBaseline? = nil,
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
        self.category = category
        self.parentID = parentID
        self.spellings = spellings
        self.displayName = displayName
        self.baseline = baseline
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
            && brand == nil && ean == nil && !hasOverrides
    }

    /// Whether the answer overrides the catalog anywhere (phase 7d). The
    /// baseline alone is not one: it only remembers what the catalog said.
    public var hasOverrides: Bool {
        category != nil || parentID != nil || !spellings.isEmpty || displayName != nil
    }

    /// Whether the answer says anything about the name's numbers or what it
    /// counts as — everything but the overrides.
    public var hasAnswer: Bool {
        kind != nil || targetID != nil || values != nil || !weights.isEmpty || brand != nil || ean != nil
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

/// What the catalog said at the places a household overrides, when it last
/// decided about them (phase 7d) — the difference between "the catalog
/// disagrees, and the household knows" and "the catalog has changed since".
///
/// A place whose catalog value is the one remembered here stands quietly;
/// one the catalog has moved since is a conflict, asked in the ingredient's
/// detail and in "Abweichungen" until the household takes the catalog's
/// value or keeps its own ("Meine behalten" remembers the new value here).
public struct CatalogBaseline: Codable, Hashable, Sendable {
    /// The aisle the catalog filed the word under.
    public var category: IngredientCategory?
    /// The catalog id of the word's parent, `""` where it had none; `nil`
    /// where nothing was remembered — a word the catalog did not know.
    public var parentID: String?
    /// For each claimed spelling (normalized), the catalog id of the word
    /// the catalog gave it to — the meaning the household confirmed it
    /// overrides.
    public var spellingOwners: [String: String]

    public init(category: IngredientCategory? = nil, parentID: String? = nil, spellingOwners: [String: String] = [:]) {
        self.category = category
        self.parentID = parentID
        self.spellingOwners = spellingOwners
    }

    public var isEmpty: Bool { category == nil && parentID == nil && spellingOwners.isEmpty }
}
