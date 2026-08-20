import Foundation

/// One piece of a step's text, so a view can render a resolved amount
/// differently from the words around it. SousKit only splits the text;
/// turning `.amount` into an accented run is the view's job.
public enum StepAmountSegment: Hashable, Sendable {
    /// Text with nothing resolved — printed as written.
    case text(String)
    /// An amount tied to an ingredient line, already scaled and formatted.
    case amount(String)
}

/// A bare ingredient mention — a step names it with no share of its own,
/// "die Butter erhitzen" — paired with the amount the resolver would write
/// in if the cook agreed to it.
///
/// Never applied on its own: this only proposes. See
/// `StepAmountResolver.Resolution.applying(_:to:)` for the one place a
/// suggestion is allowed to become real text, and VISION.md, "amounts
/// written into a step name an ingredient", for why a guess never gets
/// written in silently.
public struct AmountSuggestion: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let stepID: UUID
    /// The ingredient's name as written on its line — not the normalized
    /// catalog key used for matching, which reads like nothing a cook
    /// wrote.
    public let ingredientName: String
    public let displayAmount: String
    fileprivate let insertionPoint: String.Index

    fileprivate init(stepID: UUID, ingredientName: String, displayAmount: String, insertionPoint: String.Index) {
        self.id = UUID()
        self.stepID = stepID
        self.ingredientName = ingredientName
        self.displayAmount = displayAmount
        self.insertionPoint = insertionPoint
    }
}

/// Ties the amounts written into a recipe's steps to the ingredient lines
/// they belong to.
///
/// A step reads "300 g Kartoffeln 7 Minuten köcheln lassen" while the
/// ingredient list holds the full amount the dish needs. Nothing in the text
/// says which ingredient line a number belongs to, so this works it out —
/// across the whole recipe at once, because "die restlichen Kartoffeln"
/// only means something once every other step's claim on the same line is
/// known. See VISION.md, "Amounts written into a step name an ingredient",
/// for the full reasoning behind the approach taken here.
public enum StepAmountResolver {
    /// What resolving a recipe found: which amount in which step belongs to
    /// which ingredient line, and the text to show for it.
    public struct Resolution: Sendable {
        fileprivate let segmentsByStep: [UUID: [StepAmountSegment]]
        fileprivate let boundIngredientIDsByStep: [UUID: Set<UUID>]
        /// Which pot each ingredient line fell into — so the fallback list
        /// under a step can collapse lines that share one pot instead of
        /// presenting the same butter twice.
        fileprivate let potIndexByLineID: [UUID: Int]
        fileprivate let suggestionsByStep: [UUID: [AmountSuggestion]]

        /// `step`'s text, split into plain text and resolved amounts.
        public func segments(for step: RecipeStep) -> [StepAmountSegment] {
            segmentsByStep[step.id] ?? [.text(step.text)]
        }

        /// Whether `step` already names `ingredient`'s amount inline —
        /// used to drop it from a separate ingredient list under the step
        /// once its number is already part of the sentence.
        public func mentionsAmount(of ingredient: RecipeIngredient, in step: RecipeStep) -> Bool {
            boundIngredientIDsByStep[step.id]?.contains(ingredient.id) ?? false
        }

        /// Ingredients `step` names without ever giving them a share of
        /// their own — candidates for the review screen to offer, never
        /// written in on their own.
        public func suggestions(for step: RecipeStep) -> [AmountSuggestion] {
            suggestionsByStep[step.id] ?? []
        }

        /// Every suggestion across every step, for a count without
        /// walking each one — the recipe list's "needs review" marker and
        /// the detail view's banner both just want a number.
        public var allSuggestions: [AmountSuggestion] {
            suggestionsByStep.values.flatMap { $0 }
        }

