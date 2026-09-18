import Foundation

/// Reads Paprika's export files.
///
/// A `.paprikarecipes` export is a zip of `.paprikarecipe` files, and each
/// of those is one recipe as gzip-compressed JSON. The recipe itself is
/// shaped much like Mela's — ingredients and directions as written text,
/// the photo as base64 — so the reading is a mapping of field names rather
/// than a conversion.
public enum PaprikaImport: RecipeImportFormat {
    public static let fileExtensions = ["paprikarecipes", "paprikarecipe"]

    public static func read(_ data: Data, named name: String) throws -> RecipeImportBatch {
        if ZIPArchive.looksLikeArchive(data) {
            return readArchive(data, named: name)
        }
        guard let object = object(in: data) else { throw RecipeImportError.unrecognizedFormat }
        return batch(from: object, named: name)
    }

    private static func readArchive(_ data: Data, named name: String) -> RecipeImportBatch {
        guard let entries = try? ZIPArchive.entries(in: data) else {
            return RecipeImportBatch(problems: [
                RecipeImportProblem(name: name, reason: "Das Archiv konnte nicht geöffnet werden.")
            ])
        }

        var recipes: [ImportedRecipe] = []
        var problems: [RecipeImportProblem] = []
        for entry in entries {
            let file = (entry.name as NSString).lastPathComponent
            guard !file.hasPrefix("."), !entry.name.hasPrefix("__MACOSX/") else { continue }

            guard let object = object(in: entry.data) else {
                problems.append(RecipeImportProblem(name: file, reason: "Kein lesbares Rezept."))
                continue
            }
            let single = batch(from: object, named: file)
            recipes.append(contentsOf: single.recipes)
            problems.append(contentsOf: single.problems)
        }
        return RecipeImportBatch(recipes: recipes, problems: problems)
    }

    /// The recipe's JSON, compressed as Paprika writes it or already
    /// unpacked by someone who went looking inside.
    private static func object(in data: Data) -> [String: Any]? {
        let json = GZip.isCompressed(data) ? GZip.decompress(data) : data
        guard let json else { return nil }
        return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    }

    private static func batch(from object: [String: Any], named name: String) -> RecipeImportBatch {
        guard let imported = recipe(from: object) else {
            return RecipeImportBatch(problems: [
                RecipeImportProblem(name: name, reason: "Rezept ohne Titel.")
            ])
        }
        return RecipeImportBatch(recipes: [imported])
    }

    // MARK: - One recipe

    private static func recipe(from object: [String: Any]) -> ImportedRecipe? {
        guard let title = RecipeFieldParsing.nonEmpty(string(object["name"])) else { return nil }

        let recipe = Recipe(
            // Derived from Paprika's own uid, so importing the same export
            // twice updates the recipes instead of doubling them.
            id: identifier(for: object, title: title),
            title: title,
            summary: RecipeFieldParsing.nonEmpty(text(object["description"])),
            servings: RecipeFieldParsing.servings(from: string(object["servings"])),
            ingredientsText: text(object["ingredients"]),
            instructionsText: text(object["directions"]),
            categories: categories(object["categories"]),
            isFavorite: bool(object["on_favorites"]) ?? false,
            notes: RecipeFieldParsing.nonEmpty(text(object["notes"])),
            source: source(from: object),
            // Paprika writes "10 mins" and "1 hr 30 mins"; the shared parser
            // adds the parts up.
            prepTimeSeconds: RecipeFieldParsing.seconds(in: string(object["prep_time"])),
            cookTimeSeconds: RecipeFieldParsing.seconds(in: string(object["cook_time"])),
            totalTimeSeconds: RecipeFieldParsing.seconds(in: string(object["total_time"])),
            createdAt: date(object["created"]) ?? .nowInSyncPrecision,
            updatedAt: .nowInSyncPrecision
        )
        // Rating, difficulty and nutrition are left behind: Sous has no
        // rating, and works out effort and nutrition itself — a second,
        // disagreeing reading beside its own would only confuse.
        return ImportedRecipe(recipe: recipe, images: images(from: object))
    }

    private static func identifier(for object: [String: Any], title: String) -> UUID {
        if let uid = RecipeFieldParsing.nonEmpty(string(object["uid"])) {
            if let uuid = UUID(uuidString: uid) { return uuid }
            return StableID.make(namespace: "paprika", index: 0, content: uid)
        }
        return StableID.make(namespace: "paprika.title", index: 0, content: title)
    }

    /// Paprika keeps the link and the name of where a recipe came from
    /// apart; a name without a link is a cookbook or a person, not a site.
    private static func source(from object: [String: Any]) -> RecipeSource {
        let name = RecipeFieldParsing.nonEmpty(string(object["source"]))
        if let link = RecipeFieldParsing.nonEmpty(string(object["source_url"])),
           let url = URL(string: link), url.scheme != nil {
            return RecipeSource(kind: .web, url: url, name: name ?? url.host())
        }
        return RecipeSource(kind: .manual, name: name)
    }

    /// The main photo first, then the ones Paprika attaches to the
    /// directions.
    private static func images(from object: [String: Any]) -> [Data] {
        var images: [Data] = []
        if let main = string(object["photo_data"]).flatMap(decodeImage) {
            images.append(main)
        }
        for photo in object["photos"] as? [[String: Any]] ?? [] {
            if let data = string(photo["data"]).flatMap(decodeImage) { images.append(data) }
        }
        return images
    }

    private static func decodeImage(_ text: String) -> Data? {
        let encoded = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encoded.isEmpty else { return nil }
        return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
    }

    /// "2020-04-18 14:07:04", in the time zone of the device that wrote it —
    /// which is as good a guess as any for the one reading it.
    private static func date(_ value: Any?) -> Date? {
        guard let text = RecipeFieldParsing.nonEmpty(string(value)) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }

    // MARK: - Loose values

    /// Paprika's text fields, with Windows line endings where a recipe came
    /// through its web app.
    private static func text(_ value: Any?) -> String {
        (string(value) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func categories(_ value: Any?) -> [String] {
        var seen = Set<String>()
        return (value as? [Any] ?? [])
            .compactMap { RecipeFieldParsing.nonEmpty(string($0)) }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: flag
        case let number as NSNumber: number.boolValue
        case let text as String: ["true", "yes", "1"].contains(text.lowercased())
        default: nil
        }
    }
}
