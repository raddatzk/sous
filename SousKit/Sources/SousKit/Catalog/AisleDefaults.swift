import Foundation

/// Which aisle a BLS food group lands in when nothing more specific says.
///
/// `IngredientCategory` is one enum doing two jobs — it names what kind of
/// food something is *and* orders a shopping list into a route through a shop.
/// That stays as it is (see the pipeline README, "Group and aisle"): what is
/// data is the *mapping*, so widening or re-routing the source's taxonomy is
/// an edit to `aisles.json` rather than a change to an enum the shopping list,
/// the catalog browser and the category manager all read.
///
/// The compiler applies the mapping: every row of `nutrition.json` arrives with
/// its aisle already set, so the app reads none of this at run time. The file is
/// still part of every data set, and loaded with it, so a set without it is
/// refused like any other incomplete one.
public struct AisleDefaults: Sendable {
    public struct Group: Codable, Hashable, Sendable {
        public var group: String
        public var category: IngredientCategory?
        /// Whether the pipeline ships rows from this group at all — kept so
        /// the file documents the whole source, not only the part in scope.
        public var included: Bool
        public var note: String
    }

    private struct File: Codable {
        var groups: [Group]
    }

    public private(set) var groups: [Group]

    public init(groups: [Group]) {
        self.groups = groups
    }

    /// `aisles.json`.
    init(json: Data) throws {
        self.init(groups: try JSONDecoder().decode(File.self, from: json).groups)
    }

    /// The table shipped with the app.
    public static var bundled: AisleDefaults { DataSet.bundled.aisles }
}