        /// `recipe` with `accepted` written into its step text — the only
        /// place a suggestion is allowed to change what the cook wrote,
        /// and only for the ones they said yes to.
        ///
        /// `recipe` must be the same recipe this resolution was computed
        /// from (same step text, same step ids) — the suggestions carry
        /// positions into that exact text.
        public func applying(_ accepted: Set<AmountSuggestion.ID>, to recipe: Recipe) -> Recipe {
            guard !accepted.isEmpty else { return recipe }
            var recipe = recipe
            let updatedSteps = recipe.steps.map { step -> RecipeStep in
                let toInsert = suggestions(for: step).filter { accepted.contains($0.id) }
                guard !toInsert.isEmpty else { return step }
                let operations = toInsert.map { Operation.insertAfter(point: $0.insertionPoint, amount: $0.displayAmount) }
                var updated = step
                updated.text = buildSegments(text: step.text, operations: operations)
                    .map { segment -> String in
                        switch segment {
                        case .text(let s), .amount(let s): s
                        }
                    }
                    .joined()
                return updated
            }
            recipe.instructionsText = StepParser.text(for: updatedSteps)
            return recipe
        }
    }

    /// Resolves every amount mentioned across `recipe`'s steps against its
    /// ingredient lines, once for the whole recipe.
    public static func resolve(
        _ recipe: Recipe,
        toServings targetServings: Int,
        additionalMentions: [UUID: [AmountMention]] = [:],
        catalog: IngredientCatalog = .bundled,
        formatter: QuantityFormatter = QuantityFormatter()
    ) -> Resolution {
        let steps = recipe.steps
        let lines = recipe.ingredients

        guard recipe.servings > 0, targetServings > 0 else {
            return Resolution(
                segmentsByStep: Dictionary(uniqueKeysWithValues: steps.map { ($0.id, [.text($0.text)]) }),
                boundIngredientIDsByStep: [:],
                potIndexByLineID: [:],
                suggestionsByStep: [:]
            )
        }

        let factor = Double(targetServings) / Double(recipe.servings)
        let scaledLines = recipe.scaledIngredients(toServings: targetServings)
        let canonicalNames = lines.map { IngredientCatalog.normalize(catalog.canonicalName(for: $0.name)) }
        let pots = pots(lines: lines, scaledLines: scaledLines, canonicalNames: canonicalNames)

        // `additionalMentions` — e.g. from `AmountAIExtractor` — supplements
        // the regex scanner rather than replacing it: both just produce
        // `AmountMention`s, and everything from here on treats them alike.
        var fixedShareMentions: [(stepIndex: Int, mention: AmountMention)] = []
        var remainingMentions: [(stepIndex: Int, mention: AmountMention)] = []
        for (stepIndex, step) in steps.enumerated() {
            let regexMentions = AmountMentionScanner.mentions(in: step.text)
            let mentions = regexMentions + supplementary(additionalMentions[step.id] ?? [], notAlreadyFoundBy: regexMentions)
            for mention in mentions {
                if case .remaining = mention.kind {
                    remainingMentions.append((stepIndex, mention))
                } else {
                    fixedShareMentions.append((stepIndex, mention))
                }
            }
        }

        // Each fixed-share mention's candidate pots, together with the
        // fraction of that pot's total it would claim.
        let domains: [[Candidate]] = fixedShareMentions.map { entry in
            candidatePots(
                for: entry.mention, stepGroup: steps[entry.stepIndex].group,
                pots: pots, catalog: catalog
            ).compactMap { potIndex in
                fraction(for: entry.mention.kind, against: pots[potIndex]).map {
                    Candidate(potIndex: potIndex, fraction: $0)
                }
            }
        }

        let assignment = solve(domains: domains, potCount: pots.count)

        var remainingCapacity = [Double](repeating: 1.0, count: pots.count)
        var boundPot: [Int: Int] = [:]        // index into fixedShareMentions/remainingMentions -> pot index
        var boundFraction: [Int: Double] = [:]

        for (order, potIndex) in assignment {
            guard let candidate = domains[order].first(where: { $0.potIndex == potIndex }) else { continue }
            boundPot[order] = potIndex
            boundFraction[order] = candidate.fraction
            remainingCapacity[potIndex] -= candidate.fraction
        }

        // "Restliche" only resolves where exactly one pot could mean it —
        // splitting a remainder across candidates is not a share anyone
        // wrote down.
        for (index, entry) in remainingMentions.enumerated() {
            let candidates = candidatePots(
                for: entry.mention, stepGroup: steps[entry.stepIndex].group,
                pots: pots, catalog: catalog
            )
            guard candidates.count == 1 else { continue }
            let potIndex = candidates[0]
            let share = remainingCapacity[potIndex]
            guard share > 0.001 else { continue }
            let offset = fixedShareMentions.count + index
            boundPot[offset] = potIndex
            boundFraction[offset] = share
        }

        let allMentions = fixedShareMentions + remainingMentions
        var segmentsByStep: [UUID: [StepAmountSegment]] = [:]
        var boundIngredientIDsByStep: [UUID: Set<UUID>] = [:]
        var suggestionsByStep: [UUID: [AmountSuggestion]] = [:]

        for (stepIndex, step) in steps.enumerated() {
            var operations: [Operation] = []
            var boundIDs: Set<UUID> = []

            for (offset, entry) in allMentions.enumerated() where entry.stepIndex == stepIndex {
                let mention = entry.mention
                if let potIndex = boundPot[offset], let fraction = boundFraction[offset] {
                    let pot = pots[potIndex]
                    let amount = displayAmount(
                        for: mention.kind, fraction: fraction,
                        scaledQuantity: pot.scaledTotal, formatter: formatter
                    )
                    if mention.replacesWrittenRange {
                        operations.append(.replace(range: mention.writtenRange, text: amount, resolved: true))
                    } else {
                        // Right after the name as matched, not after
                        // whatever the phrase scan happened to also pick up.
                        let point = matchedNameEnd(
                            in: mention.namePhrase, canonicalTarget: pot.canonicalName, catalog: catalog
                        ) ?? mention.namePhrase.endIndex
                        operations.append(.insertAfter(point: point, amount: amount))
                    }
                    // Binding a pot binds every line in it — the step's
                    // amount covers the ingredient, however many lines the
                    // list happens to spell it across.
                    for lineIndex in pot.lineIndices { boundIDs.insert(lines[lineIndex].id) }
                } else if case .absolute(let quantity) = mention.kind {
                    // Unresolved falls back to the old, whole-recipe scale —
                    // still moving with the serving count, just without
                    // knowing which line it came from.
                    let blind = formatter.string(for: Quantity(quantity.amount * factor, quantity.unit))
                    operations.append(.replace(range: mention.writtenRange, text: blind, resolved: false))
                }
                // `bareCount`, `fraction` and `remaining` are left untouched
                // when they do not resolve: a bare number never scales on
                // its own, and wording that already reads correctly must
                // not gain a number it cannot back up.
            }

            segmentsByStep[step.id] = buildSegments(text: step.text, operations: operations)
            boundIngredientIDsByStep[step.id] = boundIDs

            // Pots this step names but never gave a share of its own —
            // candidates for the review screen, never written in here.
            var stepSuggestions: [AmountSuggestion] = []
            let negated = negatedRanges(in: step.text)
            for pot in pots where !boundIDs.contains(lines[pot.lineIndices[0]].id) {
                if let stepGroup = step.group, let potGroup = pot.group, stepGroup != potGroup { continue }
                guard let end = firstBareNameEnd(of: pot.canonicalName, in: step.text, avoiding: negated, catalog: catalog) else { continue }
                // A parenthetical right after the name is an amount someone
                // already accepted — `AmountMentionScanner` does not read it
                // back as a mention (nothing follows it that looks like a
                // name), so without this check the same suggestion would
                // keep reappearing every time the recipe is resolved again.
                guard !isAlreadyAnswered(at: end, in: step.text) else { continue }
                stepSuggestions.append(AmountSuggestion(
                    stepID: step.id,
                    ingredientName: lines[pot.lineIndices[0]].name,
                    displayAmount: formatter.string(for: pot.scaledTotal),
                    insertionPoint: end
                ))
            }
            suggestionsByStep[step.id] = stepSuggestions
        }

        var potIndexByLineID: [UUID: Int] = [:]
        for (potIndex, pot) in pots.enumerated() {
            for lineIndex in pot.lineIndices { potIndexByLineID[lines[lineIndex].id] = potIndex }
        }

        return Resolution(
            segmentsByStep: segmentsByStep,
            boundIngredientIDsByStep: boundIngredientIDsByStep,
            potIndexByLineID: potIndexByLineID,
            suggestionsByStep: suggestionsByStep
        )
    }

