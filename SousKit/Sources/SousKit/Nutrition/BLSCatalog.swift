import Foundation

/// One row of the Bundeslebensmittelschlüssel, as it stands in the source.
///
/// The key is the SBLS code, not the name: a name is what a release happens to
/// call a food this time, a code is what the food *is*. Everything the app
/// remembers about a mapping remembers the code, so a new release can be
/// swapped in wholesale without user data pointing at nothing.
public struct BLSEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { code }

    /// The SBLS code: "K110132".
    public var code: String
    /// The catalog designation, verbatim: "Kartoffel geschält, gekocht". This
    /// is what "beruht auf: …" shows — the source's word, not the kitchen's.
    public var name: String
    /// The BLS food group, its code's first letter. The source's own taxonomy,
    /// kept as it is; `aisles.json` maps it onto the app's aisles.
    public var group: String
    /// Which aisle this row lands in — the pipeline's per-row refinement of
    /// the group default, so peanuts in the legume group still read as nuts.
    public var category: IngredientCategory
    /// Where this row's numbers come from, for the rows that are not BLS.
    ///
    /// `nil` for everything out of `bls.json`, where the file's own
    /// attribution already answers the question for all 3,983 rows at once.
    /// Set on every supplement, because a file of supplements has no single
    /// answer: its rows come from wherever the food happened to be documented.
    public var source: String?
    public var perHundredGrams: NutritionInfo

    public init(
        code: String, name: String, group: String,
        category: IngredientCategory, source: String? = nil,
        perHundredGrams: NutritionInfo
    ) {
        self.code = code
        self.name = name
        self.group = group
        self.category = category
        self.source = source
        self.perHundredGrams = perHundredGrams
    }
}

/// The food rows the app ships, keyed by code.
///
/// Deliberately not merged, averaged, or deduplicated: the nine Schmelzkäse
/// are nine rows here, and picking between them is a question for the cook
/// (phase 4), not one the build step gets to answer by taking a mean.
///
/// Two files feed it. `bls.json` is the catalog; `community.json` holds the
/// handful of foods the BLS does not list at all — nutritional yeast, and
/// whatever else turns out to be missing. They are one table at run time on
/// purpose: a basis is a code, and nothing that resolves, confirms or
/// reconciles a basis should have to ask which file the code came from.
public struct BLSCatalog: Sendable {
    /// What CC BY 4.0 asks the app to be able to say, carried in the data
    /// rather than in a Swift constant — the file that changes on an update is
    /// the file that states its own version.
    public struct Source: Codable, Hashable, Sendable {
        public var datasetVersion: String
        public var release: String
        public var license: String
        public var attribution: String
        public var changeNote: String
    }

    private struct File: Codable {
        var datasetVersion: String
        var release: String
        var license: String
        var attribution: String
        var changeNote: String
        var entries: [BLSEntry]

        var sourceValue: Source {
            Source(
                datasetVersion: datasetVersion, release: release, license: license,
                attribution: attribution, changeNote: changeNote
            )
        }
    }

    public private(set) var source: Source
    /// The supplements file speaking for itself, or `nil` where the app ships
    /// none. Kept apart from `source` rather than merged into it: the two
    /// files are under different licences from different bodies, and the
    /// sources screen has to be able to name both separately.
    public private(set) var supplementSource: Source?
    public private(set) var entries: [BLSEntry]
    private var byCode: [String: BLSEntry]

