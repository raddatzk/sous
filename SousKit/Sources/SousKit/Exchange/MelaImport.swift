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
    public static let fileExtensions = ["melarecipe", "melarecipes"]

    public static func read(_ data: Data, named name: String) throws -> RecipeImportBatch {
        if ZIPArchive.looksLikeArchive(data) {
            return readArchive(data, named: name)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw RecipeImportError.unrecognizedFormat
        }
        switch json {
        case let object as [String: Any]:
            return batch(from: [object], names: [name])
        case let array as [Any]:
            let objects = array.compactMap { $0 as? [String: Any] }
            return batch(from: objects, names: objects.indices.map { "\(name) (\($0 + 1))" })
        default:
            throw RecipeImportError.unrecognizedFormat
        }
    }

    /// A `.melarecipes` bundle: a zip of individual recipe files.
    private static func readArchive(_ data: Data, named name: String) -> RecipeImportBatch {
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
            let single = batch(from: [object], names: [file])
            recipes.append(contentsOf: single.recipes)
            problems.append(contentsOf: single.problems)
        }
        return RecipeImportBatch(recipes: recipes, problems: problems)
    }

    private static func batch(from objects: [[String: Any]], names: [String]) -> RecipeImportBatch {
        var recipes: [ImportedRecipe] = []
        var problems: [RecipeImportProblem] = []
        for (index, object) in objects.enumerated() {
            let name = index < names.count ? names[index] : "Rezept \(index + 1)"
            if let imported = recipe(from: object) {
                recipes.append(imported)
            } else {
                problems.append(RecipeImportProblem(name: name, reason: "Rezept ohne Titel."))
            }
        }
        return RecipeImportBatch(recipes: recipes, problems: problems)
    }

    // MARK: - One recipe

    private static func recipe(from object: [String: Any]) -> ImportedRecipe? {
        let title = string(object["title"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }

        let prep = seconds(in: string(object["prepTime"]))
        let cook = seconds(in: string(object["cookTime"]))
        let total = seconds(in: string(object["totalTime"]))

        let recipe = Recipe(
            // Derived from Mela's own id, so importing the same library twice
            // updates the recipes instead of doubling them.
            id: identifier(for: object),
            title: title,
            summary: nonEmpty(string(object["text"])),
            servings: servings(from: string(object["yield"])),
            ingredientsText: lines(object["ingredients"]),
            instructionsText: lines(object["instructions"]),
            categories: categories(object["categories"]),
            isFavorite: bool(object["favorite"]) ?? false,
            wantToCook: bool(object["wantToCook"]) ?? false,
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
        if let id = nonEmpty(string(object["id"])) {
            if let uuid = UUID(uuidString: id) { return uuid }
            return StableID.make(namespace: "mela", index: 0, content: id)
        }
        // No id at all: fall back to the title, which at least keeps a second
        // import of the same file from producing a second copy.
        let title = string(object["title"]) ?? ""
        return StableID.make(namespace: "mela.title", index: 0, content: title)
    }

    private static func source(from object: [String: Any]) -> RecipeSource {
        guard let link = nonEmpty(string(object["link"])), let url = URL(string: link) else {
            return .manual
        }
        return RecipeSource(kind: .web, url: url, name: url.host())
    }

    /// Mela keeps nutrition as a block of text of its own. Sous has nowhere
    /// to put it until the nutrition database lands, and dropping what the
    /// user wrote would be worse than parking it under the notes.
    private static func notes(from object: [String: Any]) -> String? {
        let notes = nonEmpty(string(object["notes"]))
        guard let nutrition = nonEmpty(string(object["nutrition"])) else { return notes }
        let block = "Nährwerte (aus Mela):\n\(nutrition)"
        guard let notes else { return block }
        return "\(notes)\n\n\(block)"
    }

    // MARK: - Fields

    /// Text that may have been written as one string or as a list of lines.
    private static func lines(_ value: Any?) -> String {
        if let text = string(value) { return text }
        if let array = value as? [Any] {
            return array.compactMap { string($0) }.joined(separator: "\n")
        }
        return ""
    }

    private static func categories(_ value: Any?) -> [String] {
        let names: [String] = if let array = value as? [Any] {
            array.compactMap { string($0) }
        } else if let text = string(value) {
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
            return string(value).flatMap { decodeImage($0) }.map { [$0] } ?? []
        }
        return array.compactMap { string($0) }.compactMap { decodeImage($0) }
    }

    private static func decodeImage(_ text: String) -> Data? {
        var encoded = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if encoded.hasPrefix("data:"), let comma = encoded.firstIndex(of: ",") {
            encoded = String(encoded[encoded.index(after: comma)...])
        }
        guard !encoded.isEmpty else { return nil }
        return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
    }

    /// "4 Portionen", "4", "Für 4 Personen" — the first number in it.
    static func servings(from text: String?) -> Int {
        guard let text, let match = text.firstMatch(of: /\d+/), let value = Int(match.0) else {
            return 2
        }
        return value.clamped(to: Recipe.servingsRange)
    }

    /// A duration as Mela may have stored it.
    ///
    /// Real exports carry "40min", "1h 30min", "20 Min", "5 Minuten", "95"
    /// and ISO-8601 periods from its web import, sometimes several of them
    /// in one field. Every number with its unit is therefore added up: a
    /// parser that stopped at the first one would read "1h 30min" as an
    /// hour and quietly lose half of every long recipe.
    static func seconds(in text: String?) -> Int? {
        guard let text = nonEmpty(text) else { return nil }
        if let period = isoPeriodSeconds(text) { return period }

        var total = 0
        var found = false
        for match in text.matches(of: /(\d+)\s*([\p{L}.]*)/) {
            guard let value = Int(match.1) else { continue }
            let unit = String(match.2).lowercased().trimmingCharacters(in: .init(charactersIn: "."))
            let multiplier: Int
            // "std" before "s": both start the same way and mean very
            // different things.
            if unit.hasPrefix("h") || unit.hasPrefix("std") || unit.hasPrefix("stunde") {
                multiplier = 3600
            } else if unit.hasPrefix("sek") || unit.hasPrefix("sec") || unit == "s" {
                multiplier = 1
            } else if unit.isEmpty || unit.hasPrefix("m") {
                // A bare number in a time field means minutes.
                multiplier = 60
            } else {
                continue
            }
            total += value * multiplier
            found = true
        }
        return found && total > 0 ? total : nil
    }

    private static func isoPeriodSeconds(_ text: String) -> Int? {
        guard let match = text.firstMatch(
            of: /^P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/.ignoresCase()
        ) else { return nil }
        let days = match.1.flatMap { Int($0) } ?? 0
        let hours = match.2.flatMap { Int($0) } ?? 0
        let minutes = match.3.flatMap { Int($0) } ?? 0
        let seconds = match.4.flatMap { Int($0) } ?? 0
        let total = days * 86400 + hours * 3600 + minutes * 60 + seconds
        return total > 0 ? total : nil
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
        if let text = string(value) {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }

    // MARK: - Loose values

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

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