    /// Drops an extra mention (from `additionalMentions`) wherever the
    /// regex scanner already found one naming the same noun over an
    /// overlapping span — the two sources agreeing is not two shares to
    /// claim, just one mention seen twice. What regex could not name at
    /// all — a second noun under one shared "restlichen", say — has no
    /// overlapping regex mention to match here and always survives.
    private static func supplementary(_ extra: [AmountMention], notAlreadyFoundBy regexMentions: [AmountMention]) -> [AmountMention] {
        extra.filter { candidate in
            !regexMentions.contains { regex in
                regex.writtenRange.overlaps(candidate.writtenRange)
                    && regex.namePhrase.lowercased().hasPrefix(candidate.namePhrase.lowercased())
            }
        }
    }

    // MARK: - Pots

    /// What a mention actually claims from: one ingredient's total within one
    /// group, however many list lines it is spelled across.
    ///
    /// Two `150 g Butter` lines with no group heading are one 300-gram supply
    /// as far as any step is concerned — resolving against the raw lines
    /// instead would leave "150 g" torn between two equally good homes and
    /// bind nothing. Lines in different groups never share a pot: their
    /// amounts are kept apart on purpose, and "die restliche Butter" in a
    /// filling step must mean the filling's butter, not the dough's leftovers.
    private struct Pot {
        var lineIndices: [Int]
        let canonicalName: String
        let group: String?
        let scalesWithServings: Bool
        var totalQuantity: Quantity
        var scaledTotal: Quantity
    }

