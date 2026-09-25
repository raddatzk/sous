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

    /// The scheme Mela writes, e.g.
    /// `mela://recipe/rewe.de/rezepte/spaghetti-kuerbis-carbonara`.
    public static let melaScheme = "mela"

    /// What a recipe link points at.
    public enum Target: Hashable, Sendable {
        /// A recipe in this library.
        case local(UUID)
        /// A recipe identified the way another app names it. Kept as written
        /// so an import can map it once the target exists here; Mela's
        /// identifiers are multi-part paths, not UUIDs.
        case external(scheme: String, identifier: String)
    }

    public static func target(from url: URL) -> Target? {
        guard url.host() == "recipe" else { return nil }
        let identifier = url.path().trimmingPrefix("/")

        switch url.scheme {
        case scheme:
            return UUID(uuidString: String(identifier)).map(Target.local)
        case melaScheme:
            return identifier.isEmpty
                ? nil
                : .external(scheme: melaScheme, identifier: String(identifier))
        default:
            return nil
        }
    }

    /// The recipe id a URL points at, or `nil` if it is not a local one.
    public static func recipeID(from url: URL) -> UUID? {
        guard case .local(let id) = target(from: url) else { return nil }
        return id
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
