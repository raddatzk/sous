import Foundation

/// Reads a recipe out of a web page.
///
/// Recipe sites embed their recipe as schema.org JSON-LD, because that is
/// what search engines read — which makes the structured version of the page
/// available to anyone who asks for it. No AI is needed to get at it, and
/// none should be: the data is already structured, and a model would only
/// add a chance of getting it wrong.
///
/// Pages without that markup are not handled here. They are the case for
/// generation from the page's text, later.
public enum RecipeWebImport {
    /// A recipe found in a page, with the pictures it points at.
    public struct Extracted: Sendable, Hashable {
        public var recipe: Recipe
        /// Where the pictures are, not the pictures themselves — fetching
        /// them is the caller's business.
        public var imageURLs: [URL]
    }

    public enum Failure: Error, LocalizedError {
        case noRecipeFound

        public var errorDescription: String? {
            "Auf dieser Seite wurde kein Rezept gefunden."
        }
    }

    /// Finds the recipe in a page's HTML.
    public static func extract(from html: String, url: URL) throws -> Extracted {
        guard let object = recipeObject(in: html) else { throw Failure.noRecipeFound }
        return extracted(from: object, url: url)
    }

    // MARK: - Finding the recipe

    /// Every `application/ld+json` block, searched for something of type
    /// Recipe — which may be the whole document, one entry of an array, or
    /// buried in an `@graph`.
    static func recipeObject(in html: String) -> [String: Any]? {
        for block in jsonBlocks(in: html) {
            guard let json = try? JSONSerialization.jsonObject(
                with: Data(block.utf8), options: [.fragmentsAllowed]
            ) else { continue }
            if let recipe = findRecipe(in: json) { return recipe }
        }
        return nil
    }

    private static func jsonBlocks(in html: String) -> [String] {
        let pattern = /<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>(.*?)<\/script>/
            .ignoresCase()
            .dotMatchesNewlines()
        return html.matches(of: pattern).map { String($0.1) }
    }

    private static func findRecipe(in json: Any) -> [String: Any]? {
        switch json {
        case let object as [String: Any]:
            if isRecipe(object) { return object }
            // Sites commonly wrap everything in one @graph.
            for key in ["@graph", "mainEntity", "mainEntityOfPage", "itemListElement"] {
                if let nested = object[key], let found = findRecipe(in: nested) { return found }
            }
            return nil
        case let array as [Any]:
            return array.lazy.compactMap { findRecipe(in: $0) }.first
        default:
            return nil
        }
    }

    private static func isRecipe(_ object: [String: Any]) -> Bool {
        switch object["@type"] {
        case let type as String: type.caseInsensitiveCompare("Recipe") == .orderedSame
        case let types as [Any]:
            types.contains { ($0 as? String)?.caseInsensitiveCompare("Recipe") == .orderedSame }
        default: false
        }
    }

    // MARK: - Reading it

    private static func extracted(from object: [String: Any], url: URL) -> Extracted {
        let prep = RecipeFieldParsing.seconds(in: string(object["prepTime"]))
        let cook = RecipeFieldParsing.seconds(in: string(object["cookTime"]))

        let recipe = Recipe(
            title: RecipeFieldParsing.nonEmpty(text(object["name"])) ?? "Rezept",
            summary: RecipeFieldParsing.nonEmpty(text(object["description"])),
            servings: RecipeFieldParsing.servings(from: yield(object["recipeYield"])),
            ingredientsText: ingredients(object["recipeIngredient"] ?? object["ingredients"]),
            instructionsText: instructions(object["recipeInstructions"]),
            categories: categories(object),
            source: RecipeSource(kind: .web, url: url, name: url.host()),
            prepTimeSeconds: prep,
            cookTimeSeconds: cook,
            totalTimeSeconds: RecipeFieldParsing.seconds(in: string(object["totalTime"]))
        )
        return Extracted(recipe: recipe, imageURLs: imageURLs(object["image"], relativeTo: url))
    }