    private static func pots(
        lines: [RecipeIngredient],
        scaledLines: [RecipeIngredient],
        canonicalNames: [String]
    ) -> [Pot] {
        var result: [Pot] = []
        for index in lines.indices {
            guard let quantity = lines[index].quantity, let scaled = scaledLines[index].quantity else { continue }
            let mergeTarget = result.indices.first { potIndex in
                let pot = result[potIndex]
                return pot.group == lines[index].group
                    && pot.canonicalName == canonicalNames[index]
                    // A non-scaling line pooled with a scaling one would make
                    // "a fraction of the pot" mean something different at
                    // every serving count — keep such lines apart.
                    && pot.scalesWithServings == lines[index].scalesWithServings
                    && pot.totalQuantity.adding(quantity) != nil
                    && pot.scaledTotal.adding(scaled) != nil
            }
            if let potIndex = mergeTarget,
               let total = result[potIndex].totalQuantity.adding(quantity),
               let scaledTotal = result[potIndex].scaledTotal.adding(scaled) {
                result[potIndex].lineIndices.append(index)
                result[potIndex].totalQuantity = total
                result[potIndex].scaledTotal = scaledTotal
            } else {
                result.append(Pot(
                    lineIndices: [index],
                    canonicalName: canonicalNames[index],
                    group: lines[index].group,
                    scalesWithServings: lines[index].scalesWithServings,
                    totalQuantity: quantity,
                    scaledTotal: scaled
                ))
            }
        }
        return result
    }

