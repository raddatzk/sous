import Foundation

/// How much work a recipe is, read off its own structure.
///
/// The idea is borrowed from static analysis, but not the usual measure.
/// Cyclomatic complexity counts paths, and a recipe is a straight line — it
/// would score 1 for a sandwich and 1 for a cassoulet. What transfers is what
/// *cognitive* complexity does instead: stop counting paths and start
/// counting the things a person has to hold in their head at once.
///
/// For a recipe those are:
///
/// - **Components.** "Für den Teig" and "Für die Füllung" are sub-procedures:
///   each has to be finished and then combined, and each is its own place in
///   the cook's attention.
/// - **Interleaving.** A step that names a duration and is not the last step
///   means something is running while the cook does something else. That is
///   the closest thing a recipe has to concurrency, and it is the difference
///   between a long recipe and a busy one.
/// - **Sub-recipes.** A linked recipe is a call, and its work comes along —
///   at half weight, because a linked naan is more replaceable than a step
///   is: it can be bought, and the recipe still works.
/// - **Sheer size.** Steps, ingredients, and how many of them want preparing
///   before they are used.
///
/// What this deliberately does *not* measure is skill. Croissants are five
/// ingredients, few steps, one component and no interleaving — structurally
/// trivial, and hard. Every signal here is about load, so the number is
/// honest about effort and would be a lie about difficulty. A cook who
/// disagrees says so, and their word wins: see `Recipe.effortOverride`.
public struct RecipeEffort: Hashable, Sendable {
    /// The rungs a reader sees. Thresholds live in ``level(for:)`` and are
    /// the one part of this that wants calibrating against a real library
    /// rather than reasoning.
    public enum Level: String, Codable, Hashable, Sendable, CaseIterable {
        case simple
        case medium
        case involved

        /// What the chip says. Provisional in the same way the thresholds
        /// are: the words are only right if the rungs land where a cook
        /// would put them, and that is a calibration, not a translation.
        public var title: String {
            switch self {
            case .simple: "Einfach"
            case .medium: "Mittel"
            case .involved: "Aufwendig"
            }
        }

        public var symbolName: String {
            switch self {
            case .simple: "gauge.with.dots.needle.0percent"
            case .medium: "gauge.with.dots.needle.50percent"
            case .involved: "gauge.with.dots.needle.100percent"
            }
        }
    }

    /// What drove the number, in the order it was counted. Kept so the app
    /// can say *why* a dish reads as involved, and so a calibration run has
    /// something to look at besides a total.
    public struct Contribution: Hashable, Sendable {
        public let signal: Signal
        public let count: Int
        public let points: Double
    }

    public enum Signal: String, Hashable, Sendable {
        case steps
        case ingredients
        case preparations
        case components
        case interleaving
        case subRecipes
    }

    public let score: Double
    public let level: Level
    public let contributions: [Contribution]
}

extension RecipeEffort {
    /// The weights, in one place so that calibrating means editing a list of
    /// numbers rather than reading the code.
    ///
    /// They are a first cut and they are guesses. The ratios say what was
    /// meant: a second component costs about as much as three extra steps,
    /// because switching between two things is the expensive part; a step
    /// that leaves something running costs more than a step that does not.
    enum Weight {
        static let perStep = 1.0
        static let perIngredient = 0.3
        /// An ingredient that has to be prepared before it is used — diced,
        /// soaked, brought to room temperature — is a small job of its own.
        static let perPreparation = 0.5
        /// Beyond the first: one component is just "the recipe".
        static let perComponent = 3.0
        static let perInterleavedStep = 1.5
        /// Halved on purpose, see the type's note.
        static let subRecipeFactor = 0.5
    }

    /// How deep a chain of linked recipes is followed. The same limit the
    /// shopping list uses, for the same reason: beyond that it is a loop or a
    /// mistake.
    static let maxLinkDepth = 3

    /// Where the rungs sit, set against a library of 166 recipes rather than
    /// reasoned about: they are its thirds, near enough. Thirds because the
    /// rungs exist to be filtered by, and a rung that matches four percent of
    /// a library is a rung nobody can use — which is what the first guess at
    /// these numbers produced.
    ///
    /// They are a property of that library and not of cooking. A collection
    /// leaning harder on baking or on one-pan suppers would want them
    /// elsewhere, and moving them is editing two numbers.
    static func level(for score: Double) -> Level {
        switch score {
        case ..<10: .simple
        case ..<15: .medium
        default: .involved
        }
    }
}

public extension Recipe {
    /// The effort this recipe's structure implies, or `nil` where the recipe
    /// has too little structure to tell.
    ///
    /// `nil` is not "no effort". A recipe imported as one block of prose has
    /// one step, no headings and no durations, and every signal here would
    /// read it as trivial — so it says nothing instead, the way the app says
    /// nothing about nutrition it has not been able to work out. The recipe
    /// is not worse than the others; what is missing is the structure to
    /// judge it by.
    ///
    /// - Parameter resolve: looks up a linked recipe by id. Without it the
    ///   sub-recipes count as one step each, which is what they look like
    ///   from the outside.
    func effort(resolve: (UUID) -> Recipe? = { _ in nil }) -> RecipeEffort? {
        effort(depth: 0, visited: [], resolve: resolve)
    }

    private func effort(
        depth: Int, visited: Set<UUID>, resolve: (UUID) -> Recipe?
    ) -> RecipeEffort? {
        let steps = steps
        let ingredients = ingredients
        let components = ingredientGroups().count
        let hasDurations = steps.contains { $0.durationSeconds != nil }

        // Too thin to judge: one block of prose, no headings, no times.
        guard steps.count > 1 || components > 1 || hasDurations else { return nil }

        // A step that names a duration and is not the last one leaves
        // something running while the cook moves on.
        let interleaved = steps.dropLast().filter { $0.durationSeconds != nil }.count
        let preparations = ingredients.filter {
            $0.preparation?.isEmpty == false
        }.count

        var seen = visited
        seen.insert(id)
        var subScore = 0.0
        var subCount = 0
        if depth < RecipeEffort.maxLinkDepth {
            for linkedID in linkedRecipeIDs where !seen.contains(linkedID) {
                seen.insert(linkedID)
                subCount += 1
                guard let linked = resolve(linkedID),
                      let nested = linked.effort(depth: depth + 1, visited: seen, resolve: resolve)
                else { continue }
                subScore += nested.score * RecipeEffort.Weight.subRecipeFactor
            }
        }

        let contributions: [RecipeEffort.Contribution] = [
            .init(signal: .steps, count: steps.count,
                  points: Double(steps.count) * RecipeEffort.Weight.perStep),
            .init(signal: .ingredients, count: ingredients.count,
                  points: Double(ingredients.count) * RecipeEffort.Weight.perIngredient),
            .init(signal: .preparations, count: preparations,
                  points: Double(preparations) * RecipeEffort.Weight.perPreparation),
            .init(signal: .components, count: components,
                  points: Double(max(0, components - 1)) * RecipeEffort.Weight.perComponent),
            .init(signal: .interleaving, count: interleaved,
                  points: Double(interleaved) * RecipeEffort.Weight.perInterleavedStep),
            .init(signal: .subRecipes, count: subCount, points: subScore),
        ].filter { $0.count > 0 }

        let score = contributions.reduce(0) { $0 + $1.points }
        return RecipeEffort(
            score: score, level: RecipeEffort.level(for: score), contributions: contributions
        )
    }
}
