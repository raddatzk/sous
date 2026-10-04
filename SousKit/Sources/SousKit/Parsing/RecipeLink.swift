import Foundation

/// A reference from one recipe to another, written as a markdown link with
/// the app's own scheme: `[Pizzateig](sous://recipe/<uuid>)`.
///
/// The target is identified by id rather than by title, so renaming a recipe
/// does not break every reference to it. The link text stays whatever the
/// author wrote, which is why it is a plain markdown link: exported
/// elsewhere it is still a link, not leftover syntax.
public enum RecipeLink {
    public static let scheme = "sous"

    /// How deep a chain of linked recipes is followed — by the shopping
    /// list, nutrition and effort alike. A curry references its naan, which
    /// might reference a spice mix; beyond that it is a loop or a mistake.
    static let maxDepth = 3

    public static func url(for id: UUID) -> URL {
        URL(string: "\(scheme)://recipe/\(id.uuidString)")!
    }

    /// A link to hand out — pasted into Notes, a reminder, a message —
    /// which also names the household the recipe was copied from.
    ///
    /// The id alone is not enough outside the library: the same recipe can
    /// sit in several households under the same id (a web import derives it
    /// from the page), and one household cannot see another's rows. Opened
    /// while a different household is showing, the link says where to look.
    /// Links between recipes stay without it — they never leave their
    /// household.
    public static func url(for id: UUID, household: UUID?) -> URL {
        guard let household else { return url(for: id) }
        var components = URLComponents(url: url(for: id), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: householdQueryName, value: household.uuidString)]
        return components.url!
    }

    static let householdQueryName = "household"

    /// The household a link names, or `nil` for one written without it.
    public static func householdID(from url: URL) -> UUID? {
        guard recipeID(from: url) != nil else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == householdQueryName }?.value
            .flatMap(UUID.init(uuidString:))
    }

    /// Renders a link ready to be inserted into an ingredient or step line.
    public static func markdown(title: String, id: UUID) -> String {
        "[\(title)](\(url(for: id).absoluteString))"
    }

    /// The recipe id a URL points at, or `nil` if it is not a local one.
    ///
    /// Other apps' links — Mela writes `mela://recipe/…` with a path, not a
    /// UUID — are not ours and read as none.
    public static func recipeID(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host() == "recipe" else { return nil }
        return UUID(uuidString: String(url.path().trimmingPrefix("/")))
    }

    /// Every recipe referenced in a piece of text, in the order they appear.
    ///
    /// The pattern is built per call: `Regex` is not `Sendable`, so it cannot
    /// live in a stored property under strict concurrency.
    public static func referencedIDs(in text: String) -> [UUID] {
        // A pasted link that names its household still counts.
        let pattern = /\(sous:\/\/recipe\/([0-9A-Fa-f-]{36})(?:\?[^)\s]*)?\)/
        return text.matches(of: pattern).compactMap { UUID(uuidString: String($0.1)) }
    }
}

extension Recipe {
    /// Recipes this one references, from either the ingredients or the steps.
    public var linkedRecipeIDs: [UUID] {
        var seen = Set<UUID>()
        return (RecipeLink.referencedIDs(in: ingredientsText)
            + RecipeLink.referencedIDs(in: instructionsText))
            .filter { seen.insert($0).inserted }
    }
}
