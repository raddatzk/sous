import Foundation

/// Suggesting categories while the comma-separated list is being typed.
///
/// Categories are free text — they exist because a recipe uses them — so the
/// suggestions come from what is already in the library rather than from a
/// fixed list. Without them a typo quietly creates a second category.
public enum CategoryCompletion {
    /// The entry currently being typed: everything after the last comma.
    public static func partial(in text: String) -> String? {
        let entry = text
            .split(separator: ",", omittingEmptySubsequences: false)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return entry.count >= 1 ? entry : nil
    }

    /// Categories worth offering, closest first, leaving out the ones already
    /// in the list.
    public static func suggestions(
        for text: String,
        categories: [String],
        limit: Int = 6
    ) -> [String] {
        guard let partial = partial(in: text) else { return [] }
        let query = partial.lowercased()

        let alreadyListed = Set(
            text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .dropLast()
        )

        return categories
            .filter { category in
                let name = category.lowercased()
                return name.contains(query) && !alreadyListed.contains(name) && name != query
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

    /// The list with the entry being typed replaced by the chosen category,
    /// ready for the next one.
    public static func completed(text: String, with category: String) -> String {
        var entries = text
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if entries.isEmpty {
            entries = [category]
        } else {
            entries[entries.count - 1] = category
        }
        return entries.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }
}
