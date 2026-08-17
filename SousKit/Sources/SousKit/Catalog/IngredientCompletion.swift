import Foundation

/// Suggesting catalog ingredients while an ingredient list is being typed.
///
/// SwiftUI's own `textInputSuggestions` is macOS-only and `TextEditor` has no
/// inline completion, so the pieces are here: which line the cursor is in,
/// what is being typed in it, and what the line becomes when a suggestion is
/// taken. The view only has to draw them.
public enum IngredientCompletion {
    /// The line the cursor sits in.
    public static func lineRange(in text: String, at cursor: String.Index) -> Range<String.Index> {
        let clamped = min(max(cursor, text.startIndex), text.endIndex)
        let start = text[..<clamped].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let end = text[clamped...].firstIndex(of: "\n") ?? text.endIndex
        return start..<end
    }

    /// What is being typed as the ingredient's name in that line, without the
    /// amount and unit — "300 g Toma" is looking for "Toma".
    ///
    /// `nil` when there is nothing worth suggesting on: a heading, a line
    /// already carrying a recipe link, or fewer than two letters.
    public static func partialName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasSuffix(":") else { return nil }
        guard RecipeLink.referencedIDs(in: line).isEmpty else { return nil }

        let name = IngredientParser.parseLine(line).name.trimmingCharacters(in: .whitespaces)
        return name.count >= 2 ? name : nil
    }

    /// Ingredients worth offering for a line, best match first.
    ///
    /// A name the catalog already resolves exactly is not offered — there is
    /// nothing to complete once "Tomaten" is written out.
    public static func suggestions(
        forLine line: String,
        catalog: IngredientCatalog,
        limit: Int = 6
    ) -> [CatalogIngredient] {
        guard let partial = partialName(in: line) else { return [] }
        if let exact = catalog.ingredient(for: partial),
           exact.keys.contains(IngredientCatalog.normalize(partial)) {
            return []
        }
        return catalog.suggestions(for: partial, limit: limit)
    }

    /// The line with the typed name replaced by the chosen ingredient,
    /// keeping the amount, the unit, and anything written after it.
    public static func completed(
        line: String,
        with ingredient: CatalogIngredient
    ) -> String {
        guard let partial = partialName(in: line),
              let range = line.range(of: partial, options: .backwards)
        else { return line }

        return line.replacingCharacters(in: range, with: ingredient.name)
    }
}
