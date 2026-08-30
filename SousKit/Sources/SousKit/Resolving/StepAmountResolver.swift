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

/// Where a suggestion's amount came from — shown in the review sheet so the
/// cook knows what they're agreeing to, not just what number it is.
public enum AmountSuggestionOrigin: Sendable, Hashable {
    /// A step names the ingredient with no amount of its own at all — the
    /// long-standing bare-mention chip case.
    case unmentioned
    /// `AmountAIExtractor` found this phrase and resolved it against a pot,
    /// but an AI claim is never trusted into the text on its own — see
    /// `amount-confirmation-vs-guessing-tension`: the phrase it matched,
    /// exactly as written, so the cook can judge it against the sentence.
    case aiExtracted(writtenText: String)
}

/// A proposed amount for an ingredient in a step, not yet written into the
/// text — either a bare mention with no amount of its own, or a value
/// `AmountAIExtractor` found that has not been confirmed by a person yet.
///
/// Never applied on its own: this only proposes. See
/// `StepAmountResolver.Resolution.applying(_:corrections:to:)` for the one
/// place a suggestion is allowed to become real text, and VISION.md,
/// "amounts written into a step name an ingredient", for why a guess never
/// gets written in silently.
public struct AmountSuggestion: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let stepID: UUID
    /// The ingredient's name as written on its line — not the normalized
    /// catalog key used for matching, which reads like nothing a cook
    /// wrote.
    public let ingredientName: String
    public let displayAmount: String
    public let origin: AmountSuggestionOrigin
    /// What identifies this question across edits, so that "no, not in the
    /// text" can be remembered.
    ///
    /// `id` cannot: it is a fresh `UUID` per resolve, so nothing said about
    /// a suggestion survives the next one. `stepID` cannot either — it hashes
    /// the step's *index* along with its line, so inserting a step anywhere
    /// above renames every question below it. This hashes only what the
    /// question is actually about: the sentence, and the ingredient in it.
    /// Reorder the steps and the answer holds; rewrite the sentence and it
    /// is a different question again, which is the point.
    public let declineKey: String
    /// Exactly one of these is set — mirrors the `insertAfter`/`replace`
    /// split `StepAmountResolver` already makes for a mention that writes
    /// itself in directly. A bare mention only ever inserts; an AI claim
    /// inserts or replaces depending on whether it named a written amount.
    fileprivate let insertionPoint: String.Index?
    fileprivate let replaceRange: Range<String.Index>?

    fileprivate init(
        stepID: UUID, stepText: String, ingredientName: String, displayAmount: String,
        origin: AmountSuggestionOrigin,
        insertionPoint: String.Index? = nil, replaceRange: Range<String.Index>? = nil
    ) {
        self.id = UUID()
        self.declineKey = StableID.make(
            namespace: "decline",
            index: 0,
            content: "\(IngredientCatalog.normalize(stepText))|\(IngredientCatalog.normalize(ingredientName))"
        ).uuidString
        self.stepID = stepID
        self.ingredientName = ingredientName
        self.displayAmount = displayAmount
        self.origin = origin
        self.insertionPoint = insertionPoint
        self.replaceRange = replaceRange
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
        fileprivate private(set) var suggestionsByStep: [UUID: [AmountSuggestion]]

        /// Whether the steps between them account for every pot's whole
        /// amount — the recipe's text answers every "how much of it here?"
        /// on its own, and the guessed fallback chips have nothing left to
        /// add. Lines without a quantity ("Salz nach Geschmack") never
        /// form a pot, so they can neither block this state nor be blocked
        /// by it; a recipe with no pots at all is not "fully claimed", it
        /// is unquantified.
        public let isFullyClaimed: Bool

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

        /// The same resolution with the questions already answered "no" left
        /// out — of the count, of the sheet, and of the banner that offers
        /// the sheet.
        ///
        /// Applied here rather than at each of those three, so a suggestion
        /// the cook has settled cannot reappear at one of them because
        /// somebody forgot to ask.
        public func excluding(declined keys: Set<String>) -> Resolution {
            guard !keys.isEmpty else { return self }
            var copy = self
            copy.suggestionsByStep = suggestionsByStep.compactMapValues { list in
                let kept = list.filter { !keys.contains($0.declineKey) }
                return kept.isEmpty ? nil : kept
            }
            return copy
        }

        /// `recipe` with `accepted` written into its step text — the only
        /// place a suggestion is allowed to change what the cook wrote,
        /// and only for the ones they said yes to. `corrections` overrides
        /// an accepted suggestion's `displayAmount` with what the cook
        /// actually typed in the review sheet, for the ones they corrected
        /// rather than took as offered.
        ///
        /// `recipe` must be the same recipe this resolution was computed
        /// from (same step text, same step ids) — the suggestions carry
        /// positions into that exact text.
        public func applying(
            _ accepted: Set<AmountSuggestion.ID>,
            corrections: [AmountSuggestion.ID: String] = [:],
            to recipe: Recipe
        ) -> Recipe {
            guard !accepted.isEmpty else { return recipe }
            var recipe = recipe
            let updatedSteps = recipe.steps.map { step -> RecipeStep in
                let toInsert = suggestions(for: step).filter { accepted.contains($0.id) }
                guard !toInsert.isEmpty else { return step }
                let operations = toInsert.map { suggestion -> Operation in
                    let text = corrections[suggestion.id] ?? suggestion.displayAmount
                    if let range = suggestion.replaceRange {
                        return .replace(range: range, text: text, resolved: true)
                    }
                    return .insertAfter(point: suggestion.insertionPoint!, amount: text)
                }
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

    /// Where a mention came from — decides what happens once it binds to a
    /// pot: a regex mention writes straight into the text (trusted by
    /// construction, VISION.md §113), an AI mention becomes a suggestion
    /// pending confirmation (never trusted on its own, see
    /// `amount-confirmation-vs-guessing-tension`).
    private enum MentionOrigin: Equatable {
        case regex
        case ai
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
                suggestionsByStep: [:],
                isFullyClaimed: false
            )
        }

        let factor = Double(targetServings) / Double(recipe.servings)
        let scaledLines = recipe.scaledIngredients(toServings: targetServings)
        let canonicalNames = lines.map { IngredientCatalog.normalize(catalog.canonicalName(for: $0.name)) }
        let pots = pots(lines: lines, scaledLines: scaledLines, canonicalNames: canonicalNames, catalog: catalog)

        // `additionalMentions` — e.g. from `AmountAIExtractor` — supplements
        // the regex scanner rather than replacing it: both compete for the
        // same pot capacity in the solve below. `origin` only matters once
        // a mention has bound — a regex mention writes straight into the
        // text, an AI one becomes a suggestion pending confirmation, see
        // `amount-confirmation-vs-guessing-tension`.
        var fixedShareMentions: [(stepIndex: Int, mention: AmountMention, origin: MentionOrigin)] = []
        var remainingMentions: [(stepIndex: Int, mention: AmountMention, origin: MentionOrigin)] = []
        for (stepIndex, step) in steps.enumerated() {
            let regexMentions = AmountMentionScanner.mentions(in: step.text)
            let aiMentions = supplementary(additionalMentions[step.id] ?? [], notAlreadyFoundBy: regexMentions)
            let tagged = regexMentions.map { ($0, MentionOrigin.regex) } + aiMentions.map { ($0, MentionOrigin.ai) }
            for (mention, origin) in tagged {
                if case .remaining = mention.kind {
                    remainingMentions.append((stepIndex, mention, origin))
                } else {
                    fixedShareMentions.append((stepIndex, mention, origin))
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
            // "Restliche" takes everything the fixed shares left, so the
            // pot is spoken for — which is exactly what `isFullyClaimed`
            // wants to know below.
            remainingCapacity[potIndex] = 0
        }

        let allMentions = fixedShareMentions + remainingMentions
        var segmentsByStep: [UUID: [StepAmountSegment]] = [:]
        var boundIngredientIDsByStep: [UUID: Set<UUID>] = [:]
        var suggestionsByStep: [UUID: [AmountSuggestion]] = [:]

        for (stepIndex, step) in steps.enumerated() {
            var operations: [Operation] = []
            var boundIDs: Set<UUID> = []
            // Both a bare mention (below) and an AI claim pending
            // confirmation (here) land in the same list — one review sheet,
            // regardless of which case a step turns out to need.
            var stepSuggestions: [AmountSuggestion] = []

            for (offset, entry) in allMentions.enumerated() where entry.stepIndex == stepIndex {
                let mention = entry.mention
                if let potIndex = boundPot[offset], let fraction = boundFraction[offset] {
                    let pot = pots[potIndex]
                    let amount = displayAmount(
                        for: mention.kind, fraction: fraction,
                        scaledQuantity: pot.scaledTotal, formatter: formatter
                    )
                    switch entry.origin {
                    case .regex:
                        if mention.replacesWrittenRange {
                            operations.append(.replace(range: mention.writtenRange, text: amount, resolved: true))
                        } else {
                            // Right after the name as matched, not after
                            // whatever the phrase scan happened to also pick up.
                            let point = matchedNameEnd(
                                in: mention.namePhrase, for: pot, catalog: catalog
                            ) ?? mention.namePhrase.endIndex
                            operations.append(.insertAfter(point: point, amount: amount))
                        }
                    case .ai:
                        // Never written straight into the text — an AI claim
                        // only ever becomes a suggestion, confirmed or
                        // corrected once through the review sheet before it
                        // can render as a resolved amount anywhere. But a
                        // claim whose own written span already sits inside
                        // parentheses — "Rapsöl (3 EL)" — or whose insertion
                        // point already has a parenthetical right after it
                        // is not a new finding: it is either a prior
                        // suggestion already confirmed, or a "Name (Menge)"
                        // amount the person themselves wrote. The model
                        // re-recognizes both just as readily as a genuinely
                        // new one, and without this check every step naming
                        // an already-answered amount would ask again after
                        // every edit that changes the recipe's content hash.
                        if mention.replacesWrittenRange {
                            if !isEnclosedInParens(mention.writtenRange, in: step.text) {
                                let origin = AmountSuggestionOrigin.aiExtracted(writtenText: String(step.text[mention.writtenRange]))
                                stepSuggestions.append(AmountSuggestion(
                                    stepID: step.id, stepText: step.text, ingredientName: lines[pot.lineIndices[0]].name,
                                    displayAmount: amount, origin: origin, replaceRange: mention.writtenRange
                                ))
                            }
                        } else {
                            let point = matchedNameEnd(
                                in: mention.namePhrase, for: pot, catalog: catalog
                            ) ?? mention.namePhrase.endIndex
                            if !isAlreadyAnswered(at: point, in: step.text) {
                                let origin = AmountSuggestionOrigin.aiExtracted(writtenText: String(step.text[mention.writtenRange]))
                                stepSuggestions.append(AmountSuggestion(
                                    stepID: step.id, stepText: step.text, ingredientName: lines[pot.lineIndices[0]].name,
                                    displayAmount: amount, origin: origin, insertionPoint: point
                                ))
                            }
                        }
                    }
                    // Binding a pot binds every line in it — the step's
                    // amount covers the ingredient, however many lines the
                    // list happens to spell it across. True for an AI claim
                    // too, even while it is still unconfirmed: it must not
                    // also turn up as a bare-mention suggestion below, and
                    // the pot's remaining capacity is real either way.
                    for lineIndex in pot.lineIndices { boundIDs.insert(lines[lineIndex].id) }
                } else if case .absolute(let quantity) = mention.kind, entry.origin == .regex {
                    // Unresolved falls back to the old, whole-recipe scale —
                    // still moving with the serving count, just without
                    // knowing which line it came from. Only for a written
                    // number a person can see is being blindly scaled; an
                    // unresolved AI claim has nothing written to fall back
                    // to and is simply dropped.
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
            let negated = negatedRanges(in: step.text)
            for (potIndex, pot) in pots.enumerated() where !boundIDs.contains(lines[pot.lineIndices[0]].id) {
                if let stepGroup = step.group, let potGroup = pot.group, stepGroup != potGroup { continue }
                guard let end = firstBareNameEnd(of: pot.canonicalName, in: step.text, avoiding: negated, catalog: catalog)
                    ?? pot.headCanonicalName.flatMap({ firstBareNameEnd(of: $0, in: step.text, avoiding: negated, catalog: catalog) })
                    ?? pot.groupKey.flatMap({ firstGroupNameEnd(groupKey: $0, in: step.text, avoiding: negated, catalog: catalog) })
                    ?? firstCompoundHeadEnd(claimedBy: potIndex, pots: pots, stepGroup: step.group, in: step.text, avoiding: negated, catalog: catalog)
                else { continue }
                // A parenthetical right after the name is an amount someone
                // already accepted — `AmountMentionScanner` does not read it
                // back as a mention (nothing follows it that looks like a
                // name), so without this check the same suggestion would
                // keep reappearing every time the recipe is resolved again.
                guard !isAlreadyAnswered(at: end, in: step.text) else { continue }
                stepSuggestions.append(AmountSuggestion(
                    stepID: step.id,
                    stepText: step.text,
                    ingredientName: lines[pot.lineIndices[0]].name,
                    displayAmount: formatter.string(for: pot.scaledTotal),
                    origin: .unmentioned,
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
            suggestionsByStep: suggestionsByStep,
            isFullyClaimed: !pots.isEmpty && remainingCapacity.allSatisfy { $0 <= 0.001 }
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
        /// The canonical form of the name's head noun, when the written name
        /// carries more words than a step would repeat — "rote Zwiebel" is
        /// called "Zwiebel" in running text. `nil` for single-word names,
        /// and cleared where another pot owns the head name outright: with
        /// both "rote Zwiebel" and "Zwiebeln" on the list, a bare "Zwiebel"
        /// in a step belongs to the pot that says exactly that.
        var headCanonicalName: String?
        /// The key of the catalog ingredient this pot's name bundles under
        /// — its variant parent, or its own entry. `nil` where the catalog
        /// has never heard of the name, and cleared where two pots share
        /// it: with Kirschtomaten and Strauchtomaten both listed, a bare
        /// "Tomaten" in a step means neither.
        var groupKey: String?
        let group: String?
        let scalesWithServings: Bool
        var totalQuantity: Quantity
        var scaledTotal: Quantity

        /// The one word the compound tier may try step words against as
        /// suffixes — the head noun where there is one, the name itself
        /// where the name is a single word ("Olivenöl"). A multi-word name
        /// without a usable head offers nothing to build a compound on.
        var suffixHost: String? {
            headCanonicalName ?? (canonicalName.contains(" ") ? nil : canonicalName)
        }
    }

    private static func pots(
        lines: [RecipeIngredient],
        scaledLines: [RecipeIngredient],
        canonicalNames: [String],
        catalog: IngredientCatalog
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
                    // From the written name, not the canonical one — the
                    // canonical form is lowercased, and picking the head
                    // out of a postpositive qualifier needs the
                    // capitalization the cook wrote.
                    headCanonicalName: headWord(of: lines[index].name).map {
                        IngredientCatalog.normalize(catalog.canonicalName(for: $0))
                    },
                    groupKey: catalog.groupIngredient(for: canonicalNames[index])?.key,
                    group: lines[index].group,
                    scalesWithServings: lines[index].scalesWithServings,
                    totalQuantity: quantity,
                    scaledTotal: scaled
                ))
            }
        }
        let taken = Set(result.map(\.canonicalName))
        var potsPerGroupKey: [String: Int] = [:]
        for pot in result {
            if let key = pot.groupKey { potsPerGroupKey[key, default: 0] += 1 }
        }
        for index in result.indices {
            if let head = result[index].headCanonicalName, taken.contains(head) {
                result[index].headCanonicalName = nil
            }
            if let key = result[index].groupKey, potsPerGroupKey[key, default: 0] > 1 {
                result[index].groupKey = nil
            }
        }
        return result
    }

    /// The head noun a multi-word name answers to in running text — "rote
    /// Zwiebel" is called "Zwiebel", "Dose Kokosmilch" is called
    /// "Kokosmilch", "Limette, Saft davon" is called "Limette".
    ///
    /// German noun phrases end in their head — except where a list writes
    /// the qualifier after it ("Paprika rot", "Weißwein trocken"), which is
    /// why the last *capitalized* word wins, nouns being the words German
    /// capitalizes. What follows a comma or an opening parenthesis
    /// qualifies rather than names, a spaced slash offers an alternative
    /// (an unspaced one is a plural marker: "Zehe/n Knoblauch"), and a
    /// purpose clause ("Fett für die Form") stops the phrase early.
    /// `nil` where there is no separate head to speak of: single-word
    /// names, and heads too short to stand for anything on their own.
    static func headWord(of name: String) -> String? {
        var base = Substring(name)
        if let cut = base.range(of: " / ") {
            base = base[..<cut.lowerBound]
        }
        if let cut = base.firstIndex(where: { $0 == "," || $0 == "(" }) {
            base = base[..<cut]
        }
        var words = base.split(separator: " ")
        // "für/zum/zur/nach" open a purpose clause; "Type/Typ" opens a
        // grading — "Weizenmehl Type 405" is called "Weizenmehl", not
        // "Type". Both end the part of the name that names.
        let qualifierWords: Set<String> = ["für", "zum", "zur", "nach", "type", "typ"]
        if let cut = words.firstIndex(where: { qualifierWords.contains($0.lowercased()) }) {
            words = Array(words[..<cut])
        }
        guard let head = (words.last(where: { $0.first?.isUppercase == true }) ?? words.last).map(String.init),
              head.count >= 3,
              IngredientCatalog.normalize(head) != IngredientCatalog.normalize(name)
        else { return nil }
        return head
    }

    // MARK: - Matching

    private static func candidatePots(
        for mention: AmountMention,
        stepGroup: String?,
        pots: [Pot],
        catalog: IngredientCatalog
    ) -> [Int] {
        let direct = pots.indices.filter { index in
            if let stepGroup, let potGroup = pots[index].group, stepGroup != potGroup { return false }
            if mention.namePrecedesAmount {
                return matchedNameStart(in: mention.namePhrase, for: pots[index], catalog: catalog) != nil
            }
            return matchedNameEnd(in: mention.namePhrase, for: pots[index], catalog: catalog) != nil
        }
        guard direct.isEmpty else { return direct }
        // The bundle tier: "10 Tomaten" against a list that only says
        // "Kirschtomaten" — the catalog's variant relation, applied where
        // no pot matched by name. `groupKey` is already cleared on pots
        // whose bundle is shared, so a match here is unambiguous.
        let grouped = pots.indices.filter { index in
            if let stepGroup, let potGroup = pots[index].group, stepGroup != potGroup { return false }
            guard let key = pots[index].groupKey else { return false }
            if mention.namePrecedesAmount {
                return groupMatchedNameStart(in: mention.namePhrase, groupKey: key, catalog: catalog) != nil
            }
            return groupMatchedNameEnd(in: mention.namePhrase, groupKey: key, catalog: catalog) != nil
        }
        guard grouped.isEmpty else { return grouped.count == 1 ? grouped : [] }
        // The compound tier: "1 EL Öl" against a list that only says
        // "Olivenöl". Tried only where no pot matched by name, and only
        // through `compoundHeadPot`'s uniqueness guard.
        let words = mention.namePhrase.split(separator: " ")
        guard let word = mention.namePrecedesAmount ? words.last : words.first,
              let potIndex = compoundHeadPot(claiming: word, pots: pots, stepGroup: stepGroup, catalog: catalog)
        else { return [] }
        return [potIndex]
    }

    /// The single pot `word` can only mean as the head of a compound —
    /// "Öl" against a list whose one oil is "Olivenöl" — or `nil`.
    ///
    /// German compounds end in their head noun, so "Olivenöl" *is* an Öl
    /// the way `VariantHeuristic` already reasons for new names — and the
    /// same false friends exist ("Erdnussbutter" ends in "butter" and is
    /// not a kind of butter), which is why this tier only ever answers
    /// within one recipe and only when the answer is unique: no pot that
    /// says exactly this word, no head noun that says it, and exactly one
    /// compound ending in it. Two oils on the list, and a bare "Öl" means
    /// neither.
    private static func compoundHeadPot(
        claiming word: Substring, pots: [Pot], stepGroup: String?, catalog: IngredientCatalog
    ) -> Int? {
        // A unit word is never the noun of a compound. "EL" passes the
        // capitalized-word filter and the two-letter minimum, and "Zwiebel"
        // happens to end in "el" — without this, every "(2 EL)" in a step
        // hands the recipe's one "-el" ingredient a phantom mention.
        guard case .custom = IngredientUnit(symbol: String(word)) else { return nil }
        let canonical = IngredientCatalog.normalize(catalog.canonicalName(for: String(word)))
        guard !pots.contains(where: { $0.canonicalName == canonical || $0.headCanonicalName == canonical })
        else { return nil }
        func matches(_ related: (Substring, String) -> Bool) -> [Int] {
            pots.indices.filter { index in
                if let stepGroup, let potGroup = pots[index].group, stepGroup != potGroup { return false }
                guard let host = pots[index].suffixHost else { return false }
                return related(word, host)
            }
        }
        // The head direction first — "Olivenöl" *is* an Öl, so that claim
        // is safe wherever it is unique, and two heads sharing the word
        // are an ambiguity to stop at, never to sidestep into the weaker
        // stem direction. Only where no host ends in the word at all does
        // the stem get a try.
        let heads = matches { isCompoundHead($0, of: $1, catalog: catalog) }
        guard heads.isEmpty else { return heads.count == 1 ? heads.first : nil }
        let stems = matches { isCompoundStem($0, of: $1, catalog: catalog) }
        return stems.count == 1 ? stems.first : nil
    }

    /// Whether `host` is a compound built on `word`. The leftover must be
    /// a real morpheme, not a plural ending, so "Reis" never claims "Eis".
    /// The word is also tried in its canonical form: the host went through
    /// the catalog and lost its plural there, so a written "Tomaten" must
    /// become "Tomate" again to be seen at the end of "Strauchtomate".
    fileprivate static func isCompoundHead(_ word: some StringProtocol, of host: String, catalog: IngredientCatalog) -> Bool {
        let normalized = IngredientCatalog.normalize(String(word))
        if suffixMatches(normalized, host: host) { return true }
        let canonical = IngredientCatalog.normalize(catalog.canonicalName(for: String(word)))
        return canonical != normalized && suffixMatches(canonical, host: host)
    }

    private static func suffixMatches(_ word: String, host: String) -> Bool {
        word.count >= 2 && host.count - word.count >= 3 && host.hasSuffix(word)
    }

    /// Whether `host` is a compound whose *modifier* is `word` — the step
    /// calling "Bockshornkleesamen" just "Bockshornklee". The reverse of
    /// `isCompoundHead`, and the semantically weaker direction: a
    /// "Zwiebelpulver" is not a Zwiebel, which is exactly the false friend
    /// `VariantHeuristic` refuses to automate. It is admitted here anyway
    /// because the guards around it carry the safety: a word any line
    /// owns outright never reaches this tier, the claim must be unique in
    /// the recipe, and the head direction is always tried first. The
    /// longer minimum keeps trivial stems out entirely.
    fileprivate static func isCompoundStem(_ word: some StringProtocol, of host: String, catalog: IngredientCatalog) -> Bool {
        let normalized = IngredientCatalog.normalize(String(word))
        if stemMatches(normalized, host: host) { return true }
        let canonical = IngredientCatalog.normalize(catalog.canonicalName(for: String(word)))
        return canonical != normalized && stemMatches(canonical, host: host)
    }

    private static func stemMatches(_ word: String, host: String) -> Bool {
        word.count >= 4 && host.count - word.count >= 3 && host.hasPrefix(word)
    }

    /// `matchedNameEnd` against everything a pot answers to: its full
    /// canonical name first, its head noun second — so "die Kokosmilch"
    /// still reaches the pot the list wrote as "Dose Kokosmilch". The full
    /// name always gets the first try: where it matches, the head can only
    /// agree, and where another pot owns the head outright the head was
    /// already cleared at construction.
    private static func matchedNameEnd(in phrase: Substring, for pot: Pot, catalog: IngredientCatalog) -> String.Index? {
        if let end = matchedNameEnd(in: phrase, canonicalTarget: pot.canonicalName, catalog: catalog) { return end }
        if let head = pot.headCanonicalName,
           let end = matchedNameEnd(in: phrase, canonicalTarget: head, catalog: catalog) { return end }
        if let key = pot.groupKey,
           let end = groupMatchedNameEnd(in: phrase, groupKey: key, catalog: catalog) { return end }
        // For a pot already chosen through the compound tier, the resolved
        // amount still belongs right after the word that named it.
        if let host = pot.suffixHost, let word = phrase.split(separator: " ").first,
           isCompoundHead(word, of: host, catalog: catalog) || isCompoundStem(word, of: host, catalog: catalog) {
            return word.endIndex
        }
        return nil
    }

    private static func matchedNameStart(in phrase: Substring, for pot: Pot, catalog: IngredientCatalog) -> String.Index? {
        if let start = matchedNameStart(in: phrase, canonicalTarget: pot.canonicalName, catalog: catalog) { return start }
        if let head = pot.headCanonicalName,
           let start = matchedNameStart(in: phrase, canonicalTarget: head, catalog: catalog) { return start }
        if let key = pot.groupKey,
           let start = groupMatchedNameStart(in: phrase, groupKey: key, catalog: catalog) { return start }
        if let host = pot.suffixHost, let word = phrase.split(separator: " ").last,
           isCompoundHead(word, of: host, catalog: catalog) || isCompoundStem(word, of: host, catalog: catalog) {
            return word.startIndex
        }
        return nil
    }

    /// `matchedNameEnd`'s shape, comparing at the shopping-list level
    /// instead of by name: the phrase names *some member* of the pot's
    /// bundle — "Tomaten" reaching the line that says "Kirschtomaten",
    /// because the catalog files both under one parent. Same word windows,
    /// longest first, same reasons.
    private static func groupMatchedNameEnd(in phrase: Substring, groupKey: String, catalog: IngredientCatalog) -> String.Index? {
        let words = phrase.split(separator: " ")
        guard !words.isEmpty else { return nil }
        for count in stride(from: min(words.count, 4), through: 1, by: -1) {
            let candidateWords = words.prefix(count)
            if catalog.groupIngredient(for: candidateWords.joined(separator: " "))?.key == groupKey {
                return candidateWords.last!.endIndex
            }
        }
        return nil
    }

    private static func groupMatchedNameStart(in phrase: Substring, groupKey: String, catalog: IngredientCatalog) -> String.Index? {
        let words = phrase.split(separator: " ")
        guard !words.isEmpty else { return nil }
        for count in stride(from: min(words.count, 4), through: 1, by: -1) {
            let candidateWords = words.suffix(count)
            if catalog.groupIngredient(for: candidateWords.joined(separator: " "))?.key == groupKey {
                return candidateWords.first!.startIndex
            }
        }
        return nil
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

    /// The mirror image of `matchedNameEnd`, for a `namePhrase` that sits
    /// before the mention instead of after it ("Rapsöl (3 EL)" — the phrase
    /// is "…etwas Rapsöl", the name ends right where the mention starts,
    /// not where the phrase happens to have started scanning). Tries
    /// suffixes longest-first for the same reason `matchedNameEnd` tries
    /// prefixes longest-first: a two-word name must get a chance before it
    /// is cut down to a non-matching single word.
    static func matchedNameStart(in phrase: Substring, canonicalTarget: String, catalog: IngredientCatalog) -> String.Index? {
        let words = phrase.split(separator: " ")
        guard !words.isEmpty else { return nil }
        for count in stride(from: min(words.count, 4), through: 1, by: -1) {
            let candidateWords = words.suffix(count)
            let candidate = candidateWords.joined(separator: " ")
            if IngredientCatalog.normalize(catalog.canonicalName(for: candidate)) == canonicalTarget {
                return candidateWords.first!.startIndex
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

    /// Where a bundle member is first named bare in `text` — the
    /// counterpart of `firstBareNameEnd` for the tier that matches through
    /// the catalog's variant relation instead of by name. Same walk over
    /// every word start, same negation rule.
    private static func firstGroupNameEnd(
        groupKey: String, in text: String, avoiding: [Range<String.Index>], catalog: IngredientCatalog
    ) -> String.Index? {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor].isLetter else {
                cursor = text.index(after: cursor)
                continue
            }
            let wordStart = cursor
            let phrase = AmountMentionScanner.namePhrase(after: cursor, in: text)
            if let end = groupMatchedNameEnd(in: phrase, groupKey: groupKey, catalog: catalog),
               !avoiding.contains(where: { $0.contains(wordStart) }) {
                return end
            }
            while cursor < text.endIndex, text[cursor].isLetter || text[cursor] == "-" {
                cursor = text.index(after: cursor)
            }
        }
        return nil
    }

    /// Where a bare step word first names `pots[potIndex]` as the head of a
    /// compound — the counterpart of `firstBareNameEnd` for the tier where
    /// no pot is named outright. Only capitalized words are tried: the
    /// compound head is a noun, and skipping the lowercase ones keeps a
    /// verb like "braten" from ever being read as the tail of one.
    private static func firstCompoundHeadEnd(
        claimedBy potIndex: Int, pots: [Pot], stepGroup: String?, in text: String,
        avoiding: [Range<String.Index>], catalog: IngredientCatalog
    ) -> String.Index? {
        for match in text.matches(of: /[\p{L}][\p{L}\-]*/) {
            let word = text[match.range]
            guard word.first?.isUppercase == true,
                  !avoiding.contains(where: { $0.contains(match.range.lowerBound) })
            else { continue }
            if compoundHeadPot(claiming: word, pots: pots, stepGroup: stepGroup, catalog: catalog) == potIndex {
                return match.range.upperBound
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
    fileprivate static func isAlreadyAnswered(at index: String.Index, in text: String) -> Bool {
        var cursor = index
        while cursor < text.endIndex, text[cursor] == " " { cursor = text.index(after: cursor) }
        guard cursor < text.endIndex, text[cursor] == "(" else { return false }
        let inside = text[text.index(after: cursor)...].lowercased()
        return !negationTriggerWords.contains { inside.hasPrefix($0) }
    }

    /// Whether `range` sits directly inside a pair of parentheses — "(3 EL)"
    /// — immediately preceded by `(` and immediately followed by `)`.
    ///
    /// An AI claim whose own written span already has this shape is not a
    /// fresh finding: either the person wrote "Name (Menge)" themselves, or
    /// this is exactly the shape a prior confirmation left behind (a
    /// `replace`-shaped `AmountSuggestion` never adds its own parentheses —
    /// it substitutes text in place, keeping whatever punctuation the
    /// written amount already sat inside of). Without this check, the model
    /// — which is specifically good at reading "Name (Menge)" order — would
    /// re-find the same phrase on every enrichment pass and turn it back
    /// into an unconfirmed suggestion, undoing the point of confirming it.
    private static func isEnclosedInParens(_ range: Range<String.Index>, in text: String) -> Bool {
        guard range.lowerBound > text.startIndex, range.upperBound < text.endIndex else { return false }
        let before = text.index(before: range.lowerBound)
        return text[before] == "(" && text[range.upperBound] == ")"
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
    /// A clause ends with the noun it excludes, not at the next comma —
    /// "ohne Fett Pinienkerne anrösten" only excludes the fat, and running
    /// to the comma would swallow the Pinienkerne with it. The excluded
    /// noun is the first capitalized word after the trigger that is not a
    /// unit ("bis auf 2 EL Wasser" must reach past the EL to the Wasser),
    /// and a conjunction right after it hands the clause on to the next
    /// one ("abgesehen vom Olivenöl und paar Pinienkerne" excludes both).
    /// Clauses that never name a noun ("ohne umzurühren") keep the old
    /// punctuation end.
    fileprivate static func negatedRanges(in text: String) -> [Range<String.Index>] {
        let negationTriggers = /(?i)(?:abgesehen vo[nm]|außer|ausgenommen|bis auf|ohne)\s+/
        let enders: Set<Character> = [",", ".", ";", ")", "\n"]
        let conjunctions: Set<String> = ["und", "oder", "sowie"]
        return text.matches(of: negationTriggers).map { match in
            var end = match.range.upperBound
            while end < text.endIndex, !enders.contains(text[end]) {
                end = text.index(after: end)
            }
            let clause = text[match.range.upperBound..<end]

            func isNoun(_ word: Substring) -> Bool {
                guard word.first?.isUppercase == true else { return false }
                guard case .custom = IngredientUnit(symbol: String(word)) else { return false }
                return true
            }

            var nounEnd: String.Index?
            for wordMatch in clause.matches(of: /[\p{L}][\p{L}\-]*/) {
                let word = clause[wordMatch.range]
                if nounEnd == nil {
                    if isNoun(word) { nounEnd = wordMatch.range.upperBound }
                } else if conjunctions.contains(word.lowercased()) {
                    nounEnd = nil
                } else {
                    break
                }
            }
            return match.range.lowerBound..<(nounEnd ?? end)
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
    /// `requiringWordStart` is set for a head-noun search: a full written
    /// name matching mid-word was always unlikely, but a bare head like
    /// "Fett" would otherwise hit inside "einfetten". `requiringWordEnd`
    /// joins it for the shortest names — "Öl" and "Tee" must stand alone,
    /// or they hit inside "Ölivenöl"-style compounds and "Teelöffel".
    fileprivate static func mentionedAsBareName(
        _ name: String, in text: String, negated: [Range<String.Index>],
        requiringWordStart: Bool = false, requiringWordEnd: Bool = false
    ) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: name, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            let startsWord = found.lowerBound == text.startIndex
                || !text[text.index(before: found.lowerBound)].isLetter
            let endsWord = found.upperBound == text.endIndex
                || !text[found.upperBound].isLetter
            if !requiringWordStart || startsWord, !requiringWordEnd || endsWord,
               !negated.contains(where: { $0.overlaps(found) }), !isAlreadyAnswered(at: found.upperBound, in: text) {
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
        switch kind {
        case .absolute(let quantity):
            guard quantity.unit.dimension == pot.totalQuantity.unit.dimension else { return nil }
            // The same unit on both sides needs no shared base to divide
            // through — "1 Zehe" against a pot already totalled in "Zehe"
            // is a plain ratio between two numbers, the same reasoning
            // `Quantity.adding(_:)` already uses to add two lines that
            // share an imprecise unit. Without this, "Zehe", "Blatt",
            // "Bund" and the rest of `UnitDimension.imprecise` could never
            // resolve against a pot at all — `baseUnitFactor` is `nil` for
            // all of them by definition, forward word order or backward.
            if quantity.unit == pot.totalQuantity.unit {
                guard pot.totalQuantity.amount > 0 else { return nil }
                let value = quantity.amount / pot.totalQuantity.amount
                return value <= 1.0001 ? value : nil
            }
            guard let potBase = pot.totalQuantity.inBaseUnit, potBase > 0, let mentionBase = quantity.inBaseUnit else { return nil }
            let value = mentionBase / potBase
            return value <= 1.0001 ? value : nil
        case .bareCount(let value):
            guard pot.totalQuantity.unit.dimension == .count,
                  let potBase = pot.totalQuantity.inBaseUnit, potBase > 0
            else { return nil }
            let value = value / potBase
            return value <= 1.0001 ? value : nil
        case .fraction(let value):
            // No pot-unit dependency at all — "die Hälfte des Knoblauchs"
            // is 0.5 regardless of what the clove pot's total converts to.
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
    public func ingredients(
        mentionedIn step: RecipeStep,
        scaledToServings targetServings: Int? = nil,
        catalog: IngredientCatalog = .bundled
    ) -> [RecipeIngredient] {
        ingredients(
            mentionedIn: step,
            resolution: StepAmountResolver.resolve(self, toServings: targetServings ?? servings, catalog: catalog),
            scaledToServings: targetServings,
            catalog: catalog
        )
    }

    /// Same as ``ingredients(mentionedIn:scaledToServings:)``, against a
    /// `Resolution` computed once for the whole recipe — for a caller
    /// walking every step, which would otherwise resolve the recipe anew
    /// for each one.
    public func ingredients(
        mentionedIn step: RecipeStep,
        resolution: StepAmountResolver.Resolution,
        scaledToServings targetServings: Int? = nil,
        catalog: IngredientCatalog = .bundled
    ) -> [RecipeIngredient] {
        let all = scaledIngredients(toServings: targetServings ?? servings)
        let negated = StepAmountResolver.negatedRanges(in: step.text)
        // The names other lines own outright, so a head noun never stands
        // in where the list also says exactly that: with "rote Zwiebel"
        // and "Zwiebeln" both listed, a bare "Zwiebel" means the latter.
        let ownedKeys = Set(all.map { IngredientCatalog.normalize(catalog.canonicalName(for: $0.name)) })

        // One walk over the step's capitalized words feeds two tiers the
        // substring search cannot serve. The catalog tier: a word whose
        // canonical entry is a line's — "Brühe" is an alias of
        // "Gemüsebrühe", "Zwiebel" the singular of "Zwiebeln" — matches
        // that line the way the resolver's own name matching always has.
        // The compound tier, mirroring `compoundHeadPot` at line level: a
        // word nothing owns outright, ending exactly one line's host word
        // — "Tofu" reaching the line that says "Räuchertofu". Both are
        // collected up front because ownership and uniqueness are
        // questions about all lines at once, not about one at a time.
        let ownersByCanonical = Dictionary(grouping: all) {
            IngredientCatalog.normalize(catalog.canonicalName(for: $0.name))
        }
        let bundles: [(id: UUID, groupKey: String, canonical: String)] = all.compactMap { ingredient in
            guard let group = catalog.groupIngredient(for: ingredient.name) else { return nil }
            return (ingredient.id, group.key, IngredientCatalog.normalize(catalog.canonicalName(for: ingredient.name)))
        }
        let hosts: [(id: UUID, host: String)] = all.compactMap { ingredient in
            let name = ingredient.name.trimmingCharacters(in: .whitespaces)
            if let head = StepAmountResolver.headWord(of: name) {
                return (ingredient.id, IngredientCatalog.normalize(catalog.canonicalName(for: head)))
            }
            guard !name.contains(" ") else { return nil }
            return (ingredient.id, IngredientCatalog.normalize(catalog.canonicalName(for: name)))
        }
        var wordMatched = Set<UUID>()
        for match in step.text.matches(of: /[\p{L}][\p{L}\-]*/) {
            let word = step.text[match.range]
            guard word.first?.isUppercase == true,
                  !negated.contains(where: { $0.contains(match.range.lowerBound) }),
                  !StepAmountResolver.isAlreadyAnswered(at: match.range.upperBound, in: step.text)
            else { continue }
            if let owners = ownersByCanonical[IngredientCatalog.normalize(catalog.canonicalName(for: String(word)))] {
                wordMatched.formUnion(owners.map(\.id))
                continue
            }
            // The bundle tier: the word names the parent (or a sibling) of
            // exactly one listed variant — "Tomaten" reaching the line
            // that says "Kirschtomaten". Two distinct variants of the same
            // bundle, and the word means neither.
            if let wordGroup = catalog.groupIngredient(for: String(word))?.key {
                let members = bundles.filter { $0.groupKey == wordGroup }
                if !members.isEmpty {
                    if Set(members.map(\.canonical)).count == 1 {
                        for member in members { wordMatched.insert(member.id) }
                    }
                    continue
                }
            }
            // Head direction before stem direction, and an ambiguous head
            // never falls through to a stem — same order, same reasons as
            // `compoundHeadPot`.
            var claimants = hosts.filter { StepAmountResolver.isCompoundHead(word, of: $0.host, catalog: catalog) }
            if claimants.isEmpty {
                claimants = hosts.filter { StepAmountResolver.isCompoundStem(word, of: $0.host, catalog: catalog) }
            }
            // Two lines spelling the same host are one supply, not an
            // ambiguity — the pot dedupe below folds them back together.
            if Set(claimants.map(\.host)).count == 1 {
                for claimant in claimants { wordMatched.insert(claimant.id) }
            }
        }

        let matching = all.filter { ingredient in
            guard !resolution.mentionsAmount(of: ingredient, in: step) else { return false }
            let name = ingredient.name.trimmingCharacters(in: .whitespaces)
            guard name.count >= 2 else { return false }
            // The shortest names must stand alone as a word — "Öl" and
            // "Tee" would otherwise hit inside "Kokosöl" and "Teelöffel".
            let standalone = name.count < 4
            if StepAmountResolver.mentionedAsBareName(
                name, in: step.text, negated: negated,
                requiringWordStart: standalone, requiringWordEnd: standalone
            ) { return true }
            if let head = StepAmountResolver.headWord(of: name),
               !ownedKeys.contains(IngredientCatalog.normalize(catalog.canonicalName(for: head))),
               StepAmountResolver.mentionedAsBareName(head, in: step.text, negated: negated, requiringWordStart: true) {
                return true
            }
            return wordMatched.contains(ingredient.id)
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
