import Foundation

/// Nutrition values for the ingredients `IngredientCatalog` knows by name.
///
/// The chain a written name walks is: name → aliases → synonym table → SBLS
/// code → BLS row. This type is where the last three steps happen; the first
/// belongs to `IngredientCatalog`, so that exactly one place decides what a
/// written ingredient means.
public struct NutritionCatalog: Sendable {
    private var byName: [String: CatalogNutrition]

    public init(entries: [CatalogNutrition]) {
        byName = Dictionary(entries.map { (IngredientCatalog.normalize($0.name), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The catalog shipped with the app, assembled rather than read: the
    /// synonym table says which codes a kitchen word means, the BLS table
    /// holds the values, and the measure table holds what a piece of it
    /// weighs. Three files that each say one thing, joined by value.
    public static var bundled: NutritionCatalog { DataSet.bundled.nutrition }

    /// The catalog of the data set this process runs on.
    public static var current: NutritionCatalog { DataSet.current.nutrition }

    /// Injectable so a test can assemble the same thing from fixture data.
    ///
    /// The synonym table and the BLS catalog are read here and nowhere else:
    /// a data set builds this once, and asking the synonym table again on
    /// every lookup would be a second path deciding what a written word
    /// means — the one thing this type's contract forbids. The target's
    /// weight is carried through onto the basis.
    public static func make(
        synonyms: SynonymTable, bls: BLSCatalog, measures: MeasureTable
    ) -> NutritionCatalog {
        // The BLS as its rows cite it — the dataset's own name, for what the
        // curation settles without values.
        let source = bls.entries.first { $0.sourceID == "bls" }?.source ?? CatalogNutrition.blsSource
        var entries: [CatalogNutrition] = []
        entries.reserveCapacity(synonyms.entries.count)
        let nameByID = Dictionary(
            synonyms.entries.compactMap { entry in entry.id.map { ($0, entry.word) } },
            uniquingKeysWith: { first, _ in first }
        )
        for word in synonyms.entries {
            var bases: [String: NutritionBasis] = [:]
            var group: String?
            for state in IngredientState.displayOrder {
                guard let target = word.target(for: state),
                      let row = bls.entry(for: target.code)
                else { continue }
                group = group ?? row.group
                bases[state.rawValue] = NutritionBasis(
                    values: row.perHundredGrams,
                    code: row.code,
                    catalogName: row.name,
                    weight: target.weight,
                    // The row's own source — every row names the body that
                    // measured it, and "BLS 4.0" under a figure the BLS never
                    // published would be a false claim, not a rounding of
                    // the truth.
                    source: row.labelledSource ?? CatalogNutrition.blsSource,
                    sourceURL: row.sourceURL
                )
            }
            // A word the source does not list at all arrives *answered*,
            // not empty, and that answer overrules anything the loop above
            // found: the marker is the curator's last word, not a hint.
            //
            // The difference matters. An empty word is a question every
            // recipe using it asks again; a word carrying
            // `deliberatelyWithout` is a settled one that stops counting as a
            // defect. Filed under `unspecified`, because "the BLS has no
            // cinnamon" is true of cinnamon in every state.
            if word.hasNoValues {
                bases = [IngredientState.unspecified.rawValue: NutritionBasis(
                    values: .zero, status: .deliberatelyWithout,
                    // The dataset's own name, not `ownSource`: this is the
                    // curation's decision, and telling the cook it was theirs
                    // would be a small lie in the one place that explains
                    // where a number came from.
                    source: source
                )]
            }
            let candidates = word.candidateCodes
            // A word with no basis still sits in a food group, and the group
            // is what a cup of it or a milliliter of it is answered from.
            if group == nil, let code = candidates.first { group = bls.entry(for: code)?.group }
            // Most specific wins: what was authored for this ingredient beats
            // what was authored for its whole group.
            let spellings = [word.word] + word.aliases
            let unitWeights = (group.map(measures.grams(forGroup:)) ?? [:])
                .merging(measures.grams(forAnyOf: spellings), uniquingKeysWith: { _, specific in specific })
            let density = measures.density(forAnyOf: spellings)
                ?? group.flatMap(measures.density(forGroup:))
            // An entry is worth having as soon as the word carries *anything*
            // a later step can use. It used to take values: the 28 spices got
            // no entry at all, so the one line the picker exists for — a known
            // ingredient with no basis — was the one line with no candidates
            // to offer. A word with an empty `bases` still says "the catalog
            // knows this and has no values", which is what the gap reason
            // reads off it.
            guard !bases.isEmpty || !unitWeights.isEmpty || !candidates.isEmpty
                    || density != nil || word.parent != nil || word.product?.like != nil
            else { continue }
            // The word's own line of attribution follows its basis: a word
            // resting on a supplement is shown as resting on that supplement,
            // not on the catalog it is not in. Read in a fixed order, so equal
            // weights go to the same basis on every launch — a dictionary's
            // order is not.
            let wordSource = IngredientState.displayOrder.compactMap { bases[$0.rawValue] }
                .max { $0.weight < $1.weight }?.source ?? source
            var entry = CatalogNutrition(
                name: word.word,
                bases: bases,
                unitWeightsGrams: unitWeights,
                unitStates: measures.states(forAnyOf: spellings),
                densityGramsPerMl: density,
                source: wordSource,
                candidateCodes: candidates,
                parentName: word.parent
            )
            entry.likeName = word.product?.like.flatMap { nameByID[$0] }
            entries.append(entry)
        }
        return NutritionCatalog(entries: entries)
    }

    /// Looked up only by a name already resolved to its canonical form via
    /// `IngredientCatalog.canonicalName(for:)` — this catalog does no alias
    /// or plural matching of its own, so there is exactly one place that
    /// decides what a written ingredient means.
    ///
    /// A variety with nothing of its own is answered with its parent's basis:
    /// "Cocktailtomate" is a tomato until the catalog says otherwise, and the
    /// inheritance happens here rather than at build time so that a local
    /// answer laid over the parent reaches the variant too.
    public func nutrition(forCanonicalName name: String) -> CatalogNutrition? {
        guard let entry = byName[IngredientCatalog.normalize(name)] else { return nil }
        guard !entry.hasBases else { return entry }
        // A product without a label counts like its generic word, which may
        // itself be a variety. `like` never names a product (the compiler
        // says so), so this does not chain.
        if let likeName = entry.likeName,
           IngredientCatalog.normalize(likeName) != IngredientCatalog.normalize(entry.name),
           let generic = nutrition(forCanonicalName: likeName), generic.hasBases {
            return entry.estimating(like: generic)
        }
        // Up the chain to the nearest ancestor with a basis — any depth, since
        // the shipped data already held Pilz → Champignon → Brauner Champignon
        // and the store no longer refuses the shape. A seen-set rather than a
        // depth cap: a hand-edited data file is the one place a loop could
        // still come from, and the walk must end either way.
        var seen: Set<String> = [IngredientCatalog.normalize(entry.name)]
        var current = entry
        while let parentName = current.parentName,
              let parent = byName[IngredientCatalog.normalize(parentName)],
              seen.insert(IngredientCatalog.normalize(parent.name)).inserted {
            if parent.hasBases { return entry.inheriting(from: parent) }
            current = parent
        }
        return entry
    }

    /// The entry as it was written, without anything taken from an
    /// ancestor — what a form compares against to say which of the figures
    /// it shows are the ingredient's own and which came down the chain.
    public func ownEntry(forCanonicalName name: String) -> CatalogNutrition? {
        byName[IngredientCatalog.normalize(name)]
    }

    public var entries: [CatalogNutrition] { Array(byName.values) }

    /// This catalog with `entries` in place of whatever it held under their
    /// names — not merged: a local answer that lends a target's entry says
    /// the whole of what the name is worth (``LocalAnswerSet``).
    public func replacing(_ entries: [CatalogNutrition]) -> NutritionCatalog {
        var replaced = self
        for entry in entries {
            replaced.byName[IngredientCatalog.normalize(entry.name)] = entry
        }
        return replaced
    }
}
