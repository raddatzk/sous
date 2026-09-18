import Foundation

/// What a file amounts to, before anything is stored.
///
/// Neither a tap on a file in the Files app nor a pick in the import dialog
/// is yet a decision about every recipe in it: an export of a whole library
/// holds recipes the cook has long since stopped wanting, and a single file
/// may be one they already have and are only opening to read. So the file is
/// read first and measured against the library.
public enum RecipeImportOffer: Sendable, Hashable {
    /// Nothing in the file could be read.
    case nothingReadable(problems: [RecipeImportProblem])
    /// The file is one recipe, and the library has it: open it instead.
    case alreadyHere(Recipe)
    /// Recipes to look through and choose from.
    case preview(RecipeImportPreview)

    /// Sorts a file's recipes by whether the library has them.
    ///
    /// `existing` maps ids to what the library holds under them. A recipe in
    /// the trash counts as new: importing it again is how the cook gets it
    /// back, and "you have this already" would send them looking for it.
    public init(batch: RecipeImportBatch, existing: [UUID: Recipe]) {
        let live = existing.filter { !$0.value.isDeleted }
        if batch.recipes.isEmpty {
            self = .nothingReadable(problems: batch.problems)
        } else if batch.recipes.count == 1, let recipe = live[batch.recipes[0].recipe.id] {
            self = .alreadyHere(recipe)
        } else {
            self = .preview(RecipeImportPreview(batch: batch, existing: live))
        }
    }
}

/// The recipes of a file laid out for choosing, before any of them is stored.
public struct RecipeImportPreview: Sendable, Hashable {
    public struct Entry: Identifiable, Sendable, Hashable {
        public var item: ImportedRecipe
        /// What the library holds under the same id, if anything — the
        /// recipe importing this one would replace.
        public var existing: Recipe?

        public var id: UUID { item.recipe.id }
        public var recipe: Recipe { item.recipe }
        public var isNew: Bool { existing == nil }
    }

    /// Alphabetical, like the recipe list the cook will find them in.
    public var entries: [Entry]
    /// Entries of the file that could not be read at all.
    public var problems: [RecipeImportProblem]

    /// `existing` holds the live recipes of the library by id.
    ///
    /// A file naming the same recipe twice keeps the first: the two would be
    /// stored under one id anyway, and a list showing both would offer a
    /// choice that is not one.
    public init(batch: RecipeImportBatch, existing: [UUID: Recipe]) {
        var seen = Set<UUID>()
        entries = batch.recipes
            .filter { seen.insert($0.recipe.id).inserted }
            .map { Entry(item: $0, existing: existing[$0.recipe.id]) }
            .sorted {
                $0.recipe.title.localizedStandardCompare($1.recipe.title) == .orderedAscending
            }
        problems = batch.problems
    }

    /// What is ticked when the preview opens: everything new. A recipe the
    /// cook already has is replaced only when they ask for it — the file is
    /// often older than what they have been editing since.
    public var initialSelection: Set<UUID> {
        Set(entries.filter(\.isNew).map(\.id))
    }

    public var newCount: Int { entries.count { $0.isNew } }

    /// The chosen recipes, ready to store. The file's problems are left out:
    /// the preview has shown them already, and the report afterwards is
    /// about what the import itself did.
    public func batch(selecting ids: Set<UUID>) -> RecipeImportBatch {
        RecipeImportBatch(recipes: entries.filter { ids.contains($0.id) }.map(\.item))
    }
}
