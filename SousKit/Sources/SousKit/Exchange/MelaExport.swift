import Foundation

/// Writes recipes in the format ``MelaImport`` reads, under Sous's own
/// extension: `.sousrecipe` for one, `.sousrecipes` for a library.
///
/// Mela's format rather than one of Sous's own: it is the format this app's
/// model was shaped after, so nothing has to be left behind, and a file
/// written here opens in Mela, in Sous, and in anything else that learned to
/// read it. A second, private format would be one more thing to keep in step
/// for no reader that does not already exist.
public enum MelaExport {
    /// One recipe with its pictures, as the contents of a `.sousrecipe` file.
    ///
    /// `variantGroup` is written into the file when the recipe is one version
    /// of a dish, because there is nowhere else for it to go: an export that
    /// dropped it would put five recipes back into a library as five
    /// strangers, and silently.
    public static func recipe(
        _ recipe: Recipe,
        images: [Data],
        variantGroup: VariantGroup? = nil
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object(for: recipe, images: images, variantGroup: variantGroup),
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// A whole library as a `.sousrecipes` archive.
    public static func library(
        _ recipes: [(recipe: Recipe, images: [Data], variantGroup: VariantGroup?)]
    ) throws -> Data {
        var used = Set<String>()
        let entries = try recipes.map { item in
            ZIPWriter.Entry(
                name: fileName(for: item.recipe, avoiding: &used),
                data: try recipe(item.recipe, images: item.images, variantGroup: item.variantGroup),
                modified: item.recipe.updatedAt
            )
        }
        return ZIPWriter.archive(entries)
    }

    /// A file name a person can read in the Finder, and that stays unique
    /// even when two recipes are called the same thing.
    static func fileName(for recipe: Recipe, avoiding used: inout Set<String>) -> String {
        let stripped = recipe.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = stripped.isEmpty ? "Rezept" : String(stripped.prefix(60))

        var candidate = base
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return "\(candidate).sousrecipe"
    }

    private static func object(
        for recipe: Recipe,
        images: [Data],
        variantGroup: VariantGroup? = nil
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": recipe.id.uuidString,
            "title": recipe.title,
            "text": recipe.summary ?? "",
            "yield": String(recipe.servings),
            "ingredients": recipe.ingredientsText,
            "instructions": recipe.instructionsText,
            "notes": recipe.notes ?? "",
            "categories": recipe.categories,
            "favorite": recipe.isFavorite,
            "wantToCook": recipe.wantToCook,
            // Mela counts from Apple's reference date, and its own import
            // reads it back that way.
            "date": recipe.createdAt.timeIntervalSinceReferenceDate,
            "images": images.map { $0.base64EncodedString() },
        ]
        // Times are written the way Mela writes them, so its own reader and
        // ours both understand them.
        if let prep = recipe.prepTimeSeconds { object["prepTime"] = duration(prep) }
        if let cook = recipe.cookTimeSeconds { object["cookTime"] = duration(cook) }
        if let total = recipe.totalTimeSeconds { object["totalTime"] = duration(total) }
        if let url = recipe.source.url { object["link"] = url.absoluteString }
        // Sous's own key. Mela ignores what it does not know, and so does
        // every other reader of this format.
        if let variantGroup {
            object["sousVariantGroup"] = [
                "id": variantGroup.id.uuidString,
                "title": variantGroup.title,
            ]
        }
        return object
    }

    /// "20min", "1h 30min" — what its exports contain.
    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        guard minutes >= 60 else { return "\(minutes)min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)min"
    }
}
