import Foundation

/// Turning the flat list of recipes into the nested one the library shows.
///
/// The store returns a flat array and ``RecipeQuery`` knows nothing about
/// groups: the nesting is presentation, computed here from what the query
/// happened to return. That is what lets a filtered list show a group with
/// only its matching members — nobody had to teach the filter about groups,
/// because the group is drawn around whatever came back.
public enum VariantGrouping {
    /// One row of the library at its top level.
    public enum Entry: Identifiable, Hashable, Sendable {
        /// A recipe standing on its own — either in no group, or the last
        /// one left in its group.
        case recipe(Recipe)
        /// A group and the members of it this list is showing, which under a
        /// filter may be fewer than it has.
        case group(VariantGroup, members: [Recipe])

        public var id: UUID {
            switch self {
            case .recipe(let recipe): recipe.id
            case .group(let group, _): group.id
            }
        }

        /// The recipes this entry draws, so a caller can walk the list
        /// without caring about the nesting.
        public var recipes: [Recipe] {
            switch self {
            case .recipe(let recipe): [recipe]
            case .group(_, let members): members
            }
        }
    }

    /// Nests `recipes` into the groups in `groups`, keeping the order the
    /// query gave them.
    ///
    /// A group takes the place of its first member, so sorting by title puts
    /// "Chili con Carne" where its first variant would have stood rather
    /// than in some order of its own. Within a group the query's order is
    /// dropped for creation order: the members are versions of one dish, and
    /// the only thing that distinguishes their sequence is which was written
    /// first.
    ///
    /// `groups` is expected to hold only groups that are still groups — see
    /// ``RecipeStore/variantGroups()``. A recipe naming a group that is not
    /// in there stands on its own, which is also what a member whose group
    /// row is gone does.
    public static func entries(
        for recipes: [Recipe],
        groups: [UUID: VariantGroup]
    ) -> [Entry] {
        var entries: [Entry] = []
        var members: [UUID: [Recipe]] = [:]
        /// Where each group's row goes: the slot its first member claimed.
        var slots: [UUID: Int] = [:]

        for recipe in recipes {
            guard let groupID = recipe.variantGroupID, let group = groups[groupID] else {
                entries.append(.recipe(recipe))
                continue
            }
            members[groupID, default: []].append(recipe)
            if slots[groupID] == nil {
                slots[groupID] = entries.count
                entries.append(.group(group, members: []))
            }
        }

        for (groupID, slot) in slots {
            guard let group = groups[groupID] else { continue }
            let sorted = (members[groupID] ?? []).sorted { $0.createdAt < $1.createdAt }
            entries[slot] = .group(group, members: sorted)
        }
        return entries
    }
}
