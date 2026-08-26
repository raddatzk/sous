import Foundation

/// Which aisle a BLS food group lands in when nothing more specific says.
///
/// `IngredientCategory` is one enum doing two jobs — it names what kind of
/// food something is *and* orders a shopping list into a route through a shop.
/// This phase deliberately leaves that as it is (see the pipeline README,
/// "Group and aisle"): what becomes data is the *mapping*, so widening or
/// re-routing the source's taxonomy is an edit to `aisles.json` rather than a
/// change to an enum the shopping list, the catalog browser and the category
/// manager all read.
///
/// The finer per-row assignment lives in `bls.json`; this is the fallback for
/// anything that arrives with only a group letter.
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
    private var byGroup: [String: IngredientCategory]

    public init(groups: [Group]) {
        self.groups = groups
        byGroup = groups.reduce(into: [:]) { result, group in
            result[group.group] = group.category
        }
    }

    public func category(forGroup group: String) -> IngredientCategory? { byGroup[group] }

    /// The table shipped with the app.
    public static let bundled: AisleDefaults = {
        guard let url = Bundle.module.url(forResource: "aisles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            assertionFailure("The bundled aisle defaults are missing or unreadable")
            return AisleDefaults(groups: [])
        }
        return AisleDefaults(groups: file.groups)
    }()
}