    // MARK: - Matching

    private static func candidatePots(
        for mention: AmountMention,
        stepGroup: String?,
        pots: [Pot],
        catalog: IngredientCatalog
    ) -> [Int] {
        pots.indices.filter { index in
            if let stepGroup, let potGroup = pots[index].group, stepGroup != potGroup { return false }
            return matchedNameEnd(in: mention.namePhrase, canonicalTarget: pots[index].canonicalName, catalog: catalog) != nil
        }
    }

    /// Where `phrase`'s match against `canonicalTarget` ends, or `nil` if it
    /// does not name it at all.
    ///
    /// Tries the phrase's words against the catalog longest-first, so
    /// "Rote Bete" is not cut down to a non-matching "Rote" before the
    /// two-word name gets a chance. The end index is the point that
    /// matters beyond domain membership: "restliche Kartoffeln nur
    /// schälen" only names one ingredient, and a resolved amount belongs
    /// right after it — not after "schälen", which is merely how far the
    /// phrase scan happened to look.
    static func matchedNameEnd(in phrase: Substring, canonicalTarget: String, catalog: IngredientCatalog) -> String.Index? {
        let words = phrase.split(separator: " ")
        guard !words.isEmpty else { return nil }
        for count in stride(from: min(words.count, 4), through: 1, by: -1) {
            let candidateWords = words.prefix(count)
            let candidate = candidateWords.joined(separator: " ")
            if IngredientCatalog.normalize(catalog.canonicalName(for: candidate)) == canonicalTarget {
                return candidateWords.last!.endIndex
            }
        }
        return nil
    }

