import Foundation

/// Several versions of the same dish, standing side by side.
///
/// A group is not a recipe and must never become one. It holds a title and
/// the two timestamps every synced row needs, and nothing else: the test is
/// not whether a field could exist but whether anything branches on it.
/// Showing the union of its members' categories on the comparison screen is
/// free; storing categories here would make ``RecipeFilter`` search two kinds
/// of thing and let a recipe reach one category by two routes.
///
/// Membership lives on the members — ``Recipe/variantGroupID`` — rather than
/// as a list here, which is what makes "dissolve" a matter of clearing a
/// field and leaves plan entries and shopping lists pointing at a variant,
/// never at a group.
///
/// There is no tombstone. A group is not something the trash can hold: it is
/// drawn as a group while at least two of its members are alive, and a
/// `variantGroupID` naming a row that is gone reads as "ungrouped" rather
/// than as damage.
public struct VariantGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// The dish, as opposed to the versions of it: "Chili con Carne".
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .nowInSyncPrecision,
        updatedAt: Date = .nowInSyncPrecision
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension VariantGroup {
    /// What to call the dish two recipes are versions of.
    ///
    /// The name they already share, where they share one: "Ajvar-Suppe" and
    /// "Ajvar-Suppe vegan" are both an Ajvar-Suppe, and asking the cook to
    /// type that out again would be asking them to repeat themselves.
    ///
    /// Only up to a word boundary, and only from three characters on. The
    /// common prefix of "Chili con Carne" and "Chiligarnelen" is "Chili" by
    /// letters and nothing by meaning, and the VISION's own example —
    /// "Chili con Carne" against "Linseneintopf mit Chili" — has no prefix at
    /// all. Where nothing survives those two rules the first recipe's title
    /// stands in, which is always a name even when it is not yet the right
    /// one. A suggestion either way: it is prefilled, not decided.
    public static func suggestedTitle(for recipes: [Recipe]) -> String {
        guard let first = recipes.first else { return "" }
        guard recipes.count > 1 else { return first.title }

        var prefix = first.title
        for recipe in recipes.dropFirst() {
            prefix = String(
                zip(prefix, recipe.title)
                    .prefix { $0.lowercased() == $1.lowercased() }
                    .map(\.0)
            )
            if prefix.isEmpty { break }
        }

        // A prefix that stops mid-word is a letter count, not a name. It has
        // to end where a word ends in every title it came from, which is
        // either at a separator in the longer text or at the whole of it.
        while let last = prefix.last {
            let endsCleanly = recipes.allSatisfy { recipe in
                recipe.title.count == prefix.count
                    || recipe.title.dropFirst(prefix.count).first.map(Self.isSeparator) == true
            }
            if endsCleanly, !Self.isSeparator(last) { break }
            prefix.removeLast()
        }

        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 3 ? trimmed : first.title
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character == "-" || character == "," || character == "("
    }
}

extension Recipe {
    /// A second version of this recipe, as a full recipe of its own.
    ///
    /// A copy rather than a delta, which is the decision the whole feature
    /// rests on: a derived variant would have no text of its own, and text
    /// is the truth here. What it leaves behind is as deliberate as what it
    /// takes:
    ///
    /// - **Pictures.** ``StoredRecipeImage`` owns a `recipeID` and
    ///   `RecipeLibrary.save` prunes by that ownership, so copied `imageIDs`
    ///   would name rows the variant does not own — ids that render nothing,
    ///   and silently, since a recipe without pictures looks like a recipe
    ///   nobody photographed. A variant starts without them and gets its own.
    /// - **Favourite and "will ich kochen".** Both are judgments about a
    ///   recipe someone has cooked, and nobody has cooked this one yet. A
    ///   copied wish would also say the same thing twice to a week that can
    ///   only act on one of them.
    ///
    /// Categories come along because the vegetarian chili is still a main
    /// course, and a variant missing from every filter the original answers
    /// would be a variant nobody finds. The source comes along because the
    /// variant is overwhelmingly still that recipe, whatever was changed in
    /// it.
    public func variantCopy(
        title newTitle: String,
        in groupID: UUID,
        id newID: UUID = UUID(),
        now: Date = .nowInSyncPrecision
    ) -> Recipe {
        var copy = self
        copy.id = newID
        copy.title = newTitle
        copy.variantGroupID = groupID
        copy.imageIDs = []
        copy.isFavorite = false
        copy.wantToCook = false
        copy.createdAt = now
        copy.updatedAt = now
        copy.deletedAt = nil
        return copy
    }
}
