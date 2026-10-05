import Foundation

/// A recipe as it arrived: its ingredients, instructions and notes exactly as
/// imported, kept once and never written again.
///
/// Optimizing a recipe for Sous rewrites its lines — preparation into the
/// steps, alternatives into the notes, noise dropped — and overwrites the
/// recipe. The text it came with stays here, read-only, so "Original" can
/// show it and the cook can always see what the optimization changed.
///
/// History, not a source: nothing derived (nutrition, shopping, the search
/// index, step references) ever reads it.
public struct RecipeOriginal: Codable, Hashable, Sendable {
    public var ingredientsText: String
    public var instructionsText: String
    public var notes: String?
    /// When it was kept — the import, or the first optimization of a recipe
    /// from before originals were kept.
    public var keptAt: Date
    /// What a replacement by a chat model could change besides the text:
    /// kept the first time one happens, so "Original" brings it back too.
    /// `nil` where none has happened.
    public var meta: Meta?
    /// Read only, from before ``history``: the one version a replacement
    /// kept. ``versions`` folds it in; nothing writes it any more.
    public var previous: Version?
    /// The recipe's earlier versions, oldest first, at most
    /// ``historyLimit``: what it read before each change that replaced it —
    /// a chat model's rewrite, an optimization, an edit saved in the editor,
    /// a version restored.
    public var history: [Version]?

    /// How many earlier versions a recipe keeps. Text is small, but the
    /// column syncs with the recipe, and ten is more going back than anybody
    /// does.
    public static let historyLimit = 10

    /// ``history``, or the one ``previous`` an original from before it kept.
    public var versions: [Version] {
        history ?? previous.map { [$0] } ?? []
    }

    /// The fields beside the text a replacement may change.
    public struct Meta: Codable, Hashable, Sendable {
        public var title: String
        public var summary: String?
        public var servings: Int
        public var categories: [String]

        public init(of recipe: Recipe) {
            title = recipe.title
            summary = recipe.summary
            servings = recipe.servings
            categories = recipe.categories
        }
    }

    /// A whole version of a recipe's content.
    public struct Version: Codable, Hashable, Sendable {
        public var meta: Meta
        public var ingredientsText: String
        public var instructionsText: String
        public var notes: String?
        public var stepReferences: StepReferences?
        /// When this version stopped being the recipe. `nil` in a version
        /// kept before the history had dates.
        public var keptAt: Date?
        /// What replaced it: "Vegan machen", "Bearbeitet". `nil` likewise.
        public var replacedBy: String?

        public init(of recipe: Recipe, keptAt: Date? = nil, replacedBy: String? = nil) {
            meta = Meta(of: recipe)
            ingredientsText = recipe.ingredientsText
            instructionsText = recipe.instructionsText
            notes = recipe.notes
            stepReferences = recipe.stepReferences
            self.keptAt = keptAt
            self.replacedBy = replacedBy
        }

        /// Whether `recipe` reads like this: the content, not when or why.
        public func matches(_ recipe: Recipe) -> Bool {
            meta == Meta(of: recipe)
                && ingredientsText == recipe.ingredientsText
                && instructionsText == recipe.instructionsText
                && (notes ?? "") == (recipe.notes ?? "")
        }
    }

    public init(
        ingredientsText: String,
        instructionsText: String,
        notes: String?,
        keptAt: Date = .nowInSyncPrecision,
        meta: Meta? = nil,
        previous: Version? = nil,
        history: [Version]? = nil
    ) {
        self.ingredientsText = ingredientsText
        self.instructionsText = instructionsText
        self.notes = notes
        self.keptAt = keptAt
        self.meta = meta
        self.previous = previous
        self.history = history
    }

    /// `recipe`'s text as it reads now.
    public init(of recipe: Recipe, keptAt: Date = .nowInSyncPrecision) {
        self.init(
            ingredientsText: recipe.ingredientsText,
            instructionsText: recipe.instructionsText,
            notes: recipe.notes,
            keptAt: keptAt
        )
    }

    /// Whether `recipe` reads like the original, title and the other fields
    /// beside the text included where the original kept them.
    func matchesWhole(_ recipe: Recipe) -> Bool {
        matches(recipe) && (meta.map { $0 == Meta(of: recipe) } ?? true)
    }

    /// Whether `recipe` still reads exactly like this — then there is nothing
    /// for "Original" to show apart from what is on screen already.
    public func matches(_ recipe: Recipe) -> Bool {
        ingredientsText == recipe.ingredientsText
            && instructionsText == recipe.instructionsText
            && (notes ?? "") == (recipe.notes ?? "")
    }

    /// The column's JSON, or `nil` for no original.
    static func encode(_ original: RecipeOriginal?) -> String? {
        guard let original, let data = try? SousCoding.encoder.encode(original) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads what ``encode(_:)`` wrote; anything unreadable reads as none.
    static func decode(_ json: String?) -> RecipeOriginal? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? SousCoding.decoder.decode(RecipeOriginal.self, from: data)
    }
}

extension Recipe {
    /// This recipe with its original kept, if it has none yet — the one
    /// place an original is written. An existing one is never replaced.
    public func keepingOriginal(keptAt: Date = .nowInSyncPrecision) -> Recipe {
        guard original == nil else { return self }
        var copy = self
        copy.original = RecipeOriginal(of: self, keptAt: keptAt)
        return copy
    }

    /// This recipe as it replaces `before`, with `before` kept: as the
    /// original where there is none yet (fields beside the text included),
    /// and otherwise at the end of the history — unless it reads like the
    /// last version kept, or like the original, which are there already.
    ///
    /// The history is `before`'s, not this copy's: an editor hands back the
    /// recipe as it was opened, and whatever happened to the stored one
    /// since must not be lost.
    func replacing(_ before: Recipe, because replacedBy: String, at date: Date = .nowInSyncPrecision) -> Recipe {
        var copy = self
        guard var original = before.original else {
            var original = RecipeOriginal(of: before, keptAt: date)
            original.meta = RecipeOriginal.Meta(of: before)
            copy.original = original
            return copy
        }
        if original.meta == nil { original.meta = RecipeOriginal.Meta(of: before) }
        var history = original.versions
        let kept = RecipeOriginal.Version(of: before, keptAt: date, replacedBy: replacedBy)
        let alreadyKept = history.last?.matches(before) ?? (history.isEmpty && original.matchesWhole(before))
        if !alreadyKept {
            history.append(kept)
        }
        original.history = Array(history.suffix(RecipeOriginal.historyLimit))
        original.previous = nil
        copy.original = original
        return copy
    }

    /// Whether `other` says something different from this recipe in what a
    /// version keeps: the text, the title and the fields beside it.
    func differsInContent(from other: Recipe) -> Bool {
        RecipeOriginal.Meta(of: self) != RecipeOriginal.Meta(of: other)
            || ingredientsText != other.ingredientsText
            || instructionsText != other.instructionsText
            || (notes ?? "") != (other.notes ?? "")
    }
}
