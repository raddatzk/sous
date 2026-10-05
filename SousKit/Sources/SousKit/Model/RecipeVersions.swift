import Foundation

/// One version of a recipe's content, as the versions page lists it: the
/// current one, an earlier one from the history, or the original.
public struct RecipeVersion: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case current
        /// From ``RecipeOriginal/history``, its index there.
        case earlier(Int)
        case original
    }

    public var kind: Kind
    /// When this version stopped being the recipe; for the original, when
    /// it was kept; `nil` for the current one and where nobody recorded it.
    public var date: Date?
    /// What replaced it: "Vegan machen", "Bearbeitet".
    public var replacedBy: String?

    /// The fields beside the text, where the version kept them: an original
    /// from before replacements has the text only.
    public var title: String?
    public var summary: String?
    public var servings: Int?
    public var categories: [String]?
    public var ingredientsText: String
    public var instructionsText: String
    public var notes: String?
    public var stepReferences: StepReferences?

    public var id: String {
        switch kind {
        case .current: "current"
        case .earlier(let index): "earlier-\(index)"
        case .original: "original"
        }
    }

    init(current recipe: Recipe) {
        kind = .current
        title = recipe.title
        summary = recipe.summary
        servings = recipe.servings
        categories = recipe.categories
        ingredientsText = recipe.ingredientsText
        instructionsText = recipe.instructionsText
        notes = recipe.notes
        stepReferences = recipe.stepReferences
    }

    init(earlier version: RecipeOriginal.Version, index: Int) {
        kind = .earlier(index)
        date = version.keptAt
        replacedBy = version.replacedBy
        title = version.meta.title
        summary = version.meta.summary
        servings = version.meta.servings
        categories = version.meta.categories
        ingredientsText = version.ingredientsText
        instructionsText = version.instructionsText
        notes = version.notes
        stepReferences = version.stepReferences
    }

    init(original: RecipeOriginal) {
        kind = .original
        date = original.keptAt
        title = original.meta?.title
        summary = original.meta?.summary
        servings = original.meta?.servings
        categories = original.meta?.categories
        ingredientsText = original.ingredientsText
        instructionsText = original.instructionsText
        notes = original.notes
    }

    /// The recipe as it reads in this version: the fields the version kept,
    /// the rest as `recipe` has them now. Step references come with the
    /// text they were read against, or not at all.
    public func applied(to recipe: Recipe) -> Recipe {
        var result = recipe
        if let title { result.title = title }
        if title != nil { result.summary = summary }
        if let servings { result.servings = servings }
        if let categories { result.categories = categories }
        result.ingredientsText = ingredientsText
        result.instructionsText = instructionsText
        result.notes = notes
        result.stepReferences = stepReferences
        return result
    }
}

extension Recipe {
    /// Every version there is to look at, newest first: the current one, the
    /// earlier ones from the history, the original. Just the current one
    /// where nothing was ever kept, or where all there is reads like it.
    public var versions: [RecipeVersion] {
        var list = [RecipeVersion(current: self)]
        guard let original else { return list }
        for (index, version) in original.versions.enumerated().reversed() {
            list.append(RecipeVersion(earlier: version, index: index))
        }
        if list.count > 1 || !original.matchesWhole(self) {
            list.append(RecipeVersion(original: original))
        }
        return list
    }
}

/// What changed between two versions, as the versions page shows it: the
/// fields side by side, the ingredient and step lines one by one.
public struct RecipeVersionDifference: Sendable {
    public struct Field: Hashable, Sendable {
        public var name: String
        public var before: String
        public var after: String
    }

    public enum Line: Hashable, Sendable {
        case same(String)
        case added(String)
        case removed(String)
    }

    public var fields: [Field]
    public var ingredients: [Line]
    public var steps: [Line]

    /// Whether the two versions read alike.
    public var isEmpty: Bool {
        fields.isEmpty && !ingredients.contains { if case .same = $0 { false } else { true } }
            && !steps.contains { if case .same = $0 { false } else { true } }
    }

    /// From `before` to `after`. A field one of the two did not keep (an
    /// original's title) is left out rather than shown as removed.
    public init(from before: RecipeVersion, to after: RecipeVersion) {
        var fields: [Field] = []
        func compare(_ name: String, _ old: String?, _ new: String?) {
            guard let old, let new, old != new else { return }
            fields.append(Field(name: name, before: old, after: new))
        }
        compare("Titel", before.title, after.title)
        if before.title != nil, after.title != nil {
            compare("Beschreibung", before.summary ?? "", after.summary ?? "")
        }
        compare("Portionen", before.servings.map(String.init), after.servings.map(String.init))
        compare("Kategorien", before.categories?.joined(separator: ", "), after.categories?.joined(separator: ", "))
        compare("Notizen", before.notes ?? "", after.notes ?? "")
        self.fields = fields
        ingredients = Self.lines(from: before.ingredientsText, to: after.ingredientsText)
        steps = Self.lines(from: before.instructionsText, to: after.instructionsText)
    }

    /// The lines of both texts in reading order, each marked as kept, added
    /// or removed. Blank lines are layout, not content, and are left out.
    static func lines(from old: String, to new: String) -> [Line] {
        func split(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let before = split(old)
        let after = split(new)
        let difference = after.difference(from: before)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Line] = []
        var i = 0
        var j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                result.append(.removed(before[i]))
                i += 1
            } else if j < after.count, inserted.contains(j) {
                result.append(.added(after[j]))
                j += 1
            } else {
                // Neither removed nor inserted: the same line on both sides.
                if j < after.count { result.append(.same(after[j])) }
                i += 1
                j += 1
            }
        }
        return result
    }
}
