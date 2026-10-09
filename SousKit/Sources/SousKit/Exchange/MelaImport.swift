import Foundation

/// Reads Mela's export files.
///
/// Mela is where this app's recipes come from, and its file format is the one
/// Sous's own model was shaped after — ingredients and instructions as
/// written text, one entry per line — so an import is close to a copy rather
/// than a conversion.
///
/// The reader is deliberately forgiving about what it finds. Mela has written
/// these files across many versions: a field may be a string in one and an
/// array in the next, times may be ISO-8601 durations from a web import or
/// "20 Minuten" as somebody typed them, and unknown keys simply do not
/// concern us. Anything unreadable is reported per entry, so one damaged
/// recipe never costs the user the other four hundred.
public enum MelaImport: RecipeImportFormat {
    /// Mela's own extensions. Sous writes the same format under its own
    /// name, and ``SousImport`` reads those files.
    public static let fileExtensions = ["melarecipe", "melarecipes"]

    public static func read(_ data: Data, named name: String) throws -> RecipeImportBatch {
        try read(data, named: name, extending: nil)
    }

    /// What a format built on Mela's adds to a recipe from the keys it keeps
    /// beside Mela's own.
    typealias Extension = @Sendable (inout ImportedRecipe, [String: Any]) -> Void

    /// Reads Mela's fields, and hands every recipe's object to `extend` for
    /// whatever else it says.
    static func read(_ data: Data, named name: String, extending extend: Extension?) throws -> RecipeImportBatch {
        if ZIPArchive.looksLikeArchive(data) {
            return readArchive(data, named: name, extending: extend)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw RecipeImportError.unrecognizedFormat
        }
        switch json {
        case let object as [String: Any]:
            return batch(from: [object], names: [name], extending: extend)
        case let array as [Any]:
            let objects = array.compactMap { $0 as? [String: Any] }
            return batch(from: objects, names: objects.indices.map { "\(name) (\($0 + 1))" }, extending: extend)
        default:
            throw RecipeImportError.unrecognizedFormat
        }
    }

    /// A `.melarecipes` bundle: a zip of individual recipe files.
    private static func readArchive(_ data: Data, named name: String, extending extend: Extension?) -> RecipeImportBatch {
        guard let entries = try? ZIPArchive.entries(in: data) else {
            return RecipeImportBatch(problems: [
                RecipeImportProblem(name: name, reason: "Das Archiv konnte nicht geöffnet werden.")
            ])
        }

        var recipes: [ImportedRecipe] = []
        var problems: [RecipeImportProblem] = []
        for entry in entries {
            // Skip what the Finder and the archiver leave behind.
            let file = (entry.name as NSString).lastPathComponent
            guard !file.hasPrefix("."), !entry.name.hasPrefix("__MACOSX/") else { continue }

            guard let object = try? JSONSerialization.jsonObject(with: entry.data) as? [String: Any]
            else {
                problems.append(
                    RecipeImportProblem(name: file, reason: "Kein lesbares Rezept.")
                )
                continue
            }
            let single = batch(from: [object], names: [file], extending: extend)
            recipes.append(contentsOf: single.recipes)
            problems.append(contentsOf: single.problems)
        }
        return RecipeImportBatch(recipes: recipes, problems: problems)
    }

    private static func batch(from objects: [[String: Any]], names: [String], extending extend: Extension?) -> RecipeImportBatch {
        var recipes: [ImportedRecipe] = []
        var problems: [RecipeImportProblem] = []
        for (index, object) in objects.enumerated() {
            let name = index < names.count ? names[index] : "Rezept \(index + 1)"
            if var imported = recipe(from: object) {
                extend?(&imported, object)
                recipes.append(imported)
            } else {
                problems.append(RecipeImportProblem(name: name, reason: "Rezept ohne Titel."))
            }
        }
        return RecipeImportBatch(recipes: recipes, problems: problems)
    }

    // MARK: - One recipe

