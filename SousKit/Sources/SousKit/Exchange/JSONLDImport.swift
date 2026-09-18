import Foundation

/// Reads schema.org recipes from files.
///
/// Recipe sites publish schema.org JSON-LD for search engines, and several
/// apps keep or export their recipes the same way — Nextcloud Cookbook
/// stores every recipe as a `recipe.json` in a folder of its own, beside its
/// photo. Reading such a file is the web import without the web, so the
/// fields are read by ``RecipeWebImport``; only the finding of files and
/// pictures is this reader's own.
///
/// Pictures that are only a web address are not fetched: an import reads
/// what the user handed over and does not go online four hundred times
/// behind their back.
public enum JSONLDImport: RecipeImportFormat {
    /// `.zip` for a folder of recipe files packed up — which is what
    /// downloading a Nextcloud Cookbook folder gives.
    public static let fileExtensions = ["json", "jsonld", "zip"]

    public static func read(_ data: Data, named name: String) throws -> RecipeImportBatch {
        if ZIPArchive.looksLikeArchive(data) {
            return readArchive(data, named: name)
        }
        // A `.json` could be anything; it is this format only if a recipe
        // is in it.
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { throw RecipeImportError.unrecognizedFormat }
        let objects = RecipeWebImport.recipeObjects(in: json)
        guard !objects.isEmpty else { throw RecipeImportError.unrecognizedFormat }
        return RecipeImportBatch(recipes: objects.map { imported(from: $0, sibling: nil) })
    }

    // MARK: - Archives

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "gif"]
    private static let jsonExtensions: Set<String> = ["json", "jsonld"]

    private static func readArchive(_ data: Data, named name: String) -> RecipeImportBatch {
        guard let entries = try? ZIPArchive.entries(in: data) else {
            return RecipeImportBatch(problems: [
                RecipeImportProblem(name: name, reason: "Das Archiv konnte nicht geöffnet werden.")
            ])
        }
        let files = entries.filter { entry in
            let file = (entry.name as NSString).lastPathComponent
            return !file.hasPrefix(".") && !entry.name.hasPrefix("__MACOSX/")
        }
        let recipeFiles = files.filter { jsonExtensions.contains(pathExtension($0.name)) }
        guard !recipeFiles.isEmpty else {
            return RecipeImportBatch(problems: [
                RecipeImportProblem(name: name, reason: "Im Archiv wurde kein Rezept gefunden.")
            ])
        }

        var recipes: [ImportedRecipe] = []
        var problems: [RecipeImportProblem] = []
        for entry in recipeFiles {
            let file = (entry.name as NSString).lastPathComponent
            guard let json = try? JSONSerialization.jsonObject(
                with: entry.data, options: [.fragmentsAllowed]
            ) else {
                problems.append(RecipeImportProblem(name: file, reason: "Kein lesbares Rezept."))
                continue
            }
            let objects = RecipeWebImport.recipeObjects(in: json)
            guard !objects.isEmpty else {
                problems.append(RecipeImportProblem(name: file, reason: "Kein Rezept gefunden."))
                continue
            }
            // A picture beside the file belongs to it only when there is no
            // doubt which recipe it shows.
            let sibling = objects.count == 1
                ? siblingImage(of: entry, among: files, recipeFiles: recipeFiles)
                : nil
            recipes += objects.map { imported(from: $0, sibling: sibling) }
        }
        return RecipeImportBatch(recipes: recipes, problems: problems)
    }

    /// The picture that goes with a recipe file: one named like it
    /// (`Suppe.json`, `Suppe.jpg`), or — when the recipe has its folder to
    /// itself, as in Nextcloud Cookbook — the one in that folder, preferring
    /// the full-size `full.jpg` over the thumbnails beside it.
    private static func siblingImage(
        of entry: ZIPArchive.Entry,
        among files: [ZIPArchive.Entry],
        recipeFiles: [ZIPArchive.Entry]
    ) -> Data? {
        let folder = directory(entry.name)
        let stem = ((entry.name as NSString).lastPathComponent as NSString).deletingPathExtension
        let images = files.filter {
            directory($0.name) == folder && imageExtensions.contains(pathExtension($0.name))
        }
        func named(_ name: String) -> ZIPArchive.Entry? {
            images.first {
                (($0.name as NSString).lastPathComponent as NSString)
                    .deletingPathExtension.lowercased() == name.lowercased()
            }
        }
        if let match = named(stem) { return match.data }

        let alone = recipeFiles.filter { directory($0.name) == folder }.count == 1
        guard alone else { return nil }
        return (named("full") ?? images.first)?.data
    }

    private static func directory(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func pathExtension(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    // MARK: - One recipe

    private static func imported(from object: [String: Any], sibling: Data?) -> ImportedRecipe {
        let url = RecipeWebImport.string(object["url"])
            .flatMap { URL(string: $0) }
            .flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        let found = RecipeWebImport.extracted(from: object, url: url)

        var recipe = found.recipe
        recipe.id = identifier(for: object, recipe: recipe)
        if let created = date(object["dateCreated"] ?? object["datePublished"]) {
            recipe.createdAt = created
        }

        // A picture carried inside the file wins over one lying beside it.
        let embedded = found.imageURLs.first.flatMap(decodeDataURL)
        return ImportedRecipe(recipe: recipe, images: [embedded ?? sibling].compactMap { $0 })
    }

    /// Stable across imports, so reading the same file twice updates the
    /// recipe instead of doubling it. The object's own id or address comes
    /// first; without either, the title alone would merge two different
    /// pancake recipes, so the ingredients go into it too.
    private static func identifier(for object: [String: Any], recipe: Recipe) -> UUID {
        let key = ["@id", "url"].lazy
            .compactMap { RecipeFieldParsing.nonEmpty(RecipeWebImport.string(object[$0])) }
            .first
        if let key {
            return StableID.make(namespace: "jsonld", index: 0, content: key)
        }
        return StableID.make(
            namespace: "jsonld.content", index: 0,
            content: recipe.title + "\n" + recipe.ingredientsText
        )
    }

    private static func decodeDataURL(_ url: URL) -> Data? {
        let text = url.absoluteString
        guard text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[..<comma]
        let payload = String(text[text.index(after: comma)...])
        guard header.hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
    }

    /// schema.org dates are ISO 8601, with or without a time — and with the
    /// time zone written either way round.
    private static func date(_ value: Any?) -> Date? {
        guard let text = RecipeFieldParsing.nonEmpty(RecipeWebImport.string(value)) else {
            return nil
        }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
