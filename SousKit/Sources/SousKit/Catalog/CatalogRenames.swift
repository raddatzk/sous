import Foundation

/// What became of catalog ids that are no longer an entry's: the ids a merge
/// absorbed, each pointing at the entry that absorbed it, and the ids that
/// left the catalog for good.
///
/// `ids.json`, compiled from the `formerly:` lists and `Community/retired.yaml`.
/// It is what lets a row written with an old id keep finding its word
/// (INGREDIENTS-DATA §3 F): the row is read through this map, and rewritten
/// only when it is saved anyway. Nothing rewrites rows in bulk when data
/// changes, because every device of a household would do so on a different
/// day, and a member may not be allowed to write the owner's rows.
public struct CatalogRenames: Codable, Sendable, Hashable {
    /// Absorbed id → the id of the entry that absorbed it.
    public var renamed: [String: String]
    /// Ids whose thing left the catalog. A row holding one has nothing to
    /// resolve to, and says so.
    public var retired: Set<String>

    public init(renamed: [String: String] = [:], retired: Set<String> = []) {
        self.renamed = renamed
        self.retired = retired
    }

    public static let none = CatalogRenames()

    /// `ids.json`.
    init(json: Data) throws {
        self = try JSONDecoder().decode(CatalogRenames.self, from: json)
    }

    /// The map shipped with the app.
    public static var bundled: CatalogRenames { DataSet.bundled.renames }
}

/// What a stored catalog id means to the catalog at hand.
public enum CatalogIDResolution: Hashable, Sendable {
    /// The id is an entry's own.
    case current(CatalogIngredient)
    /// The id was absorbed; `to` is the entry that holds it now, followed
    /// through every later rename.
    case renamed(to: CatalogIngredient)
    /// The id's thing left the catalog.
    case retired
    /// Neither known nor retired: the id comes from a newer data version
    /// than this device has. The row waits, untouched, until the data
    /// catches up.
    case unknown

    /// The entry the id reaches, current or renamed.
    public var ingredient: CatalogIngredient? {
        switch self {
        case .current(let ingredient), .renamed(to: let ingredient): ingredient
        case .retired, .unknown: nil
        }
    }
}