    private static func recipe(from object: [String: Any]) -> ImportedRecipe? {
        let title = RecipeFieldParsing.string(object["title"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }

        let prep = RecipeFieldParsing.seconds(in: RecipeFieldParsing.string(object["prepTime"]))
        let cook = RecipeFieldParsing.seconds(in: RecipeFieldParsing.string(object["cookTime"]))
        let total = RecipeFieldParsing.seconds(in: RecipeFieldParsing.string(object["totalTime"]))

        let recipe = Recipe(
            // Derived from Mela's own id, so importing the same library twice
            // updates the recipes instead of doubling them.
            id: identifier(for: object),
            title: title,
            summary: RecipeFieldParsing.nonEmpty(RecipeFieldParsing.string(object["text"])),
            servings: RecipeFieldParsing.servings(from: RecipeFieldParsing.string(object["yield"])),
            ingredientsText: lines(object["ingredients"]),
            instructionsText: lines(object["instructions"]),
            categories: categories(object["categories"]),
            isFavorite: RecipeFieldParsing.bool(object["favorite"]) ?? false,
            wantToCook: RecipeFieldParsing.bool(object["wantToCook"]) ?? false,
            notes: notes(from: object),
            source: source(from: object),
            prepTimeSeconds: prep,
            cookTimeSeconds: cook,
            // Mela usually records nothing but a total, and that is a
            // reading of its own — not cooking time by another name.
            totalTimeSeconds: total,
            createdAt: date(object["date"]) ?? .nowInSyncPrecision,
            updatedAt: .nowInSyncPrecision
        )
        return ImportedRecipe(recipe: recipe, images: images(object["images"]))
    }

    private static func identifier(for object: [String: Any]) -> UUID {
        if let id = RecipeFieldParsing.nonEmpty(RecipeFieldParsing.string(object["id"])) {
            if let uuid = UUID(uuidString: id) { return uuid }
            return StableID.make(namespace: "mela", index: 0, content: id)
        }
        // No id at all: fall back to the title, which at least keeps a second
        // import of the same file from producing a second copy.
        let title = RecipeFieldParsing.string(object["title"]) ?? ""
        return StableID.make(namespace: "mela.title", index: 0, content: title)
    }

    private static func source(from object: [String: Any]) -> RecipeSource {
        guard let link = RecipeFieldParsing.nonEmpty(RecipeFieldParsing.string(object["link"])), let url = URL(string: link) else {
            return .manual
        }
        return RecipeSource(kind: .web, url: url, name: url.host())
    }

    /// Mela keeps nutrition as a block of text of its own. Sous computes its
    /// own nutrition from the ingredients now, so Mela's reading is not kept
    /// — parking it under notes would just leave a second, disagreeing set
    /// of numbers sitting next to the one the recipe page actually shows.
    private static func notes(from object: [String: Any]) -> String? {
        RecipeFieldParsing.nonEmpty(RecipeFieldParsing.string(object["notes"]))
    }

    // MARK: - Fields

    /// Text that may have been written as one string or as a list of lines.
    static func lines(_ value: Any?) -> String {
        if let text = RecipeFieldParsing.string(value) { return text }
        if let array = value as? [Any] {
            return array.compactMap { RecipeFieldParsing.string($0) }.joined(separator: "\n")
        }
        return ""
    }

    private static func categories(_ value: Any?) -> [String] {
        let names: [String] = if let array = value as? [Any] {
            array.compactMap { RecipeFieldParsing.string($0) }
        } else if let text = RecipeFieldParsing.string(value) {
            text.components(separatedBy: ",")
        } else {
            []
        }
        var seen = Set<String>()
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Pictures are base64 in the file, with or without a data-URI prefix.
    private static func images(_ value: Any?) -> [Data] {
        guard let array = value as? [Any] else {
            return RecipeFieldParsing.string(value).flatMap { RecipeFieldParsing.base64Data($0) }.map { [$0] } ?? []
        }
        return array.compactMap { RecipeFieldParsing.string($0) }.compactMap { RecipeFieldParsing.base64Data($0) }
    }

    /// Mela writes the date as a number. Which epoch it counts from depends
    /// on the version, so the value decides: anything below the year 2001 in
    /// Unix terms is counting from Apple's reference date instead.
    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let interval = number.doubleValue
            guard interval > 0 else { return nil }
            return interval < 1_000_000_000
                ? Date(timeIntervalSinceReferenceDate: interval)
                : Date(timeIntervalSince1970: interval)
        }
        if let text = RecipeFieldParsing.string(value) {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }
}
