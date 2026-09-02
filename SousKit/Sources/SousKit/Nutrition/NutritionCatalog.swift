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
    public static let bundled: NutritionCatalog = {
        make(synonyms: .bundled, bls: .bundled, measures: .bundled)
    }()

    /// Injectable so a test can assemble the same thing from fixture data.
    ///
    /// **Where the status comes from.** The synonym table and the BLS catalog
    /// are read here and nowhere else: `bundled` is a `static let`, built once
    /// per process, and asking the synonym table again on every lookup would
    /// be a second path deciding what a written word means — the one thing
    /// this type's contract forbids. So the two things a status needs, the
    /// target's weight and how the word reached its row, are carried *through*
    /// this step and land on the basis. A basis therefore knows its own status
    /// without anyone re-deriving it, and the cook's confirmations can be laid
    /// over it later like any other override.
    ///
    /// The rule itself: a word the BLS coined (`origin == "bls"`) matching its
    /// own row at full weight is not a guess and starts *confirmed* — the
    /// recipe wrote the catalog's word for the catalog's row. Everything the
    /// curated synonym table maps starts *proposed*, per the concept: kitchen
    /// German and catalog German are different languages, and which row
    /// "Schmelzkäse" means is exactly the question the cook answers.
    public static func make(
        synonyms: SynonymTable, bls: BLSCatalog, measures: MeasureTable
    ) -> NutritionCatalog {
        let source = bls.source.datasetVersion.isEmpty
            ? CatalogNutrition.blsSource : bls.source.datasetVersion
        var entries: [CatalogNutrition] = []
        entries.reserveCapacity(synonyms.entries.count)
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
                    status: word.isCatalogsOwnName(for: target) ? .confirmed : .proposed,
                    weight: target.weight,
                    // The row's own source where it has one — a supplement
                    // names the body that measured it, and "BLS 4.0" under a
                    // figure the BLS never published would be a false claim,
                    // not a rounding of the truth.
                    source: row.source ?? source
                )
            }
            // A word the source does not list at all arrives *answered*,
            // not empty, and that answer overrules anything the loop above
            // found: the marker is the curator's last word, not a hint.
            //
            // The difference is the whole of decision D. An empty word is a
            // question every recipe using it asks again; a word carrying
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
                    || density != nil || word.parent != nil
            else { continue }
            // The word's own line of attribution follows its basis: a word
            // resting on a supplement is shown as resting on that supplement,
            // not on the catalog it is not in.
            let wordSource = bases.values
                .max { $0.weight < $1.weight }?.source ?? source
            entries.append(CatalogNutrition(
                name: word.word,
                bases: bases,
                unitWeightsGrams: unitWeights,
                densityGramsPerMl: density,
                source: wordSource,
                candidateCodes: candidates,
                parentName: word.parent
            ))
        }
        return NutritionCatalog(entries: entries)
    }

    /// Looked up only by a name already resolved to its canonical form via
    /// `IngredientCatalog.canonicalName(for:)` — this catalog does no alias
    /// or plural matching of its own, so there is exactly one place that
    /// decides what a written ingredient means.
    ///
    /// A variety with nothing of its own is answered with its parent's basis:
    /// "Cocktailtomate" is a tomato until someone says otherwise, and the
    /// inheritance happens here rather than at build time so that a cook's
    /// confirmation on the parent reaches the variant the moment it is made.
    public func nutrition(forCanonicalName name: String) -> CatalogNutrition? {
        guard let entry = byName[IngredientCatalog.normalize(name)] else { return nil }
        guard !entry.hasBases else { return entry }
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

    /// This catalog with the cook's own entries laid over it, state by state.
    ///
    /// A merge rather than a replacement: an own entry usually says one thing
    /// (these numbers, or this variety relation) and must not silently take
    /// away everything the shipped entry knew — which is how a hand-entered
    /// ingredient used to end up with an empty candidate list.
    public func merging(_ overrides: [CatalogNutrition]) -> NutritionCatalog {
        var merged = self
        for override in overrides {
            let key = IngredientCatalog.normalize(override.name)
            merged.byName[key] = merged.byName[key]?.overlaid(by: override) ?? override
        }
        return merged
    }
}