    /// Where `canonicalTarget` is first named — bare, no number anywhere
    /// near it — in `text`, or `nil` if it never is.
    ///
    /// `matchedNameEnd` above assumes it is already handed the right word
    /// window, because a written amount points at where to start looking.
    /// A bare mention has no such anchor, so this walks every word start in
    /// `text` instead and hands each one to `matchedNameEnd` in turn — the
    /// same trimming logic, just seeded from a whole sentence rather than
    /// from one number's aftermath.
    /// A match starting inside one of `avoiding`'s ranges is skipped, not
    /// returned — see `negatedRanges(in:)`.
    private static func firstBareNameEnd(
        of canonicalTarget: String, in text: String, avoiding: [Range<String.Index>], catalog: IngredientCatalog
    ) -> String.Index? {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor].isLetter else {
                cursor = text.index(after: cursor)
                continue
            }
            let wordStart = cursor
            let phrase = AmountMentionScanner.namePhrase(after: cursor, in: text)
            if let end = matchedNameEnd(in: phrase, canonicalTarget: canonicalTarget, catalog: catalog),
               !avoiding.contains(where: { $0.contains(wordStart) }) {
                return end
            }
            // This word didn't start a match — skip past all of it, not
            // into it, so "utter" inside "Butter" is never tried on its own.
            while cursor < text.endIndex, text[cursor].isLetter || text[cursor] == "-" {
                cursor = text.index(after: cursor)
            }
        }
        return nil
    }

    /// Whether `text` already carries a parenthetical right after `index` —
    /// the same shape `buildSegments` writes a resolved amount in.
    ///
    /// A parenthetical that opens with a negation trigger — "Tomate
    /// (abgesehen vom Öl)" — is an exclusion clause, not an answered
    /// amount, so it does not count. See `negationTriggerWords`.
    private static func isAlreadyAnswered(at index: String.Index, in text: String) -> Bool {
        var cursor = index
        while cursor < text.endIndex, text[cursor] == " " { cursor = text.index(after: cursor) }
        guard cursor < text.endIndex, text[cursor] == "(" else { return false }
        let inside = text[text.index(after: cursor)...].lowercased()
        return !negationTriggerWords.contains { inside.hasPrefix($0) }
    }

    /// Words that turn what follows into an exclusion, not a use — "alles
    /// abgesehen vom Öl" names the oil while saying not to touch it. Kept
    /// in sync with the pattern `negatedRanges(in:)` builds below by hand,
    /// since a `Regex` cannot be derived from this array without throwing.
    private static let negationTriggerWords = ["abgesehen von", "abgesehen vom", "außer", "ausgenommen", "bis auf", "ohne"]

    /// The spans `text` explicitly excludes something in — from a trigger
    /// word like "abgesehen vom" to the end of that clause. A name found
    /// only inside one of these belongs to what the step says NOT to use,
    /// so neither a suggestion nor the fallback chip should claim it.
    ///
    /// fileprivate, not private: `Recipe.ingredients(mentionedIn:)` at the
    /// bottom of this file reads it too, the same way it already reads
    /// `Resolution.potIndexByLineID`.
    ///
    /// The pattern is built fresh each call rather than held in a stored
    /// property: `Regex` is not `Sendable`, so it cannot live in static
    /// state under strict concurrency — the same reason `AmountMentionScanner`
    /// builds its patterns fresh each time.
    fileprivate static func negatedRanges(in text: String) -> [Range<String.Index>] {
        let negationTriggers = /(?i)(?:abgesehen vo[nm]|außer|ausgenommen|bis auf|ohne)\s+/
        let enders: Set<Character> = [",", ".", ";", ")", "\n"]
        return text.matches(of: negationTriggers).map { match in
            var end = match.range.upperBound
            while end < text.endIndex, !enders.contains(text[end]) {
                end = text.index(after: end)
            }
            return match.range.lowerBound..<end
        }
    }

    /// Whether `name` is genuinely a bare mention somewhere in `text` — it
    /// appears outside every one of `negated`'s spans, and that occurrence
    /// is not already followed by a parenthetical amount.
    ///
    /// "Olivenöl (40 ml) hinzufügen" already answers its own question, the
    /// same way `isAlreadyAnswered` keeps the resolver from suggesting a
    /// second amount there — the regex scanner just never learns that,
    /// since it only reads "amount name" order ("40 ml Olivenöl"), not
    /// "name (amount)". Without this check, the fallback chip would repeat
    /// what the sentence already says.
    fileprivate static func mentionedAsBareName(_ name: String, in text: String, negated: [Range<String.Index>]) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: name, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            if !negated.contains(where: { $0.overlaps(found) }), !isAlreadyAnswered(at: found.upperBound, in: text) {
                return true
            }
            searchStart = found.upperBound
        }
        return false
    }

    /// The fraction of `pot`'s total a mention would claim, or `nil` if it
    /// cannot possibly refer to `pot` at all — dimensions disagree, or the
    /// mention alone already exceeds what the pot has.
    private static func fraction(for kind: AmountMention.Kind, against pot: Pot) -> Double? {
        guard let potBase = pot.totalQuantity.inBaseUnit, potBase > 0 else { return nil }
        switch kind {
        case .absolute(let quantity):
            guard quantity.unit.dimension == pot.totalQuantity.unit.dimension, let mentionBase = quantity.inBaseUnit else { return nil }
            let value = mentionBase / potBase
            return value <= 1.0001 ? value : nil
        case .bareCount(let value):
            guard pot.totalQuantity.unit.dimension == .count else { return nil }
            let value = value / potBase
            return value <= 1.0001 ? value : nil
        case .fraction(let value):
            return value
        case .remaining:
            return nil  // Resolved separately, from what the others leave behind.
        }
    }

    // MARK: - Assignment

    private struct Candidate {
        let potIndex: Int
        let fraction: Double
    }

    /// Brute-force backtracking over which pot each mention claims, with
    /// the ones that are not part of any bottleneck resolved outright by
    /// having only one candidate to begin with.
    ///
    /// Ambiguity is only worth resolving where it changes the outcome: two
    /// solutions that both leave every mention with the same assignment are
    /// one solution as far as the cook is concerned, so only mentions whose
    /// assignment actually varies across the assignments claiming the most
    /// mentions are left unresolved.
    private static func solve(domains: [[Candidate]], potCount: Int) -> [Int: Int] {
        let order = domains.indices.sorted { domains[$0].count < domains[$1].count }
        var bestCount = -1
        var bestSolutions: [[Int: Int]] = []
        var current: [Int: Int] = [:]
        var remaining = [Double](repeating: 1.0, count: potCount)
        var explored = 0
        let explorationBudget = 200_000

        func backtrack(_ position: Int) {
            explored += 1
            guard explored < explorationBudget else { return }

            if position == order.count {
                if current.count > bestCount {
                    bestCount = current.count
                    bestSolutions = [current]
                } else if current.count == bestCount {
                    bestSolutions.append(current)
                }
                return
            }
            if bestCount >= 0, current.count + (order.count - position) < bestCount { return }

            let mentionIndex = order[position]
            for candidate in domains[mentionIndex] {
                guard remaining[candidate.potIndex] + 1e-6 >= candidate.fraction else { continue }
                remaining[candidate.potIndex] -= candidate.fraction
                current[mentionIndex] = candidate.potIndex
                backtrack(position + 1)
                current[mentionIndex] = nil
                remaining[candidate.potIndex] += candidate.fraction
            }
            backtrack(position + 1)  // Leaving this mention unassigned is always an option.
        }

        backtrack(0)

        guard let first = bestSolutions.first else { return [:] }
        var resolved: [Int: Int] = [:]
        for (mentionIndex, potIndex) in first where bestSolutions.allSatisfy({ $0[mentionIndex] == potIndex }) {
            resolved[mentionIndex] = potIndex
        }
        return resolved
    }

    // MARK: - Rendering

    private static func displayAmount(
        for kind: AmountMention.Kind,
        fraction: Double,
        scaledQuantity: Quantity,
        formatter: QuantityFormatter
    ) -> String {
        let share = Quantity(fraction * scaledQuantity.amount, scaledQuantity.unit)
        switch kind {
        case .absolute(let quantity):
            let converted = quantity.unit == scaledQuantity.unit ? share : (share.converted(to: quantity.unit) ?? share)
            return formatter.string(for: converted)
        case .bareCount:
            return formatter.string(for: Quantity(share.amount, .piece))
        case .fraction, .remaining:
            return formatter.string(for: share)
        }
    }

    private enum Operation {
        case replace(range: Range<String.Index>, text: String, resolved: Bool)
        case insertAfter(point: String.Index, amount: String)

        var lowerBound: String.Index {
            switch self {
            case .replace(let range, _, _): range.lowerBound
            case .insertAfter(let point, _): point
            }
        }
    }

    private static func buildSegments(text: String, operations: [Operation]) -> [StepAmountSegment] {
        var segments: [StepAmountSegment] = []
        var cursor = text.startIndex

        func flush(to end: String.Index) {
            guard cursor < end else { return }
            segments.append(.text(String(text[cursor..<end])))
            cursor = end
        }

        for operation in operations.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            switch operation {
            case .replace(let range, let text, let resolved):
                flush(to: range.lowerBound)
                segments.append(resolved ? .amount(text) : .text(text))
                cursor = range.upperBound
            case .insertAfter(let point, let amount):
                flush(to: point)
                segments.append(.text(" ("))
                segments.append(.amount(amount))
                segments.append(.text(")"))
                cursor = point
            }
        }
        flush(to: text.endIndex)
        return segments
    }

    /// The primitive `AmountScaler` delegates to for text with no recipe
    /// context at all — every recognized unit scaled blindly, exactly as
    /// before the resolver existed.
    static func blindlyScaled(_ text: String, by factor: Double, formatter: QuantityFormatter) -> String {
        guard factor > 0, factor != 1 else { return text }

        let pattern = /(\d+(?:[.,]\d+)?|[½⅓⅔¼¾])\s*([\p{L}]+\.?)/
        var result = text

        // Replaced back to front so earlier ranges stay valid.
        for match in text.matches(of: pattern).reversed() {
            guard let amount = AmountMentionScanner.amountValue(from: String(match.1)) else { continue }
            let symbol = String(match.2).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let unit = IngredientUnit(symbol: symbol)

            // An unrecognized word is not a unit — it is the thing being counted.
            guard case .custom = unit else {
                let scaled = Quantity(amount * factor, unit)
                result.replaceSubrange(match.range, with: formatter.string(for: scaled))
                continue
            }
        }
        return result
    }
}

