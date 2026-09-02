import Foundation

/// Suggesting categories while one is being typed.
///
/// Categories are free text — they exist because a recipe uses them — so the
/// suggestions come from what is already in the library rather than from a
/// fixed list. Without them a typo quietly creates a second category.
public enum CategoryCompletion {
    /// Categories worth offering for what is being typed, closest first.
    ///
    /// Nothing is offered for an empty entry: a field nobody has typed in yet
    /// is not asking a question.
    ///
    /// - Parameter excluding: the categories the recipe already carries, which
    ///   would either do nothing or read as duplicates if offered again.
    public static func suggestions(
        for partial: String,
        categories: [String],
        excluding: Set<String> = [],
        limit: Int = 6
    ) -> [String] {
        let query = partial.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }

        let taken = Set(excluding.map { $0.lowercased() })

        return categories
            .filter { category in
                let name = category.lowercased()
                return name.contains(query) && !taken.contains(name) && name != query
            }
            .sorted { first, second in
                let firstPrefixed = first.lowercased().hasPrefix(query)
                let secondPrefixed = second.lowercased().hasPrefix(query)
                return firstPrefixed == secondPrefixed
                    ? first.count < second.count
                    : firstPrefixed
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The categories a recipe carries once what was typed is added.
    ///
    /// This is where free text is tidied, because it is the one place every
    /// category enters a recipe: whitespace comes off, a pasted
    /// "Salate, Schnell" becomes two categories rather than one oddly named
    /// one, and a category the recipe already carries is not added a second
    /// time.
    ///
    /// - Parameter known: the spellings the library already uses. One of them
    ///   wins over what was just typed — "salate" under an existing "Salate"
    ///   files the recipe with the others instead of starting a second
    ///   category beside it, which is the same typo the suggestions above
    ///   exist to prevent.
    public static func adding(
        _ typed: String,
        to categories: [String],
        known: [String] = []
    ) -> [String] {
        var result = categories
        for part in typed.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            // Format characters are not whitespace to `trimmingCharacters`,
            // and a zero-width space is exactly the kind of thing a text
            // field uses as scaffolding. A name is what can be seen.
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                .filter { !$0.unicodeScalars.contains { $0.properties.generalCategory == .format } }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !result.contains(where: { $0.lowercased() == key }) else { continue }
            result.append(known.first { $0.lowercased() == key } ?? name)
        }
        return result
    }
}
