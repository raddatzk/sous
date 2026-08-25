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
    public static func partialName(in line: String, catalog: IngredientCatalog = .bundled) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasSuffix(":") else { return nil }
        guard RecipeLink.referencedIDs(in: line).isEmpty else { return nil }

        let name = IngredientParser.parseLine(line, catalog: catalog).name.trimmingCharacters(in: .whitespaces)
        return name.count >= 2 ? name : nil
    }

    /// Ingredients worth offering for a line, best match first.
    ///
    /// A name the catalog already resolves exactly is not offered — there is
    /// nothing to complete once "Tomaten" is written out. Likewise, an
    /// ingredient already written out in full on another line of `text` is
    /// skipped — completing "Sch" to "Schmand" is only a useful suggestion
    /// the first time; offering it again just invites an accidental
    /// duplicate line.
    public static func suggestions(
        forLine line: String,
        in text: String = "",
        catalog: IngredientCatalog,
        limit: Int = 6
    ) -> [CatalogIngredient] {
        guard let partial = partialName(in: line, catalog: catalog) else { return [] }
        if let exact = catalog.ingredient(for: partial),
           exact.keys.contains(IngredientCatalog.normalize(partial)) {
            return []
        }
        let used = usedIngredientNames(in: text, excluding: line, catalog: catalog)
        return catalog.suggestions(for: partial, limit: limit + used.count)
            .filter { !used.contains(IngredientCatalog.normalize($0.name)) }
            .prefix(limit)
            .map { $0 }
    }

    /// The normalized names already written out in full elsewhere in
    /// `text`, skipping `currentLine` (the one being completed) so it never
    /// excludes its own match.
    private static func usedIngredientNames(
        in text: String, excluding currentLine: String, catalog: IngredientCatalog
    ) -> Set<String> {
        var names = Set<String>()
        var skippedCurrentLine = false
        for rawLine in text.components(separatedBy: "\n") {
            guard skippedCurrentLine || rawLine != currentLine else {
                skippedCurrentLine = true
                continue
            }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let name = IngredientParser.parseLine(rawLine, catalog: catalog).name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            names.insert(IngredientCatalog.normalize(name))
        }
        return names
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
