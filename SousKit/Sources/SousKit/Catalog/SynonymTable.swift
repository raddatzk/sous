import Foundation

/// One BLS row a kitchen word can mean, and how well it means it.
public struct SynonymTarget: Codable, Hashable, Sendable {
    public var code: String
    public var state: IngredientState
    /// Higher wins. The heaviest target per state is what the app computes
    /// with; the rest are the alternatives the picker will offer in phase 4.
    /// Weights come from *how* the mapping was found — the word being the BLS
    /// name outranks one of its aliases being it, and both outrank a further
    /// doneness variant of the same food.
    public var weight: Double

    public init(code: String, state: IngredientState, weight: Double) {
        self.code = code
        self.state = state
        self.weight = weight
    }
}

/// A kitchen word: what it is called, what else it answers to, and which BLS
/// rows it means.
public struct SynonymEntry: Codable, Hashable, Sendable {
    public var word: String
    public var aliases: [String]
    public var category: IngredientCategory
    /// The rows this word resolves to. May be empty — a word can carry
    /// identity without carrying nutrition, which is the whole point of the
    /// spices being here: they are known ingredients whose gap has a name.
    public var targets: [SynonymTarget]
    /// Further BLS rows found by name, offered to the cook but never computed
    /// with. Kept apart from `targets` on purpose: a word deliberately left
    /// without values must not quietly acquire some because the catalog
    /// happens to contain a row whose name starts the same way.
    public var candidates: [String]
    /// `curated` for a word a person wrote down, `bls` for one that is a BLS
    /// name itself.
    public var origin: String
    /// The word this one is a *variety* of — "Cocktailtomate" of "Tomate".
    ///
    /// Curated, never guessed at run time: a spelling and a variety look the
    /// same from the outside ("Cocktailtomaten" could be either), and the
    /// difference decides whether the shopping list may add two lines up. The
    /// aliases stay what they always were — other ways of writing *this*
    /// word — and the varieties that were hiding among them are their own
    /// words now, with a parent.
    public var parent: String?

    public init(
        word: String, aliases: [String] = [], category: IngredientCategory,
        targets: [SynonymTarget] = [], candidates: [String] = [],
        origin: String = "curated", parent: String? = nil
    ) {
        self.word = word
        self.aliases = aliases
        self.category = category
        self.targets = targets
        self.candidates = candidates
        self.origin = origin
        self.parent = parent
    }

    /// Whether `target` is this word's own row rather than a mapping onto
    /// someone else's — the word is a BLS name and the row is the one it
    /// names, at full weight.
    ///
    /// This is the whole difference between "the recipe wrote the catalog's
    /// word" (nothing to confirm) and "a kitchen word was mapped onto a
    /// catalog row" (exactly what the cook confirms). See
    /// `NutritionCatalog.make`.
    public func isCatalogsOwnName(for target: SynonymTarget) -> Bool {
        origin == "bls" && target.weight >= 1
    }

    /// The row this word means in `state` — the heaviest target, ties going to
    /// the one listed first.
    public func target(for state: IngredientState) -> SynonymTarget? {
        targets.filter { $0.state == state }.max { $0.weight < $1.weight }
    }

    /// Every code this word could mean, best first: what phase 4's picker
    /// lists, and what phase 3 already carries through the result without
    /// showing it.
    public var candidateCodes: [String] {
        var seen = Set<String>()
        return (targets.sorted { $0.weight > $1.weight }.map(\.code) + candidates)
            .filter { seen.insert($0).inserted }
    }
}

/// Kitchen word → BLS codes: the bridge between how a recipe is written and
/// how a food catalog is written.
///
/// The concept's "single biggest lever for hit rate", and its permanent
/// curation cost. It is shipped data, replaced wholesale on an app update,
/// which is why nothing the cook owns may ever point *into* it by object
/// reference — only by code, stored as a value.
public struct SynonymTable: Sendable {
    private struct File: Codable {
        var words: [SynonymEntry]
    }

    public private(set) var entries: [SynonymEntry]
    private var byKey: [String: SynonymEntry]

    public init(entries: [SynonymEntry]) {
        self.entries = entries
        byKey = [:]
        for entry in entries {
            for spelling in [entry.word] + entry.aliases {
                let key = IngredientCatalog.normalize(spelling)
                if byKey[key] == nil { byKey[key] = entry }
            }
        }
    }

    /// Looked up by any spelling, normalized the same way the catalog
    /// normalizes — the two have to agree or a word mapped at build time
    /// would not be found at run time.
    public func entry(for word: String) -> SynonymEntry? {
        byKey[IngredientCatalog.normalize(word)]
    }

    /// The table shipped with the app.
    public static let bundled: SynonymTable = {
        guard let url = Bundle.module.url(forResource: "synonyms", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            assertionFailure("The bundled synonym table is missing or unreadable")
            return SynonymTable(entries: [])
        }
        return SynonymTable(entries: file.words)
    }()

    /// The catalog entries this table describes — the identity half of it,
    /// which is what `IngredientCatalog` is built from.
    public var catalogIngredients: [CatalogIngredient] {
        entries.map {
            CatalogIngredient(
                name: $0.word, aliases: $0.aliases, category: $0.category, parentName: $0.parent
            )
        }
    }
}
