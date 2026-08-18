import Foundation

/// A recipe as it comes out of a file, before anything is stored.
///
/// Pictures travel beside the recipe rather than inside it: a recipe only
/// references image ids, and those ids do not exist until the image store has
/// taken the bytes.
public struct ImportedRecipe: Sendable, Hashable {
    public var recipe: Recipe
    /// Pictures in the order the file listed them, still as they were found.
    public var images: [Data]

    public init(recipe: Recipe, images: [Data] = []) {
        self.recipe = recipe
        self.images = images
    }
}

/// One entry that could not be read, kept so an import can report what it
/// skipped instead of failing as a whole.
public struct RecipeImportProblem: Sendable, Hashable {
    /// The file or archive entry it happened in.
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// How far a running import has got.
public struct RecipeImportProgress: Sendable, Hashable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// `nil` while the file is still being decoded and the count is unknown.
    public var fraction: Double? {
        total > 0 ? Double(done) / Double(total) : nil
    }
}

/// What an import did, once it is over.
public struct RecipeImportSummary: Sendable, Hashable {
    public var imported: Int
    public var problems: [RecipeImportProblem]

    public init(imported: Int, problems: [RecipeImportProblem] = []) {
        self.imported = imported
        self.problems = problems
    }
}

/// What reading one file produced.
public struct RecipeImportBatch: Sendable, Hashable {
    public var recipes: [ImportedRecipe]
    public var problems: [RecipeImportProblem]

    public init(recipes: [ImportedRecipe] = [], problems: [RecipeImportProblem] = []) {
        self.recipes = recipes
        self.problems = problems
    }
}

public enum RecipeImportError: Error, LocalizedError, Sendable {
    /// The bytes are not this format at all.
    case unrecognizedFormat
    case unsupportedFileType(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            "Die Datei konnte nicht gelesen werden."
        case .unsupportedFileType(let type):
            "Dateien vom Typ „\(type)“ können nicht importiert werden."
        }
    }
}

/// One file format recipes can be read from.
///
/// A protocol rather than a free function, because Mela is only the first:
/// Paprika, schema.org JSON-LD and Sous's own export all have to produce the
/// same ``ImportedRecipe`` values out of different bytes, and the code that
/// stores them should not know which one it is looking at.
public protocol RecipeImportFormat: Sendable {
    /// Extensions this format claims, lowercased and without the dot.
    static var fileExtensions: [String] { get }

    /// Reads every recipe the data holds.
    ///
    /// Throws only when the data is not this format at all. A single
    /// unreadable entry inside an archive is reported as a problem, because
    /// one broken recipe should not cost the user the other four hundred.
    static func read(_ data: Data, named name: String) throws -> RecipeImportBatch
}

/// The formats the app can read, tried in order.
public enum RecipeImport {
    public static let formats: [any RecipeImportFormat.Type] = [MelaImport.self]

    /// Reads a file by its name's extension.
    public static func read(_ data: Data, named name: String) throws -> RecipeImportBatch {
        let ext = (name as NSString).pathExtension.lowercased()
        guard let format = formats.first(where: { $0.fileExtensions.contains(ext) }) else {
            throw RecipeImportError.unsupportedFileType(ext.isEmpty ? name : ext)
        }
        return try format.read(data, named: name)
    }
}
