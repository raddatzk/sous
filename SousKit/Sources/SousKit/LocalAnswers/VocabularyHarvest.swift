import Foundation

/// What a household's vocabulary taught the app that the catalog could use,
/// written out for a `Data/` pull request (INGREDIENTS-DATA §6, "harvest").
///
/// The in-app curation retires in phase 6b, and what the cook set there —
/// aliases, varieties, own words, BLS rows, values, weights — must not go
/// with it. Nothing here is written back anywhere: the file is a list of
/// proposals for the curator, who decides what is general and what is a
/// household phrasing (which never enters the catalog).
///
/// Left out on purpose, per the migration table: pantry, store and note
/// (household facts, which stay where they are), a BLS code equal to the
/// catalog's, "bewusst ohne" (the catalog's answer stands), and the review
/// statuses.
public enum VocabularyHarvest {
    /// One word's proposals.
    public struct Proposal: Hashable, Sendable {
        /// The catalog id where the data set knows the word; `nil` for a word
        /// only the household has.
        public var catalogID: String?
        public var name: String
        /// Spellings the data set does not have yet.
        public var aliases: [String] = []
        /// The word the household filed this under, by its catalog id where
        /// it has one, otherwise by name.
        public var parent: String?
        /// Written only for a new word, or where it differs from the data
        /// set's.
        public var category: IngredientCategory?
        /// BLS codes per state that differ from the data set's.
        public var codes: [String: String] = [:]
        /// Own values per state, with where they were read.
        public var values: [String: (values: NutritionInfo, source: String?)] = [:]
        /// Unit weights that differ from the data set's.
        public var weights: [String: Double] = [:]

        public var isEmpty: Bool {
            aliases.isEmpty && parent == nil && category == nil && codes.isEmpty
                && values.isEmpty && weights.isEmpty
        }

        public static func == (lhs: Proposal, rhs: Proposal) -> Bool {
            lhs.catalogID == rhs.catalogID && lhs.name == rhs.name && lhs.aliases == rhs.aliases
                && lhs.parent == rhs.parent && lhs.category == rhs.category && lhs.codes == rhs.codes
                && lhs.values.mapValues(\.values) == rhs.values.mapValues(\.values)
                && lhs.values.mapValues(\.source) == rhs.values.mapValues(\.source)
                && lhs.weights == rhs.weights
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(catalogID)
            hasher.combine(name)
        }
    }

    /// The proposals in `entries`, measured against the data set the app
    /// runs on — never the household's merged catalog, which would find
    /// every taught alias already "known".
    public static func proposals(
        from entries: [IngredientVocabularyEntry],
        catalog: IngredientCatalog = .current,
        nutrition: NutritionCatalog = .current
    ) -> [Proposal] {
        entries.compactMap { entry -> Proposal? in
            let known = catalog.ingredient(writtenAs: entry.name)
            var proposal = Proposal(catalogID: known?.catalogID, name: known?.name ?? entry.name)

            let shipped = Set((known.map { [$0.name] + $0.aliases } ?? []).map(IngredientCatalog.normalize))
            var seen = shipped
            if known == nil, entry.isOwnIngredient { seen.insert(IngredientCatalog.normalize(entry.name)) }
            proposal.aliases = entry.aliases.filter { seen.insert(IngredientCatalog.normalize($0)).inserted }

            if let parentName = entry.parentName,
               IngredientCatalog.normalize(parentName) != known?.parentName.map(IngredientCatalog.normalize) {
                proposal.parent = catalog.ingredient(writtenAs: parentName)?.catalogID ?? parentName
            }
            if let category = entry.category, known == nil || category != known?.category {
                proposal.category = category
            }

            let shippedEntry = known.flatMap { nutrition.ownEntry(forCanonicalName: $0.name) }
            for (state, basis) in entry.bases {
                if let values = basis.values {
                    proposal.values[state] = (values, basis.source)
                } else if basis.status == .confirmed, let code = basis.code,
                          shippedEntry?.bases[state]?.code != code {
                    proposal.codes[state] = code
                }
            }
            let shippedWeights = known.flatMap { nutrition.nutrition(forCanonicalName: $0.name)?.unitWeightsGrams } ?? [:]
            for (unit, grams) in entry.unitWeightsGrams where shippedWeights[unit] != grams {
                proposal.weights[unit] = grams
            }
            return proposal.isEmpty ? nil : proposal
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The proposals as YAML in the shape of `Data/ingredients/`, one entry
    /// per word, headed with where they came from. Not compiled as it
    /// stands: each entry is a proposal to fold into its family's file.
    public static func yaml(_ proposals: [Proposal], household: String, date: Date = .now) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        var lines = [
            "# Vorschläge aus dem Vokabular des Haushalts \(quoted(household)), \(day).",
            "# Jeder Eintrag ist ein Vorschlag für Data/ingredients/ — nicht kompiliert.",
            "# `id` steht, wo der Katalog das Wort schon kennt; ohne ist das Wort neu.",
        ]
        if proposals.isEmpty { lines.append("[]") }
        for proposal in proposals {
            lines.append(proposal.catalogID.map { "- id: \(quoted($0))" } ?? "- new: true")
            lines.append("  name: \(quoted(proposal.name))")
            if !proposal.aliases.isEmpty {
                lines.append("  aliases:")
                lines += proposal.aliases.map { "    - \(quoted($0))" }
            }
            if let parent = proposal.parent { lines.append("  parent: \(quoted(parent))") }
            if let category = proposal.category { lines.append("  category: \(category.rawValue)") }
            if !proposal.codes.isEmpty {
                lines.append("  nutrition:")
                lines += proposal.codes.keys.sorted().map { "    \($0): [\(proposal.codes[$0]!)]" }
            }
            if !proposal.values.isEmpty {
                lines.append("  values:")
                for state in proposal.values.keys.sorted() {
                    let (values, source) = proposal.values[state]!
                    lines.append("    \(state):")
                    if let source { lines.append("      source: \(quoted(source))") }
                    lines.append("      kcal: \(number(values.kcal))")
                    lines.append("      fat: \(number(values.fatG))")
                    lines.append("      saturatedFat: \(number(values.saturatedFatG))")
                    lines.append("      carbs: \(number(values.carbsG))")
                    lines.append("      sugar: \(number(values.sugarG))")
                    lines.append("      fiber: \(number(values.fiberG))")
                    lines.append("      protein: \(number(values.proteinG))")
                    lines.append("      salt: \(number(values.sodiumMg * 2.5 / 1000))")
                }
            }
            if !proposal.weights.isEmpty {
                lines.append("  measures:")
                for unit in proposal.weights.keys.sorted() {
                    lines.append("    \(quoted(unit)):")
                    lines.append("      grams: \(number(proposal.weights[unit]!))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Double-quoted, so no spelling can be read as YAML syntax.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
