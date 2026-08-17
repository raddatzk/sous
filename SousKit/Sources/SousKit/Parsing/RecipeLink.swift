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