extension Recipe {
    /// A step's text with its amounts scaled to `targetServings`.
    ///
    /// Kept for callers that just want a plain string; prefer
    /// ``StepAmountResolver/resolve(_:toServings:catalog:formatter:)`` where
    /// the amounts resolved against an ingredient line should stand out.
    public func scaledStepText(_ step: RecipeStep, toServings targetServings: Int) -> String {
        guard servings > 0, targetServings > 0, targetServings != servings else { return step.text }
        return StepAmountResolver.resolve(self, toServings: targetServings)
            .segments(for: step)
            .map { segment in
                switch segment {
                case .text(let string), .amount(let string): string
                }
            }
            .joined()
    }

    /// The ingredients a step appears to use, for the ones it does not
    /// already name an amount for inline.
    ///
    /// Matched by name appearing in the step's text where nothing resolved
    /// it — a guess rather than a fact, but right often enough to be useful
    /// and wrong in a way that is obvious to the cook, who can see the full
    /// list one swipe away.
    public func ingredients(mentionedIn step: RecipeStep, scaledToServings targetServings: Int? = nil) -> [RecipeIngredient] {
        ingredients(
            mentionedIn: step,
            resolution: StepAmountResolver.resolve(self, toServings: targetServings ?? servings),
            scaledToServings: targetServings
        )
    }

