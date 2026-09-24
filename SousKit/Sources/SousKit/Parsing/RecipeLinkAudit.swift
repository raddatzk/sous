import Foundation

/// Which recipes would lose a reference if others were deleted.
///
/// A recipe can name another in a line or a step — "2 Portionen
/// [Naan](sous://recipe/…)" — and the link is what makes the curry count the
/// naan's ingredients towards its own nutrition and effort. Deleting the
/// naan therefore does more than break a tap target: it quietly changes what
/// the curry says about itself.
///
/// Nothing here rewrites anything. The audit exists so the cook can be told
/// before they decide, which is the only honest way to handle a reference
/// that only the other recipe knows about.
public enum RecipeLinkAudit {
    /// One surviving recipe and what it would be left pointing at.
    public struct Break: Sendable, Hashable {
        /// The recipe that carries the link and stays.
        public var source: Recipe
        /// The recipes it names, in the order they appear.
        public var targets: [Recipe]

        public init(source: Recipe, targets: [Recipe]) {
            self.source = source
            self.targets = targets
        }
    }

    /// The breaks that deleting `deleting` would cause among `library`.
    ///
    /// Recipes being deleted are not sources of their own: a link from one
    /// doomed recipe to another goes with both of them. Trashed recipes are
    /// no sources either — they are not what the cook would open.
    public static func breaks(
        deleting deleting: [Recipe],
        in library: [Recipe]
    ) -> [Break] {
        let doomed = Set(deleting.map(\.id))
        guard !doomed.isEmpty else { return [] }
        let byID = Dictionary(deleting.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return library.compactMap { recipe in
            guard !doomed.contains(recipe.id), !recipe.isDeleted else { return nil }
            let targets = recipe.linkedRecipeIDs
                .filter { doomed.contains($0) }
                .compactMap { byID[$0] }
            return targets.isEmpty ? nil : Break(source: recipe, targets: targets)
        }
    }
}
