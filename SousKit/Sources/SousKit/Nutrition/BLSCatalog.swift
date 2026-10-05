import Foundation

/// One row of nutrition values, as it stands in its source: a row of the
/// Bundeslebensmittelschlüssel, keyed by its SBLS code, or a row of another
/// source (Ciqual, USDA, a label), keyed by the Z code an entry gave it.
///
/// The key is the code, not the name: a name is what a release happens to
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
    /// Where this row's numbers come from, as „Quelle: …“ prints it: "BLS
    /// 4.0", "Ciqual 2020 (Anses), Nr. 11088 „Cayenne pepper“".
    public var source: String?
    /// The source's id in the register (`sources.json`): `bls`,
    /// `ciqual-2020`. The assumed zeros apply to `bls` rows only.
    public var sourceID: String?
    /// Where this one row can be looked up, where its source has such a page.
    public var sourceURL: URL?
    public var perHundredGrams: NutritionInfo
    /// For a label row: the day the label was read, "2026-10-02", so a
    /// stale row is findable.
    public var checked: String?
    /// For a label row: what its values refer to, `as-sold` or `drained`.
    public var per: String?

    public init(
        code: String, name: String, group: String,
        category: IngredientCategory, source: String? = nil, sourceID: String? = nil,
        sourceURL: URL? = nil, perHundredGrams: NutritionInfo, checked: String? = nil,
        per: String? = nil
    ) {
        self.code = code
        self.name = name
        self.group = group
        self.category = category
        self.source = source
        self.sourceID = sourceID
        self.sourceURL = sourceURL
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
/// One file feeds it, `nutrition.json`: every row the catalog uses, from
/// whichever source, and nothing else — the compiler resolves each entry's
/// codes against the sources in `Data/sources/` and ships what it found. A
/// basis is a code, and nothing that resolves, confirms or reconciles one
/// should have to ask which source the code came from; where it matters,
/// the row says (`sourceID`).
public struct BLSCatalog: Sendable {
    private struct File: Codable {
        /// `Data/assumed-zeros.yaml`.
        var assumedZero: [AssumedZero]?
        var entries: [BLSEntry]
    }

    public private(set) var entries: [BLSEntry]
    private var byCode: [String: BLSEntry]

    public init(entries: [BLSEntry]) {
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

    /// `nutrition.json`, part of every data set.
    init(nutrition: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: nutrition)
        self.init(entries: Self.applying(file.assumedZero ?? [], to: file.entries))
    }

    /// The rows with the assumed zeros filled in. Only blanks change, and
    /// only the BLS's: another source's row or a product label keeps every
    /// blank it has, since nobody vouched for its zeros.
    static func applying(_ rules: [AssumedZero], to entries: [BLSEntry]) -> [BLSEntry] {
        let byGroup = rules.reduce(into: [String: Set<Nutrient>]()) { result, rule in
            guard let nutrient = Nutrient(rawValue: rule.nutrient) else { return }
            for group in rule.groups { result[group, default: []].insert(nutrient) }
        }
        guard !byGroup.isEmpty else { return entries }
        return entries.map { entry in
            guard entry.sourceID == "bls", let zeros = byGroup[entry.group] else { return entry }
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
