import Foundation

/// What tells the versions of one dish apart, computed from the versions
/// themselves.
///
/// The comparison is the one thing no single recipe can show, and it is
/// presentation throughout: computed when the screen is drawn and never
/// persisted, so a bad answer here is an ugly screen rather than a corrupted
/// recipe. Nothing in a ``VariantGroup`` is stored because of it.
///
/// A line earns a row by being written differently somewhere: missing from
/// one version, or called for in another amount. The twelve lines all five
/// versions write identically answer no question the screen is there to
/// answer and stay off it.
///
/// Amounts come along as they stand, and are compared as they stand. The
/// members may be written for different serving counts, so "400 g" against
/// "200 g" is reported as a difference without this deciding which is more —
/// scaling them onto a common count would turn a display into a calculation,
/// and one that cannot be done at all where the units do not convert. The
/// serving counts are beside the columns; the reader can see what they mean.
///
/// How a line is prepared — gehackt against gewürfelt — is not a difference
/// here. It belongs to the instructions, and those differ between variants
/// by construction.
public struct VariantComparison: Hashable, Sendable {
    /// One ingredient the members disagree about.
    public struct Row: Identifiable, Hashable, Sendable {
        /// The canonical key both spellings reduce to, so "Cocktailtomaten"
        /// against "Tomaten" is not counted as a difference.
        public let key: String
        /// How to name it: the first spelling a member used, link syntax
        /// stripped.
        public let title: String
        /// The line each member writes for it, missing where a member does
        /// not call for it at all — which is the difference this row most
        /// often reports. Where a member names it on more than one line, the
        /// first is taken.
        public let ingredients: [UUID: RecipeIngredient]

        public var id: String { key }

        /// Whether this is a plain presence difference — someone has it,
        /// someone does not — as opposed to everyone having it in a
        /// different amount.
        public func isMissing(from member: Recipe) -> Bool {
            ingredients[member.id] == nil
        }
    }

    /// The versions being compared, in creation order.
    public let members: [Recipe]
    /// What they disagree about, in the order the ingredients first appear.
    public let rows: [Row]
    /// How many ingredients every member calls for alike — not listed, but
    /// worth saying, or a group of near-identical variants looks like a
    /// group of unrelated recipes.
    public let sharedCount: Int

    /// Compares `members` line by line.
    ///
    /// `catalog` decides what counts as the same ingredient, which is the
    /// only judgment in here — and it is the same one the shopping list
    /// already makes when it puts two spellings on one line.
    public static func make(
        of members: [Recipe],
        catalog: IngredientCatalog = .bundled
    ) -> VariantComparison {
        var order: [String] = []
        var titles: [String: String] = [:]
        var lines: [String: [UUID: RecipeIngredient]] = [:]

        for member in members {
            for ingredient in member.ingredients {
                let key = ShoppingItem.key(for: ingredient.name, catalog: catalog)
                guard !key.isEmpty else { continue }
                if titles[key] == nil {
                    order.append(key)
                    titles[key] = ShoppingItem.displayName(for: ingredient.name)
                }
                // First line wins: a recipe naming onions twice is writing
                // one ingredient, and picking the later line would report a
                // difference that is really a second use of the same thing.
                if lines[key]?[member.id] == nil {
                    lines[key, default: [:]][member.id] = ingredient
                }
            }
        }

        var rows: [Row] = []
        var shared = 0
        for key in order {
            let present = lines[key] ?? [:]
            let agrees = present.count == members.count
                && Set(present.values.map(Amount.init)).count == 1
            if agrees {
                shared += 1
                continue
            }
            rows.append(Row(key: key, title: titles[key] ?? key, ingredients: present))
        }
        return VariantComparison(members: members, rows: rows, sharedCount: shared)
    }

    /// An amount as written, reduced to the parts two lines can be held
    /// against each other by.
    ///
    /// Deliberately literal: 1 kg and 1000 g are two different ways of
    /// writing an ingredient list, and a screen about what the cook changed
    /// should say so rather than quietly equate them.
    private struct Amount: Hashable {
        let quantity: Quantity?
        let phrase: String?

        init(_ ingredient: RecipeIngredient) {
            quantity = ingredient.quantity
            phrase = ingredient.unquantifiedPhrase?.phrase
        }
    }
}