    public init(source: Source, entries: [BLSEntry], supplementSource: Source? = nil) {
        self.source = source
        self.supplementSource = supplementSource
        self.entries = entries
        byCode = Dictionary(entries.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func entry(for code: String) -> BLSEntry? { byCode[code] }

    public func entries(for codes: [String]) -> [BLSEntry] { codes.compactMap(entry(for:)) }

    /// Rows whose catalog name contains `text`, best first — the second half
    /// of the concept's bridge across the two languages: the synonym table
    /// carries what curation knows, this carries everything else.
    ///
    /// It is what makes the picker usable at all for a word the table has
    /// nothing for: "Kurkuma" has no candidates and no values, and a picker
    /// that could only offer its candidates would offer nothing. Prefix
    /// matches lead, then shorter names, so "Schmelzkäse" lists the plain
    /// cheeses before the preparations with ham in them.
    ///
    /// A supplement whose name is in another language will not be found by a
    /// German word here, and that is the curation's job to bridge, not this
    /// method's — the same as for every BLS row whose name nobody writes.
    public func search(_ text: String, limit: Int = 40) -> [BLSEntry] {
        let query = IngredientCatalog.normalize(text)
        guard query.count >= 3 else { return [] }

        return entries
            .compactMap { entry -> (BLSEntry, Int, Int)? in
                let name = IngredientCatalog.normalize(entry.name)
                guard let tier = Self.tier(of: name, for: query) else { return nil }
                return (entry, tier, name.count)
            }
            .sorted { first, second in
                (first.1, first.2) == (second.1, second.2)
                    ? first.0.name < second.0.name
                    : (first.1, first.2) < (second.1, second.2)
            }
            .prefix(limit)
            .map(\.0)
    }

    /// How well a row's name answers `query`, lower being better, or `nil`
    /// for a row that does not answer it at all.
    ///
    /// Containment alone only ever reaches *down*, to a name longer than
    /// what was typed — which is the wrong direction for German. The table
    /// stocks the general word and the cook writes the specific one:
    /// "Leinöl" is what BLS calls Q160000, "Leinsamenöl" is what stands on
    /// the bottle. `"leinöl".contains("leinsamenöl")` is false, so the one
    /// right row in the table was invisible to the one name anybody types.
    ///
    /// Tiers 2 to 4 reach up instead, along the seams a German compound
    /// actually has. The head noun comes last and carries the meaning, so a
    /// shared ending ranks above a shared beginning: typing "Leinsamenöl"
    /// should offer the oil before the seeds it is pressed from, even
    /// though both are real matches.
    static func tier(of name: String, for query: String) -> Int? {
        if name.hasPrefix(query) { return 0 }
        if name.contains(query) { return 1 }
        // A name at least as long as the query has had its chance above.
        // The short ones are held back because nearly every row shares a
        // three-letter ending with something, and "…öl" matching every oil
        // in the table is no more use than matching none of them.
        guard name.count >= 4, name.count < query.count else { return nil }

        // "Vollmilch" → "Milch": the query is the row's name with a
        // modifier written in front of it.
        if query.hasSuffix(name) { return 2 }

        // "Leinsamenöl" → "Leinöl": the row's name split in two by an
        // insertion, its beginning and its ending both still in place.
        // Both halves have to carry weight — a single shared letter at
        // either end is a coincidence, not a seam.
        let n = Array(name), q = Array(query)
        var head = 0
        while head < n.count, n[head] == q[head] { head += 1 }
        var tail = 0
        while tail < n.count - head, n[n.count - 1 - tail] == q[q.count - 1 - tail] { tail += 1 }
        if head + tail == n.count, head >= 2, tail >= 2 { return 3 }

        // "Leinsamenöl" → "Leinsamen": only the modifier is shared, and the
        // head noun — the part that says what the thing is — is not. Last,
        // and only ever as the tail of a list that has better above it.
        if query.hasPrefix(name) { return 4 }

        return nil
    }

    /// The tables shipped with the app.
    ///
    /// `bls.json` is required; `community.json` is not. A missing supplements
    /// file leaves an app that works exactly as it did before there was one,
    /// which is what makes the file safe to be empty, hand-edited, or absent
    /// from a build.
    public static let bundled: BLSCatalog = {
        guard let file = load("bls") else {
            assertionFailure("The bundled BLS table is missing or unreadable")
            return BLSCatalog(
                source: Source(
                    datasetVersion: "", release: "", license: "", attribution: "", changeNote: ""
                ),
                entries: []
            )
        }
        let supplements = load("community")
        return BLSCatalog(
            // BLS rows first, so a supplement can never take a code the
            // catalog already uses — `byCode` keeps the first of a pair.
            source: file.sourceValue,
            entries: file.entries + (supplements?.entries ?? []),
            supplementSource: supplements.map(\.sourceValue)
        )
    }()

    private static func load(_ resource: String) -> File? {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return nil }
        return file
    }
}
