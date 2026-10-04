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
    /// For a label row: the day the label was read, "2026-10-02", so a
    /// stale row is findable.
    public var checked: String?
    /// For a label row: what its values refer to, `as-sold` or `drained`.
    public var per: String?

    public init(
        code: String, name: String, group: String,
        category: IngredientCategory, source: String? = nil,
        perHundredGrams: NutritionInfo, checked: String? = nil, per: String? = nil
    ) {
        self.code = code
        self.name = name
        self.group = group
        self.category = category
        self.source = source
        self.perHundredGrams = perHundredGrams
        self.checked = checked
        self.per = per
    }

    /// The row's source as the app prints it: a label row adds the day it
    /// was read, and says so where its values are for the drained food.
    public var labelledSource: String? {
        guard let source else { return nil }
        var parts = [source]
        if per == "drained" { parts.append("pro 100 g abgetropft") }
        if let checked { parts.append("gelesen \(checked)") }
        return parts.joined(separator: " · ")
    }
}

/// The food rows the app ships, keyed by code.
///
/// Deliberately not merged, averaged, or deduplicated: the nine Schmelzkäse
/// are nine rows here, and picking between them is a question for the cook,
/// not one the build step gets to answer by taking a mean.
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
        /// Only in the supplements file: `Data/assumed-zeros.yaml`.
        var assumedZero: [AssumedZero]?
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
    /// files are under different licences from different bodies, and each
    /// has to be nameable on its own.
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

    /// One rule of `Data/assumed-zeros.yaml`: in these BLS groups, a blank
    /// for this nutrient is a zero nobody wrote down — vitamin C in flour,
    /// fibre in cheese.
    struct AssumedZero: Codable, Hashable, Sendable {
        /// A string, not a ``Nutrient``: a nutrient a later data set names
        /// and this app does not know is a rule to skip, not a file to refuse.
        var nutrient: String
        var groups: [String]
    }

    /// `bls.json` and `community.json`, the supplements. Both are part of
    /// every data set, so a set missing either one is not a set.
    init(bls: Data, supplements: Data) throws {
        let decoder = JSONDecoder()
        let file = try decoder.decode(File.self, from: bls)
        let supplements = try decoder.decode(File.self, from: supplements)
        self.init(
            // BLS rows first, so a supplement can never take a code the
            // catalog already uses — `byCode` keeps the first of a pair.
            source: file.sourceValue,
            entries: Self.applying(supplements.assumedZero ?? [], to: file.entries) + supplements.entries,
            supplementSource: supplements.sourceValue
        )
    }

    /// The BLS rows with the assumed zeros filled in. Only blanks change, and
    /// only the BLS's: a supplement or a product label keeps every blank it
    /// has, since nobody vouched for its zeros.
    static func applying(_ rules: [AssumedZero], to entries: [BLSEntry]) -> [BLSEntry] {
        let byGroup = rules.reduce(into: [String: Set<Nutrient>]()) { result, rule in
            guard let nutrient = Nutrient(rawValue: rule.nutrient) else { return }
            for group in rule.groups { result[group, default: []].insert(nutrient) }
        }
        guard !byGroup.isEmpty else { return entries }
        return entries.map { entry in
            guard let zeros = byGroup[entry.group] else { return entry }
            var entry = entry
            // An absent value reads 0 already; stating it is all that is left.
            entry.perHundredGrams.absent.subtract(zeros)
            return entry
        }
    }

    /// The tables of the data set this process runs on.
    public static var current: BLSCatalog { DataSet.current.bls }

    /// The tables shipped with the app.
    public static var bundled: BLSCatalog { DataSet.bundled.bls }
}
