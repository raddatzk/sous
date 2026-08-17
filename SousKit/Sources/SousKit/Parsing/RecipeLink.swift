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

    /// Renders a link ready to be inserted into an ingredient or step line.
    public static func markdown(title: String, id: UUID) -> String {
        "[\(title)](\(url(for: id).absoluteString))"
    }

    /// The recipe id a URL points at, or `nil` if it is not one of ours.
    public static func recipeID(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host() == "recipe" else { return nil }
        let identifier = url.pathComponents.last ?? ""
        return UUID(uuidString: identifier)
    }

    /// Every recipe referenced in a piece of text, in the order they appear.
    ///
    /// The pattern is built per call: `Regex` is not `Sendable`, so it cannot
    /// live in a stored property under strict concurrency.
    public static func referencedIDs(in text: String) -> [UUID] {
        let pattern = /\(sous:\/\/recipe\/([0-9A-Fa-f-]{36})\)/
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
