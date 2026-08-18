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
}