    /// Same as ``ingredients(mentionedIn:scaledToServings:)``, against a
    /// `Resolution` computed once for the whole recipe — for a caller
    /// walking every step, which would otherwise resolve the recipe anew
    /// for each one.
    public func ingredients(
        mentionedIn step: RecipeStep,
        resolution: StepAmountResolver.Resolution,
        scaledToServings targetServings: Int? = nil
    ) -> [RecipeIngredient] {
        let all = scaledIngredients(toServings: targetServings ?? servings)
        let negated = StepAmountResolver.negatedRanges(in: step.text)
        let matching = all.filter { ingredient in
            guard !resolution.mentionsAmount(of: ingredient, in: step) else { return false }
            let name = ingredient.name.trimmingCharacters(in: .whitespaces)
            guard name.count >= 3 else { return false }
            return StepAmountResolver.mentionedAsBareName(name, in: step.text, negated: negated)
        }

        // Lines sharing a pot are one supply, and this list is answering
        // "what does this step need" — two `150 g Butter` entries would read
        // as 300 grams twice, not once. The first line stands for the pot,
        // carrying the summed amount (its `id` stays, so a `ForEach` over
        // this list keeps a stable identity).
        var result: [RecipeIngredient] = []
        var potPosition: [Int: Int] = [:]
        for ingredient in matching {
            guard let potIndex = resolution.potIndexByLineID[ingredient.id] else {
                result.append(ingredient)
                continue
            }
            if let position = potPosition[potIndex] {
                if let total = result[position].quantity, let quantity = ingredient.quantity,
                   let sum = total.adding(quantity) {
                    result[position].quantity = sum
                }
            } else {
                potPosition[potIndex] = result.count
                result.append(ingredient)
            }
        }
        return result
    }
}