    private static func ingredients(_ value: Any?) -> String {
        lines(value).joined(separator: "\n")
    }

    /// Instructions come as a paragraph, a list of strings, a list of
    /// HowToStep objects, or sections holding steps — all four appear in the
    /// wild, sometimes on the same site.
    private static func instructions(_ value: Any?) -> String {
        switch value {
        case let text as String:
            return plainText(text)
        case let array as [Any]:
            return array.flatMap { step($0) }.joined(separator: "\n")
        case let object as [String: Any]:
            return step(object).joined(separator: "\n")
        default:
            return ""
        }
    }

    private static func step(_ value: Any) -> [String] {
        switch value {
        case let text as String:
            return [plainText(text)].filter { !$0.isEmpty }
        case let object as [String: Any]:
            let type = (object["@type"] as? String)?.lowercased() ?? ""
            if type == "howtosection" {
                // A section becomes a heading, which is how groups are
                // written in a recipe's own text.
                let name = RecipeFieldParsing.nonEmpty(text(object["name"]))
                let steps = (object["itemListElement"] as? [Any])?.flatMap { step($0) } ?? []
                return (name.map { ["# \($0)"] } ?? []) + steps
            }
            if let text = RecipeFieldParsing.nonEmpty(text(object["text"] ?? object["name"])) {
                return [text]
            }
            return []
        default:
            return []
        }
    }

    private static func categories(_ object: [String: Any]) -> [String] {
        var found: [String] = []
        for key in ["recipeCategory", "recipeCuisine", "keywords"] {
            found += lines(object[key]).flatMap { $0.components(separatedBy: ",") }
        }
        var seen = Set<String>()
        return found
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 40 && seen.insert($0.lowercased()).inserted }
    }

    private static func imageURLs(_ value: Any?, relativeTo base: URL) -> [URL] {
        let candidates: [String] = switch value {
        case let text as String: [text]
        case let array as [Any]: array.flatMap { imageStrings($0) }
        case let object as [String: Any]: imageStrings(object)
        default: []
        }
        // The first is the one sites lead with; the rest are usually the
        // same picture in other crops.
        return candidates.prefix(1).compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    private static func imageStrings(_ value: Any) -> [String] {
        if let text = value as? String { return [text] }
        guard let object = value as? [String: Any] else { return [] }
        if let url = object["url"] as? String { return [url] }
        if let contentURL = object["contentUrl"] as? String { return [contentURL] }
        return []
    }

    /// A yield can be "4 Portionen", 4, or ["4", "4 servings"].
    private static func yield(_ value: Any?) -> String? {
        switch value {
        case let array as [Any]: array.compactMap { string($0) }.first
        default: string(value)
        }
    }

    // MARK: - Values

    private static func lines(_ value: Any?) -> [String] {
        switch value {
        case let text as String: [plainText(text)].filter { !$0.isEmpty }
        case let array as [Any]: array.compactMap { RecipeFieldParsing.nonEmpty(text($0)) }
        default: []
        }
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let text as String: plainText(text)
        case let number as NSNumber: number.stringValue
        case let object as [String: Any]: (object["text"] as? String).map { plainText($0) }
        default: nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    /// Markup and entities out, one line per paragraph.
    ///
    /// Sites put `<p>` and `<br>` inside JSON-LD strings often enough that
    /// leaving them in would show tags to the cook.
    static func plainText(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</p>", "\n"),
            ("(?i)</li>", "\n"),
            ("<[^>]+>", ""),
        ] {
            text = text.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression
            )
        }
        for (entity, character) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"),
            ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&auml;", "ä"),
            ("&ouml;", "ö"), ("&uuml;", "ü"), ("&Auml;", "Ä"), ("&Ouml;", "Ö"),
            ("&Uuml;", "Ü"), ("&szlig;", "ß"), ("&#x27;", "'"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
