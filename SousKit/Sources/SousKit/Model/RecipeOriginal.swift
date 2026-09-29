import Foundation

/// A recipe as it arrived: its ingredients, instructions and notes exactly as
/// imported, kept once and never written again.
///
/// Optimizing a recipe for Sous rewrites its lines — preparation into the
/// steps, alternatives into the notes, noise dropped — and overwrites the
/// recipe. The text it came with stays here, read-only, so "Reduziert" can
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

    public init(ingredientsText: String, instructionsText: String, notes: String?, keptAt: Date = .nowInSyncPrecision) {
        self.ingredientsText = ingredientsText
        self.instructionsText = instructionsText
        self.notes = notes
        self.keptAt = keptAt
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

    /// Whether `recipe` still reads exactly like this — then there is nothing
    /// for "Reduziert" to show apart from what is on screen already.
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
}
