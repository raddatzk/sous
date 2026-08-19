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
                boundIngredientIDsByStep: [:]
            )
        }

        let factor = Double(targetServings) / Double(recipe.servings)
        let scaledLines = recipe.scaledIngredients(toServings: targetServings)
        let canonicalNames = lines.map { IngredientCatalog.normalize(catalog.canonicalName(for: $0.name)) }

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

        // Each fixed-share mention's candidate lines, together with the
        // fraction of that line's total it would claim.
        let domains: [[Candidate]] = fixedShareMentions.map { entry in
            candidateLines(
                for: entry.mention, stepGroup: steps[entry.stepIndex].group,
                lines: lines, canonicalNames: canonicalNames, catalog: catalog
            ).compactMap { lineIndex in
                fraction(for: entry.mention.kind, against: lines[lineIndex]).map {
                    Candidate(lineIndex: lineIndex, fraction: $0)
                }
            }
        }

        let assignment = solve(domains: domains, lineCount: lines.count)

        var remainingCapacity = [Double](repeating: 1.0, count: lines.count)
        var boundLine: [Int: Int] = [:]       // index into fixedShareMentions/remainingMentions -> line index
        var boundFraction: [Int: Double] = [:]

        for (order, lineIndex) in assignment {
            guard let candidate = domains[order].first(where: { $0.lineIndex == lineIndex }) else { continue }
            boundLine[order] = lineIndex
            boundFraction[order] = candidate.fraction
            remainingCapacity[lineIndex] -= candidate.fraction
        }

        // "Restliche" only resolves where exactly one line could mean it —
        // splitting a remainder across candidates is not a share anyone
        // wrote down.
        for (index, entry) in remainingMentions.enumerated() {
            let candidates = candidateLines(
                for: entry.mention, stepGroup: steps[entry.stepIndex].group,
                lines: lines, canonicalNames: canonicalNames, catalog: catalog
            )
            guard candidates.count == 1 else { continue }
            let lineIndex = candidates[0]
            let share = remainingCapacity[lineIndex]
            guard share > 0.001 else { continue }
            let offset = fixedShareMentions.count + index
            boundLine[offset] = lineIndex
            boundFraction[offset] = share
        }

        let allMentions = fixedShareMentions + remainingMentions
        var segmentsByStep: [UUID: [StepAmountSegment]] = [:]
        var boundIngredientIDsByStep: [UUID: Set<UUID>] = [:]

        for (stepIndex, step) in steps.enumerated() {
            var operations: [Operation] = []
            var boundIDs: Set<UUID> = []

            for (offset, entry) in allMentions.enumerated() where entry.stepIndex == stepIndex {
                let mention = entry.mention
                if let lineIndex = boundLine[offset], let fraction = boundFraction[offset] {
                    let amount = displayAmount(
                        for: mention.kind, fraction: fraction,
                        scaledQuantity: scaledLines[lineIndex].quantity!, formatter: formatter
                    )
                    if mention.replacesWrittenRange {
                        operations.append(.replace(range: mention.writtenRange, text: amount, resolved: true))
                    } else {
                        // Right after the name as matched, not after
                        // whatever the phrase scan happened to also pick up.
                        let point = matchedNameEnd(
                            in: mention.namePhrase, canonicalTarget: canonicalNames[lineIndex], catalog: catalog
                        ) ?? mention.namePhrase.endIndex
                        operations.append(.insertAfter(point: point, amount: amount))
                    }
                    boundIDs.insert(lines[lineIndex].id)
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
        }

        return Resolution(segmentsByStep: segmentsByStep, boundIngredientIDsByStep: boundIngredientIDsByStep)
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

    // MARK: - Matching

    private static func candidateLines(
        for mention: AmountMention,
        stepGroup: String?,
        lines: [RecipeIngredient],
        canonicalNames: [String],
        catalog: IngredientCatalog
    ) -> [Int] {
        lines.indices.filter { index in
            guard lines[index].quantity != nil else { return false }
            if let stepGroup, let lineGroup = lines[index].group, stepGroup != lineGroup { return false }
            return matchedNameEnd(in: mention.namePhrase, canonicalTarget: canonicalNames[index], catalog: catalog) != nil
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

    /// The fraction of `line`'s total a mention would claim, or `nil` if it
    /// cannot possibly refer to `line` at all — dimensions disagree, or the
    /// mention alone already exceeds what the line has.
    private static func fraction(for kind: AmountMention.Kind, against line: RecipeIngredient) -> Double? {
        guard let lineQuantity = line.quantity, let lineBase = lineQuantity.inBaseUnit, lineBase > 0 else { return nil }
        switch kind {
        case .absolute(let quantity):
            guard quantity.unit.dimension == lineQuantity.unit.dimension, let mentionBase = quantity.inBaseUnit else { return nil }
            let value = mentionBase / lineBase
            return value <= 1.0001 ? value : nil
        case .bareCount(let value):
            guard lineQuantity.unit.dimension == .count else { return nil }
            let value = value / lineBase
            return value <= 1.0001 ? value : nil
        case .fraction(let value):
            return value
        case .remaining:
            return nil  // Resolved separately, from what the others leave behind.
        }
    }

    // MARK: - Assignment

    private struct Candidate {
        let lineIndex: Int
        let fraction: Double
    }

    /// Brute-force backtracking over which line each mention claims, with
    /// the ones that are not part of any bottleneck resolved outright by
    /// having only one candidate to begin with.
    ///
    /// Ambiguity is only worth resolving where it changes the outcome: two
    /// solutions that both leave every mention with the same assignment are
    /// one solution as far as the cook is concerned, so only mentions whose
    /// assignment actually varies across the assignments claiming the most
    /// mentions are left unresolved.
    private static func solve(domains: [[Candidate]], lineCount: Int) -> [Int: Int] {
        let order = domains.indices.sorted { domains[$0].count < domains[$1].count }
        var bestCount = -1
        var bestSolutions: [[Int: Int]] = []
        var current: [Int: Int] = [:]
        var remaining = [Double](repeating: 1.0, count: lineCount)
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
                guard remaining[candidate.lineIndex] + 1e-6 >= candidate.fraction else { continue }
                remaining[candidate.lineIndex] -= candidate.fraction
                current[mentionIndex] = candidate.lineIndex
                backtrack(position + 1)
                current[mentionIndex] = nil
                remaining[candidate.lineIndex] += candidate.fraction
            }
            backtrack(position + 1)  // Leaving this mention unassigned is always an option.
        }

        backtrack(0)

        guard let first = bestSolutions.first else { return [:] }
        var resolved: [Int: Int] = [:]
        for (mentionIndex, lineIndex) in first where bestSolutions.allSatisfy({ $0[mentionIndex] == lineIndex }) {
            resolved[mentionIndex] = lineIndex
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
        return all.filter { ingredient in
            guard !resolution.mentionsAmount(of: ingredient, in: step) else { return false }
            let name = ingredient.name.trimmingCharacters(in: .whitespaces)
            guard name.count >= 3 else { return false }
            return step.text.localizedCaseInsensitiveContains(name)
        }
    }
}
