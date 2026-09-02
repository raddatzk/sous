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
    /// As written; `nil` for a variety that takes its parent's. Resolution
    /// is `IngredientCatalog`'s job, once, for the whole list.
    public var category: IngredientCategory?
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
    /// That this word has no basis on purpose — the source does not list the
    /// food at all. See ``IngredientCuration/Entry/withoutValues``.
    public var hasNoValues: Bool

    public init(
        word: String, aliases: [String] = [], category: IngredientCategory? = nil,
        targets: [SynonymTarget] = [], candidates: [String] = [],
        origin: String = "curated", parent: String? = nil, hasNoValues: Bool = false
    ) {
        self.word = word
        self.aliases = aliases
        self.category = category
        self.targets = targets
        self.candidates = candidates
        self.origin = origin
        self.parent = parent
        self.hasNoValues = hasNoValues
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

    /// The table shipped with the app: the kitchen's words, each carrying
    /// what the curation says it means.
    ///
    /// Not a file of its own any more. It used to be one — a build-time merge
    /// of the kitchen words and all 2461 BLS row names into a single
    /// vocabulary — and that merge is what put a food table's spellings in
    /// front of a cook typing an ingredient. The two lists stay two lists;
    /// this joins the kitchen's to its mapping and never touches the other.
    ///
    /// A BLS row is reachable only where somebody went looking for one, and a
    /// word this list does not know now arrives without values rather than
    /// with the table's own name attached to it — which is a question the app
    /// already knows how to ask, the same one it asks about any ingredient
    /// whose nutrition is unconfirmed.
    public static let bundled: SynonymTable = {
        SynonymTable(kitchen: .bundled, curation: .bundled)
    }()

    /// Joins the kitchen's list to the mapping. Weights are positional: the
    /// first code a state names is its basis, the rest are alternatives, and
    /// that is the whole of the ranking the curation needs to express.
    public init(kitchen: KitchenWords, curation: IngredientCuration) {
        self.init(entries: kitchen.words.map { word in
            let entry = curation.entry(for: word.name)
            let targets = (entry?.targets ?? [:]).flatMap { state, codes in
                codes.enumerated().compactMap { index, code in
                    IngredientState(rawValue: state).map {
                        SynonymTarget(
                            code: code, state: $0,
                            weight: index == 0 ? 1 : 0.8
                        )
                    }
                }
            }
            return SynonymEntry(
                word: word.name,
                aliases: word.aliases,
                category: word.category,
                targets: targets,
                // A word that says it has none offers none. Otherwise the
                // picker would keep proposing rows for a question that has
                // been answered.
                candidates: entry?.withoutValues == true ? [] : (entry?.candidates ?? []),
                parent: word.parent,
                hasNoValues: entry?.withoutValues ?? false
            )
        })
    }

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
