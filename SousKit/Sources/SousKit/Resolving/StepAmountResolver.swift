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

/// A span of a step's own text that the resolver made sense of — what the
/// editor underlays so the writer can see what the app read out of the
/// sentence. Display only: nothing is ever written into the text.
///
/// Ranges point into ``RecipeStep/text``, never into the whole instructions
/// text: the step is the unit the resolver reasons about, and whoever draws
/// the marks maps them back into its own buffer.
public struct StepTextMark: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// An amount phrase tied to an ingredient line — the same thing
        /// cook mode prints accented.
        case bound
        /// An amount the scanner read but could not tie to any line. It
        /// still scales with the serving count, just blindly.
        case loose
        /// An ingredient named without an amount after earlier steps have
        /// already taken all of it out — the basil a previous step picked,
        /// the pine nuts it roasted. Neither a new withdrawal nor a
        /// question: marked so the writer can see the name was understood
        /// and no number belongs there, where no mark would read as missed.
        case backReference
    }

    public let kind: Kind
    public let range: Range<String.Index>
    /// The ingredient line this span speaks about, where one is known.
    public let ingredientName: String?

    init(kind: Kind, range: Range<String.Index>, ingredientName: String?) {
        self.kind = kind
        self.range = range
        self.ingredientName = ingredientName
    }

    /// The same mark with any whitespace at either edge left out, or `nil`
    /// where nothing but whitespace was there.
    ///
    /// The scanner's spans are cut where the grammar ends, not where the ink
    /// does — "die Hälfte der Zwiebeln" hands back "Hälfte der ", trailing
    /// space and all. Underlining that space is a smudge, and accenting it
    /// shows nothing.
    func trimmed(in text: String) -> StepTextMark? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        while lower < upper, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
        guard lower < upper else { return nil }
        return StepTextMark(kind: kind, range: lower..<upper, ingredientName: ingredientName)
    }
}

/// One share of an ingredient a step works with, and where it came from —
/// an entry in the resolver's register of withdrawals.
///
/// Most of what a step handles comes straight off the ingredient list and
/// costs its pot what it takes. But a recipe that prepares each ingredient
/// on its own before combining them names the same pine nuts twice: once
/// where they are roasted, once where the roasted ones go into the blender.
/// The second is no new withdrawal — it draws on what the first step
/// already holds, and the pot is not charged again. See VISION.md,
/// "Amounts written into a step name an ingredient".
///
/// Derived on every resolve and never stored, like every share.
struct StepIntake: Sendable, Hashable {
    enum Source: Sendable, Hashable {
        /// Taken off the ingredient list.
        case list
        /// Out of what the steps with these ids had already taken from the
        /// pot, in step order.
        case steps([UUID])
    }

    let source: Source
    /// The ingredient lines of the pot the share belongs to — of every
    /// pot, where one word covered several variants at once.
    let ingredientLineIDs: [UUID]
    /// The share of the pot's whole amount. `nil` for a back-reference
    /// (the step names what earlier steps hold) and for a name that stayed
    /// ambiguous between pots.
    let share: Double?
    /// The amount itself, at the serving count the resolution was made
    /// for — what the chip under the step says. `nil` wherever `share` is.
    let quantity: Quantity?
    /// Whether the amount is written in the sentence and rendered there,
    /// accented, rather than as a chip beneath it.
    let inline: Bool
    /// What to call the chip where it stands for several variant pots at
    /// once — the word as the step wrote it ("Paprika"), not the first
    /// variant's line ("Paprika rot").
    let label: String?

    init(source: Source, ingredientLineIDs: [UUID], share: Double?, quantity: Quantity?, inline: Bool, label: String? = nil) {
        self.source = source
        self.ingredientLineIDs = ingredientLineIDs
        self.share = share
        self.quantity = quantity
        self.inline = inline
        self.label = label
    }

    /// Named after earlier steps emptied the pot: nothing new is taken.
    var isBackReference: Bool {
        if case .steps = source, share == nil { return true }
        return false
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
        fileprivate let settledMarksByStep: [UUID: [StepTextMark]]
        /// What each step works with and where it came from — see
        /// `StepIntake`.
        fileprivate let intakesByStep: [UUID: [StepIntake]]

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

        /// What `step`'s text says that the resolver understood, in ranges
        /// into that text — for an editor to mark up while the recipe is
        /// still being written. Ordered by where they sit in the sentence.
        /// Display only. See VISION.md, "amounts written into a step name
        /// an ingredient".
        public func marks(for step: RecipeStep) -> [StepTextMark] {
            (settledMarksByStep[step.id] ?? [])
                .compactMap { $0.trimmed(in: step.text) }
                .sorted { $0.range.lowerBound < $1.range.lowerBound }
        }

        /// Whether `step` already names `ingredient`'s amount inline —
        /// used to drop it from a separate ingredient list under the step
        /// once its number is already part of the sentence.
        public func mentionsAmount(of ingredient: RecipeIngredient, in step: RecipeStep) -> Bool {
            boundIngredientIDsByStep[step.id]?.contains(ingredient.id) ?? false
        }

        /// What `step` works with, and whether each share came off the
        /// ingredient list or out of an earlier step — in the order the
        /// resolver met them.
        func intakes(for step: RecipeStep) -> [StepIntake] {
            intakesByStep[step.id] ?? []
        }

    }

    /// Resolves every amount mentioned across `recipe`'s steps against its
    /// ingredient lines, once for the whole recipe.
    public static func resolve(
        _ recipe: Recipe,
        toServings targetServings: Int,
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
                settledMarksByStep: [:],
                intakesByStep: [:],
                isFullyClaimed: false
            )
        }

        let factor = Double(targetServings) / Double(recipe.servings)
        let scaledLines = recipe.scaledIngredients(toServings: targetServings)
        let canonicalNames = lines.map { IngredientCatalog.normalize(catalog.canonicalName(for: $0.name)) }
        let pots = pots(lines: lines, scaledLines: scaledLines, canonicalNames: canonicalNames, catalog: catalog)

        struct Entry {
            let stepIndex: Int
            let mention: AmountMention
        }
        var entries: [Entry] = []
        for (stepIndex, step) in steps.enumerated() {
            entries += AmountMentionScanner.mentions(in: step.text).map { Entry(stepIndex: stepIndex, mention: $0) }
        }

        // Which ingredient groups each step's heading speaks for — see
        // `groups(addressedBy:among:)`.
        let potGroups = Set(pots.compactMap(\.group))
        let addressedGroups: [Set<String>?] = steps.map { groups(addressedBy: $0.group, among: potGroups) }

        // The written numbers first, solved for the whole recipe at once: a
        // written amount is a withdrawal wherever it stands, so what they
        // take between them is spoken for before any step is walked.
        let writtenIndices = entries.indices.filter {
            switch entries[$0].mention.kind {
            case .absolute, .bareCount: true
            case .fraction, .remaining: false
            }
        }
        let domains: [[Candidate]] = writtenIndices.map { index in
            let entry = entries[index]
            let step = steps[entry.stepIndex]
            var candidates = candidatePots(for: entry.mention, addressed: addressedGroups[entry.stepIndex], pots: pots, catalog: catalog)
            if candidates.count > 1, case .each(let narrowed) = disambiguate(candidates, around: entry.mention.writtenRange, in: step.text, pots: pots, lines: lines, catalog: catalog) {
                candidates = narrowed
            }
            return candidates.compactMap { potIndex in
                fraction(for: entry.mention.kind, against: pots[potIndex]).map { Candidate(potIndex: potIndex, fraction: $0) }
            }
        }
        let assignment = solve(domains: domains, potCount: pots.count)

        // The register. `balance` is what the list still has of each pot
        // once every written number is accounted for; `held` is what
        // earlier steps have taken out and still hold, which is what a
        // back-reference draws on; `holders` are those steps.
        var balance = [Double](repeating: 1.0, count: pots.count)
        var held = [Double](repeating: 0.0, count: pots.count)
        var holders = [[Int]](repeating: [], count: pots.count)
        var writtenBinding: [Int: (potIndex: Int, share: Double)] = [:]
        for (order, candidate) in assignment {
            writtenBinding[writtenIndices[order]] = (candidate.potIndex, candidate.fraction)
            balance[candidate.potIndex] -= candidate.fraction
        }

        let epsilon = 0.001
        var segmentsByStep: [UUID: [StepAmountSegment]] = [:]
        var boundIngredientIDsByStep: [UUID: Set<UUID>] = [:]
        var settledMarksByStep: [UUID: [StepTextMark]] = [:]
        var intakesByStep: [UUID: [StepIntake]] = [:]

        func holderIDs(of potIndex: Int) -> [UUID] {
            Set(holders[potIndex]).sorted().map { steps[$0].id }
        }
        func lineIDs(of potIndices: [Int]) -> [UUID] {
            potIndices.flatMap { pots[$0].lineIndices.map { lines[$0].id } }
        }

        /// Takes `draw` out of every pot in `potIndices` for the step at
        /// `stepIndex`, from the list where it still has some and from what
        /// earlier steps hold where it does not — the one rule every share
        /// under a step follows. `nil` where the pots cannot give it.
        func withdraw(_ potIndices: [Int], _ draw: Draw, at stepIndex: Int, inline: Bool, label: String? = nil) -> StepIntake? {
            var fromList: [(Int, Double)] = []
            var fromHeld: [(Int, Double)] = []
            for potIndex in potIndices {
                switch draw {
                case .share(let share):
                    // Off the list, a share is of the pot; off what earlier
                    // steps hold, it is a share of that — "die Hälfte der
                    // Butter" after 200 g were melted is half the melted
                    // butter, not half the packet.
                    if balance[potIndex] + epsilon >= share {
                        fromList.append((potIndex, share))
                    } else if held[potIndex] > epsilon {
                        fromHeld.append((potIndex, share * held[potIndex]))
                    } else {
                        return nil
                    }
                case .rest:
                    if balance[potIndex] > epsilon {
                        fromList.append((potIndex, balance[potIndex]))
                    } else if held[potIndex] > epsilon {
                        fromHeld.append((potIndex, held[potIndex]))
                    } else {
                        return nil
                    }
                case .whole:
                    if balance[potIndex] > epsilon {
                        fromList.append((potIndex, balance[potIndex]))
                    } else if held[potIndex] > epsilon {
                        // A back-reference: what earlier steps hold, named
                        // again. Nothing is taken out, nothing is charged.
                        return StepIntake(
                            source: .steps(holderIDs(of: potIndex)), ingredientLineIDs: lineIDs(of: potIndices),
                            share: nil, quantity: nil, inline: false
                        )
                    } else {
                        return nil
                    }
                }
            }
            // One word, one source: a share drawn half from the list and
            // half from an earlier step is not a share anybody wrote down.
            guard fromList.isEmpty || fromHeld.isEmpty else { return nil }
            let taken = fromList.isEmpty ? fromHeld : fromList
            var quantity: Quantity?
            for (potIndex, share) in taken {
                // Rounded past the noise of a share like 1 − 200/300, so
                // 100 g is 100 g and not 100.00000000000001.
                let amount = (share * pots[potIndex].scaledTotal.amount * 1_000_000).rounded() / 1_000_000
                let part = Quantity(amount, pots[potIndex].scaledTotal.unit)
                guard let sum = quantity.map({ $0.adding(part) }) ?? part else { return nil }
                quantity = sum
            }
            for (potIndex, share) in taken {
                if fromList.isEmpty {
                    held[potIndex] -= share
                } else {
                    balance[potIndex] -= share
                    held[potIndex] += share
                    holders[potIndex].append(stepIndex)
                }
            }
            let source: StepIntake.Source = fromList.isEmpty ? .steps(holderIDs(of: taken[0].0)) : .list
            let share = taken.count == 1 ? taken[0].1 : nil
            return StepIntake(source: source, ingredientLineIDs: lineIDs(of: taken.map(\.0)), share: share, quantity: quantity, inline: inline, label: label)
        }

        for (stepIndex, step) in steps.enumerated() {
            var operations: [Operation] = []
            var boundIDs: Set<UUID> = []
            var settledMarks: [StepTextMark] = []
            var intakes: [StepIntake] = []
            var handledPots: Set<Int> = []
            let negated = negatedRanges(in: step.text)
            // The names a written amount or share already took for its own
            // pot. "mit 1 EL Olivenöl" is that pot's oil; another pot of the
            // same name must look for a word of its own.
            var spokenFor: [Range<String.Index>] = []

            for index in entries.indices where entries[index].stepIndex == stepIndex {
                let entry = entries[index]
                let mention = entry.mention
                switch mention.kind {
                case .absolute, .bareCount:
                    if let (potIndex, share) = writtenBinding[index] {
                        let pot = pots[potIndex]
                        spokenFor += nameSpan(of: mention, for: pot, catalog: catalog).map { [$0] } ?? []
                        let amount = displayAmount(for: mention.kind, fraction: share, scaledQuantity: pot.scaledTotal, formatter: formatter)
                        let quantity = Quantity(share * pot.scaledTotal.amount, pot.scaledTotal.unit)
                        handledPots.insert(potIndex)
                        held[potIndex] += share
                        holders[potIndex].append(stepIndex)
                        for lineIndex in pot.lineIndices { boundIDs.insert(lines[lineIndex].id) }
                        intakes.append(StepIntake(source: .list, ingredientLineIDs: lineIDs(of: [potIndex]), share: share, quantity: quantity, inline: true))
                        settledMarks.append(StepTextMark(kind: .bound, range: mention.writtenRange, ingredientName: lines[pot.lineIndices[0]].name))
                        operations.append(.replace(range: mention.writtenRange, text: amount, resolved: true))
                    } else {
                        // A written number that binds nowhere still speaks
                        // for its ingredient: the name beside it is not a
                        // bare mention on top of the number.
                        let candidates = candidatePots(for: mention, addressed: addressedGroups[stepIndex], pots: pots, catalog: catalog)
                        handledPots.formUnion(candidates)
                        if let first = candidates.first {
                            spokenFor += nameSpan(of: mention, for: pots[first], catalog: catalog).map { [$0] } ?? []
                        }
                    }
                    if writtenBinding[index] == nil, case .absolute(let quantity) = mention.kind,
                       scalesBlindly(quantity.unit, writtenRange: mention.writtenRange, in: step.text) {
                        // Unresolved falls back to the old, whole-recipe
                        // scale — still moving with the serving count, just
                        // without knowing which line it came from.
                        let blind = formatter.string(for: Quantity(quantity.amount * factor, quantity.unit))
                        operations.append(.replace(range: mention.writtenRange, text: blind, resolved: false))
                        settledMarks.append(StepTextMark(kind: .loose, range: mention.writtenRange, ingredientName: nil))
                    }
                    // A bare count that binds to nothing never scales on
                    // its own: "in 2 Hälften schneiden" stays two halves.

                case .fraction, .remaining:
                    // Relative wording is resolved in step order, against
                    // what the pot has left by then — "die restlichen
                    // Kartoffeln" only means something once every earlier
                    // step's claim is known. Never rewritten: the words
                    // already read correctly at every serving count, so
                    // the amount goes on the chip beneath, not into the
                    // sentence.
                    var candidates = candidatePots(for: mention, addressed: addressedGroups[stepIndex], pots: pots, catalog: catalog)
                    if candidates.count > 1 {
                        switch disambiguate(candidates, around: mention.writtenRange, in: step.text, pots: pots, lines: lines, catalog: catalog) {
                        case .each(let narrowed) where narrowed.count == 1: candidates = narrowed
                        case .sum(let variants): candidates = variants
                        case .each, .ambiguous: candidates = []
                        }
                    }
                    guard !candidates.isEmpty else { continue }
                    let draw: Draw
                    if case .fraction(let share) = mention.kind {
                        draw = .share(share)
                    } else {
                        draw = .rest
                    }
                    guard let intake = withdraw(candidates, draw, at: stepIndex, inline: false), !intake.isBackReference else { continue }
                    handledPots.formUnion(candidates)
                    spokenFor += nameSpan(of: mention, for: pots[candidates[0]], catalog: catalog).map { [$0] } ?? []
                    let name = lines[pots[candidates[0]].lineIndices[0]].name
                    settledMarks.append(StepTextMark(kind: .bound, range: mention.writtenRange, ingredientName: name))
                    intakes.append(intake)
                }
            }

            segmentsByStep[step.id] = buildSegments(text: step.text, operations: operations)

            // Pots this step names without giving them a share of their
            // own. The first such mention takes what the list has left; a
            // later one, after earlier steps emptied the pot, is a
            // back-reference. Pots one word covers together are decided
            // together — see `disambiguate`.
            //
            // A pot the word was not given to keeps looking further along
            // the step: "Kalte Butter zugeben und den Teig verkneten. Butter
            // in den warmen Milchreis rühren." names the dough's butter
            // first and the filling's second. Such a later mention carries
            // the pots it was first weighed against, and claims only what
            // its own sentence points to — otherwise it is the same butter
            // named again.
            struct BareName {
                let potIndex: Int
                let range: Range<String.Index>
                let rivals: Set<Int>
            }
            func nextBareName(of potIndex: Int, after index: String.Index) -> Range<String.Index>? {
                let pot = pots[potIndex]
                let avoiding = negated + spokenFor + [step.text.startIndex..<index]
                return firstBareName(of: pot.canonicalName, in: step.text, avoiding: avoiding, catalog: catalog)
                    ?? pot.headCanonicalName.flatMap({ firstBareName(of: $0, in: step.text, avoiding: avoiding, catalog: catalog) })
                    ?? pot.groupKey.flatMap({ firstGroupName(groupKey: $0, in: step.text, avoiding: avoiding, catalog: catalog) })
                    ?? firstCompoundHead(claimedBy: potIndex, pots: pots, addressed: addressedGroups[stepIndex], in: step.text, avoiding: avoiding, catalog: catalog)
            }
            var bareByStart: [String.Index: [BareName]] = [:]
            // Words nothing told apart, held back until the rest of the step
            // has been read: a later sentence may still settle them.
            var undecided: [(potIndices: [Int], word: String)] = []
            func lookFurther(_ potIndices: some Sequence<Int>, after index: String.Index, rivals: Set<Int>) {
                for potIndex in potIndices where !handledPots.contains(potIndex) {
                    guard let range = nextBareName(of: potIndex, after: index) else { continue }
                    bareByStart[range.lowerBound, default: []].append(BareName(potIndex: potIndex, range: range, rivals: rivals))
                }
            }
            for (potIndex, pot) in pots.enumerated() where !handledPots.contains(potIndex) {
                if let addressed = addressedGroups[stepIndex], let potGroup = pot.group, !addressed.contains(potGroup) { continue }
                guard let nameRange = nextBareName(of: potIndex, after: step.text.startIndex) else { continue }
                bareByStart[nameRange.lowerBound, default: []].append(BareName(potIndex: potIndex, range: nameRange, rivals: []))
            }
            while let start = bareByStart.keys.min() {
                let group = bareByStart.removeValue(forKey: start)!.filter { !handledPots.contains($0.potIndex) }
                guard !group.isEmpty else { continue }
                let range = group[0].range
                let word = String(step.text[range])
                let potIndices = group.map(\.potIndex)
                let rivals = group.reduce(into: Set<Int>()) { $0.formUnion($1.rivals) }
                var each: [[Int]] = potIndices.map { [$0] }
                var label: String?

                if !rivals.isEmpty {
                    let candidates = rivals.union(potIndices).sorted()
                    guard case .each(let chosen) = disambiguate(
                        candidates, in: sentence(around: range, in: step.text), pots: pots, lines: lines, catalog: catalog
                    ) else {
                        lookFurther(potIndices, after: range.upperBound, rivals: rivals)
                        continue
                    }
                    each = potIndices.filter { chosen.contains($0) }.map { [$0] }
                    lookFurther(potIndices.filter { !chosen.contains($0) }, after: range.upperBound, rivals: rivals)
                } else if group.count > 1 {
                    switch disambiguate(group.map(\.potIndex), around: range, in: step.text, pots: pots, lines: lines, catalog: catalog) {
                    case .each(let chosen):
                        each = chosen.map { [$0] }
                        lookFurther(potIndices.filter { !chosen.contains($0) }, after: range.upperBound, rivals: Set(potIndices))
                    case .sum(let variants):
                        each = [variants]
                        label = word
                    case .ambiguous:
                        undecided.append((potIndices, word))
                        lookFurther(potIndices, after: range.upperBound, rivals: Set(potIndices))
                        continue
                    }
                }
                for potIndices in each {
                    guard let intake = withdraw(potIndices, .whole, at: stepIndex, inline: false, label: label) else { continue }
                    handledPots.formUnion(potIndices)
                    let name = lines[pots[potIndices[0]].lineIndices[0]].name
                    settledMarks.append(StepTextMark(
                        kind: intake.isBackReference ? .backReference : .bound, range: range, ingredientName: name
                    ))
                    intakes.append(intake)
                }
            }
            for (potIndices, word) in undecided where potIndices.allSatisfy({ !handledPots.contains($0) }) {
                // Left as a name without an amount: the pots are not
                // charged, the cook sees what was named and nothing the
                // text cannot back up.
                intakes.append(StepIntake(
                    source: .list, ingredientLineIDs: lineIDs(of: potIndices),
                    share: nil, quantity: nil, inline: false, label: word
                ))
            }

            boundIngredientIDsByStep[step.id] = boundIDs
            settledMarksByStep[step.id] = settledMarks
            intakesByStep[step.id] = intakes
        }

        var potIndexByLineID: [UUID: Int] = [:]
        for (potIndex, pot) in pots.enumerated() {
            for lineIndex in pot.lineIndices { potIndexByLineID[lines[lineIndex].id] = potIndex }
        }

        return Resolution(
            segmentsByStep: segmentsByStep,
            boundIngredientIDsByStep: boundIngredientIDsByStep,
            potIndexByLineID: potIndexByLineID,
            settledMarksByStep: settledMarksByStep,
            intakesByStep: intakesByStep,
            isFullyClaimed: !pots.isEmpty && balance.allSatisfy { $0 <= epsilon }
        )
    }

    /// What a step takes of a pot.
    private enum Draw {
        /// A bare mention: all the list has left — or, once earlier steps
        /// have taken it all, a back-reference to what they hold.
        case whole
        /// "Restliche": all the list has left, or all earlier steps hold.
        case rest
        /// "Die Hälfte": a fixed share.
        case share(Double)
    }

    // MARK: - Which pot a name means

    /// What to do with a word that fits several pots at once.
    private enum Disambiguation {
        /// These pots, each on its own — the step names each of them
        /// ("weißen Spargel … grünen Spargel"), or the sentence settled on
        /// one.
        case each([Int])
        /// One name over every variant the list has, added up — "Paprika"
        /// for the red, the yellow and the green one.
        case sum([Int])
        /// Nothing in the sentence tells them apart.
        case ambiguous
    }

    /// Where the name a mention was matched to stands in the step — the
    /// words of `namePhrase` that name `pot`.
    private static func nameSpan(of mention: AmountMention, for pot: Pot, catalog: IngredientCatalog) -> Range<String.Index>? {
        let phrase = mention.namePhrase
        if mention.namePrecedesAmount {
            return matchedNameStart(in: phrase, for: pot, catalog: catalog).map { $0..<phrase.endIndex }
        }
        return matchedNameEnd(in: phrase, for: pot, catalog: catalog).map { phrase.startIndex..<$0 }
    }

    /// `disambiguate` for a word at `range`: its own sentence first, the
    /// whole step only where the sentence settles nothing. "Butter in den
    /// Milchreis rühren. Mehl und Butter verkneten." is two butters, and
    /// read as one text the dough's cue would decide both.
    private static func disambiguate(
        _ candidates: [Int], around range: Range<String.Index>, in text: String,
        pots: [Pot], lines: [RecipeIngredient], catalog: IngredientCatalog
    ) -> Disambiguation {
        let own = sentence(around: range, in: text)
        if own.count < text.count, case .each(let chosen) = disambiguate(candidates, in: own, pots: pots, lines: lines, catalog: catalog) {
            return .each(chosen)
        }
        return disambiguate(candidates, in: text, pots: pots, lines: lines, catalog: catalog)
    }

    /// Words a step abbreviates with a full stop that does not end the
    /// sentence: "ca. 20 cm", "z. B. Butter".
    private static let abbreviations: Set<String> = [
        "ca", "bzw", "evtl", "ggf", "ggfs", "z", "b", "u", "a", "usw", "etc", "min", "max", "std", "gr", "vgl", "inkl", "mind", "tl", "el",
    ]

    /// The sentence of `text` that `range` stands in: bounded by a line
    /// break, or by ".", "!", "?" or ";" followed by a space — a full stop
    /// after an abbreviation or inside a number does not count.
    static func sentence(around range: Range<String.Index>, in text: String) -> String {
        func endsSentence(at index: String.Index) -> Bool {
            let character = text[index]
            if character == "\n" { return true }
            guard "!?;.".contains(character) else { return false }
            let next = text.index(after: index)
            guard next == text.endIndex || text[next].isWhitespace else { return false }
            guard character == "." else { return true }
            var wordStart = index
            while wordStart > text.startIndex, text[text.index(before: wordStart)].isLetter {
                wordStart = text.index(before: wordStart)
            }
            return !abbreviations.contains(text[wordStart..<index].lowercased())
        }
        var lower = range.lowerBound
        while lower > text.startIndex, !endsSentence(at: text.index(before: lower)) {
            lower = text.index(before: lower)
        }
        var upper = range.upperBound
        while upper < text.endIndex, !endsSentence(at: upper) {
            upper = text.index(after: upper)
        }
        if upper < text.endIndex { upper = text.index(after: upper) }
        return String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tells `candidates` — pots one word fits — apart by what else the
    /// sentence says, for the recipes that write no step headings. The
    /// tiers, in order: the line's own qualifier is in the sentence
    /// ("stückigen Tomaten"), the group's name is ("für die Streusel …"),
    /// ingredients only one candidate's group lists are named alongside,
    /// or the candidates are variants of one thing in one group and add up.
    private static func disambiguate(
        _ candidates: [Int], in text: String, pots: [Pot], lines: [RecipeIngredient], catalog: IngredientCatalog
    ) -> Disambiguation {
        guard candidates.count > 1 else { return .each(candidates) }
        let words = text.matches(of: /[\p{L}][\p{L}\-]*/).map { text[$0.range].lowercased() }

        // Only a qualifier some other candidate lacks tells them apart:
        // "fettarme Kokosmilch" in the dough and in the filling both answer
        // to "Fettarme Kokosmilch", which says nothing about which one.
        let stemsByCandidate = candidates.map { Set(qualifierStems(of: lines[pots[$0].lineIndices[0]].name)) }
        let sharedStems = stemsByCandidate.dropFirst().reduce(stemsByCandidate[0]) { $0.intersection($1) }
        let byQualifier = zip(candidates, stemsByCandidate).filter { _, stems in
            stems.subtracting(sharedStems).contains { stem in
                words.contains { $0.hasPrefix(stem) && $0.count <= stem.count + 3 }
            }
        }.map(\.0)
        if !byQualifier.isEmpty { return .each(byQualifier) }

        let byGroup = candidates.filter { potIndex in
            guard let group = pots[potIndex].group else { return false }
            return groupCueWords(of: group).contains { cue in words.contains { $0 == cue || $0.hasSuffix(cue) } }
        }
        if Set(byGroup.map { pots[$0].group }).count == 1 { return .each(byGroup) }

        // Company: an ingredient named in the same sentence that only one
        // candidate's group lists.
        var company: [Int: Int] = [:]
        for potIndex in candidates {
            let group = pots[potIndex].group
            let otherGroups = candidates.filter { $0 != potIndex }.map { pots[$0].group }
            for (otherIndex, other) in pots.enumerated()
            where otherIndex != potIndex && other.group == group && !candidates.contains(otherIndex) {
                let sharedElsewhere = pots.contains { $0.canonicalName == other.canonicalName && otherGroups.contains($0.group) }
                // Named the way a step names it — "Kokosraspeln" for
                // "getrocknete Kokosraspeln" — not only by the full name.
                let named = firstBareName(of: other.canonicalName, in: text, avoiding: [], catalog: catalog)
                    ?? other.headCanonicalName.flatMap { firstBareName(of: $0, in: text, avoiding: [], catalog: catalog) }
                    ?? other.groupKey.flatMap { firstGroupName(groupKey: $0, in: text, avoiding: [], catalog: catalog) }
                guard !sharedElsewhere, named != nil else { continue }
                company[potIndex, default: 0] += 1
            }
        }
        let accompanied = company.filter { $0.value > 0 }
        if accompanied.count == 1, let potIndex = accompanied.keys.first { return .each([potIndex]) }

        let groups = Set(candidates.map { pots[$0].group })
        let heads = Set(candidates.map { pots[$0].headCanonicalName })
        if groups.count == 1, heads.count == 1, heads.first! != nil {
            var total: Quantity? = nil
            for potIndex in candidates {
                guard let sum = total.map({ $0.adding(pots[potIndex].scaledTotal) }) ?? pots[potIndex].scaledTotal else { return .ambiguous }
                total = sum
            }
            return .sum(candidates)
        }
        return .ambiguous
    }

    private static let cueStopWords: Set<String> = [
        "für", "die", "der", "den", "das", "dem", "des", "zum", "zur", "mit", "und", "oder", "extra", "etwas",
        "ca", "nach", "bedarf", "geschmack", "belieben", "zutaten", "portionen", "portion", "alternativ", "oder",
    ]

    /// The words of a line's name that are not its head noun, cut down to
    /// a stem the sentence's inflected form starts with: "weißer Spargel"
    /// → "weiß", "stückige Tomaten" → "stückig", "Rote-Bete-Saft für die
    /// Masse" → "mass".
    private static func qualifierStems(of name: String) -> [String] {
        let head = headWord(of: name).map { IngredientCatalog.normalize($0) }
        var stems: [String] = []
        for raw in name.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "(" || $0 == ")" || $0 == "/" }) {
            let word = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
            guard word.count >= 3, !cueStopWords.contains(word), IngredientCatalog.normalize(word) != head,
                  IngredientCatalog.normalize(word) != IngredientCatalog.normalize(name),
                  case .custom = IngredientUnit(symbol: word), Double(word) == nil
            else { continue }
            var stem = word
            for ending in ["en", "er", "es", "em", "e", "s"] where stem.hasSuffix(ending) && stem.count - ending.count >= 3 {
                stem = String(stem.dropLast(ending.count))
                break
            }
            stems.append(stem)
        }
        return stems
    }

    /// The ingredient groups a step heading speaks for, or `nil` where it
    /// speaks for none of them and so restricts nothing. Headings match
    /// literally first; otherwise by a shared cue word, so "Tofu-Feta
    /// zubereiten" reaches "Für den Tofu-Feta". A heading like "Lauch
    /// braten" or "Panieren und braten" names a phase, not a group — read
    /// as a group it would hide every ingredient from the step.
    private static func groups(addressedBy stepGroup: String?, among potGroups: Set<String>) -> Set<String>? {
        guard let stepGroup, !potGroups.isEmpty else { return nil }
        if potGroups.contains(stepGroup) { return [stepGroup] }
        let cues = Set(groupCueWords(of: stepGroup))
        guard !cues.isEmpty else { return nil }
        let matched = potGroups.filter { group in
            let groupCues = groupCueWords(of: group)
            return groupCues.contains { cue in cues.contains { $0 == cue || $0.hasSuffix(cue) || cue.hasSuffix($0) } }
        }
        return matched.isEmpty ? nil : matched
    }

    /// The words a group heading is known by in running text: "Für den
    /// Teig" → "teig", "Tahini Dip" → "tahini", "Kokosmilchsoße:" →
    /// "kokosmilchsoße".
    private static func groupCueWords(of group: String) -> [String] {
        group.split(whereSeparator: { !$0.isLetter })
            .map { $0.lowercased() }
            .filter { $0.count >= 4 && !cueStopWords.contains($0) }
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
        addressed: Set<String>?,
        pots: [Pot],
        catalog: IngredientCatalog
    ) -> [Int] {
        let direct = pots.indices.filter { index in
            if let addressed, let potGroup = pots[index].group, !addressed.contains(potGroup) { return false }
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
            if let addressed, let potGroup = pots[index].group, !addressed.contains(potGroup) { return false }
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
              let potIndex = compoundHeadPot(claiming: word, pots: pots, addressed: addressed, catalog: catalog)
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
        claiming word: Substring, pots: [Pot], addressed: Set<String>?, catalog: IngredientCatalog
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
                if let addressed, let potGroup = pots[index].group, !addressed.contains(potGroup) { return false }
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
        guard word.count >= 4, host.count - word.count >= 3, host.hasPrefix(word) else { return false }
        // The stem direction's false friend is a *derivative*: Chilipulver
        // is not a Chili, Tomatenmark not a Tomate, Gemüsebrühe not the
        // Gemüse. A host whose remainder names such a product is refused
        // here rather than left to the uniqueness guard, which cannot help
        // when the real thing is not on the list at all.
        var remainder = host.dropFirst(word.count)
        for linking in ["en", "n", "s", "es", "e"] where remainder.hasPrefix(linking) && remainder.count > linking.count + 3 {
            remainder = remainder.dropFirst(linking.count)
            break
        }
        return !derivativeTails.contains { remainder.hasPrefix($0) }
    }

    /// Word tails that turn an ingredient into a different product.
    private static let derivativeTails: [String] = [
        "pulver", "paste", "saft", "öl", "wasser", "mark", "sirup", "essig", "brühe", "fond", "mehl",
        "flocken", "granulat", "creme", "soße", "sauce", "salat", "gemüse", "käse", "milch", "butter",
        "reis", "masse", "menge", "chips", "extrakt", "aroma",
    ]

    /// Word tails under which a step still names the ingredient itself,
    /// just prepared — "Zwiebelwürfel", "Blumenkohlröschen",
    /// "Zitronenzesten", "Thymianblättchen" — as opposed to a derivative
    /// (`derivativeTails`) or an unrelated compound ("Salzwasser").
    private static let preparedFormTails: [String] = [
        "würfel", "scheibe", "streifen", "ring", "stück", "röschen", "blatt", "blätt", "hälfte", "spalte",
        "stift", "nadel", "korn", "körner", "faden", "fäden", "zeste", "strunk", "strünk", "raspel", "spitze",
        "viertel", "achtel", "schnitz", "brocken", "kugel", "stange", "abrieb", "schale",
    ]

    /// Whether `tail` — what follows an ingredient's name inside a longer
    /// step word — still leaves that word naming the ingredient: an
    /// inflection ("Karotte**n**", "Wirsing**s**") or a prepared form. An
    /// optional linking element ("Zitrone**n**zesten") is stripped first.
    static func isInflectionOrPreparedForm(_ tail: Substring) -> Bool {
        let lower = tail.lowercased()
        if ["", "n", "en", "s", "es", "e", "er", "nen", "ern"].contains(lower) { return true }
        var rest = Substring(lower)
        for linking in ["en", "n", "s", "es", "e"] where rest.hasPrefix(linking) && rest.count > linking.count + 3 {
            rest = rest.dropFirst(linking.count)
            break
        }
        return preparedFormTails.contains { rest.hasPrefix($0) }
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
    private static func firstBareName(
        of canonicalTarget: String, in text: String, avoiding: [Range<String.Index>], catalog: IngredientCatalog
    ) -> Range<String.Index>? {
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
                // `matchedNameEnd` trims a *prefix* of the phrase, and the
                // phrase starts at this very word — so the name is exactly
                // what lies between the two.
                return wordStart..<end
            }
            // This word didn't start a match — skip past all of it, not
            // into it, so "utter" inside "Butter" is never tried on its own.
            while cursor < text.endIndex, text[cursor].isLetter || text[cursor] == "-" {
                cursor = text.index(after: cursor)
            }
            // The prepared form: "Zwiebelwürfel" still names the onions.
            // The name at the start of the word, and after it nothing but
            // an inflection or a preparation — see `isInflectionOrPreparedForm`.
            let word = text[wordStart..<cursor].lowercased()
            if canonicalTarget.count >= 4, word.hasPrefix(canonicalTarget),
               isInflectionOrPreparedForm(Substring(word.dropFirst(canonicalTarget.count))),
               !avoiding.contains(where: { $0.contains(wordStart) }) {
                return wordStart..<cursor
            }
        }
        return nil
    }

    /// Where a bundle member is first named bare in `text` — the
    /// counterpart of `firstBareName` for the tier that matches through
    /// the catalog's variant relation instead of by name. Same walk over
    /// every word start, same negation rule.
    private static func firstGroupName(
        groupKey: String, in text: String, avoiding: [Range<String.Index>], catalog: IngredientCatalog
    ) -> Range<String.Index>? {
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
                return wordStart..<end
            }
            while cursor < text.endIndex, text[cursor].isLetter || text[cursor] == "-" {
                cursor = text.index(after: cursor)
            }
        }
        return nil
    }

    /// Where a bare step word first names `pots[potIndex]` as the head of a
    /// compound — the counterpart of `firstBareName` for the tier where
    /// no pot is named outright. Only capitalized words are tried: the
    /// compound head is a noun, and skipping the lowercase ones keeps a
    /// verb like "braten" from ever being read as the tail of one.
    private static func firstCompoundHead(
        claimedBy potIndex: Int, pots: [Pot], addressed: Set<String>?, in text: String,
        avoiding: [Range<String.Index>], catalog: IngredientCatalog
    ) -> Range<String.Index>? {
        for match in text.matches(of: /[\p{L}][\p{L}\-]*/) {
            let word = text[match.range]
            guard word.first?.isUppercase == true,
                  !avoiding.contains(where: { $0.contains(match.range.lowerBound) })
            else { continue }
            if compoundHeadPot(claiming: word, pots: pots, addressed: addressed, catalog: catalog) == potIndex {
                return match.range
            }
        }
        return nil
    }

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
        _ name: String, in text: String, negated: [Range<String.Index>]
    ) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: name, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            let startsWord = found.lowerBound == text.startIndex
                || !text[text.index(before: found.lowerBound)].isLetter
            let endsWord = found.upperBound == text.endIndex
                || !text[found.upperBound].isLetter
            // A name found inside a longer word only counts where that
            // word still names the ingredient: at its start, and followed
            // by nothing but an inflection or a prepared form. "Lauch"
            // inside "Knoblauch" and "Salz" inside "Salzwasser" are
            // different things; "Zwiebel" inside "Zwiebelwürfel" is not.
            var wordEnd = found.upperBound
            while wordEnd < text.endIndex, text[wordEnd].isLetter { wordEnd = text.index(after: wordEnd) }
            // The shortest names get no such latitude: "Ei" plus an
            // inflection is "ein", "Öl" plus a tail is a different oil.
            let endsAcceptably = endsWord
                || (name.count >= 4 && isInflectionOrPreparedForm(text[found.upperBound..<wordEnd]))
            if startsWord, endsAcceptably,
               !negated.contains(where: { $0.overlaps(found) }) {
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

    /// Brute-force backtracking over which pot each written number claims,
    /// with the ones that are not part of any bottleneck resolved outright
    /// by having only one candidate to begin with.
    ///
    /// Ambiguity is only worth resolving where it changes the outcome: two
    /// solutions that both leave every mention with the same assignment are
    /// one solution as far as the cook is concerned, so only mentions whose
    /// assignment actually varies across the assignments claiming the most
    /// mentions are left unresolved.
    private static func solve(domains: [[Candidate]], potCount: Int) -> [Int: Candidate] {
        let order = domains.indices.sorted { domains[$0].count < domains[$1].count }
        var bestCount = -1
        var bestSolutions: [[Int: Int]] = []  // mention index -> index into its domain
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
            for (candidateIndex, candidate) in domains[mentionIndex].enumerated() {
                guard remaining[candidate.potIndex] + 1e-6 >= candidate.fraction else { continue }
                remaining[candidate.potIndex] -= candidate.fraction
                current[mentionIndex] = candidateIndex
                backtrack(position + 1)
                current[mentionIndex] = nil
                remaining[candidate.potIndex] += candidate.fraction
            }
            backtrack(position + 1)  // Leaving this mention unassigned is always an option.
        }

        backtrack(0)

        guard let first = bestSolutions.first else { return [:] }
        var resolved: [Int: Candidate] = [:]
        for (mentionIndex, candidateIndex) in first where bestSolutions.allSatisfy({ $0[mentionIndex] == candidateIndex }) {
            resolved[mentionIndex] = domains[mentionIndex][candidateIndex]
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

        var lowerBound: String.Index {
            switch self {
            case .replace(let range, _, _): range.lowerBound
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
            }
        }
        flush(to: text.endIndex)
        return segments
    }

    /// The primitive `AmountScaler` delegates to for text with no recipe
    /// context at all — every recognized unit scaled blindly, exactly as
    /// before the resolver existed.
    /// Whether a number no ingredient line claims may still move with the
    /// serving count. Two shapes never do, and on the library they were
    /// more common among loose numbers than amounts were: a size ("in 3 cm
    /// große Würfel", "Ø 26 cm") and an amount given per piece ("je ca. 90
    /// g", "Bällchen, etwa 40 g schwer", "mit je 120 g Gewicht"). Doubling
    /// the servings does not double the dice or the form.
    static func scalesBlindly(_ unit: IngredientUnit, writtenRange: Range<String.Index>, in text: String) -> Bool {
        if unit == .centimeter { return false }
        let before = wordsBefore(writtenRange.lowerBound, in: text, count: 3)
            .filter { !approximationWords.contains($0) }
        if let last = before.last, perPieceLeadWords.contains(last) { return false }
        let after = AmountMentionScanner.namePhrase(after: writtenRange.upperBound, in: text, maxWords: 3)
            .split(separator: " ").map { $0.lowercased() }
        if after.contains(where: { perPieceTrailWords.contains($0) }) { return false }
        return true
    }

    private static let approximationWords: Set<String> = ["ca", "ca.", "etwa", "circa", "ungefähr", "rund", "gut", "knapp"]
    private static let perPieceLeadWords: Set<String> = ["je", "jeweils", "pro", "à"]
    private static let perPieceTrailWords: Set<String> = ["schwer", "gewicht", "durchmesser", "pro", "je"]

    /// The last `count` words before `index`, lowercased, in text order.
    private static func wordsBefore(_ index: String.Index, in text: String, count: Int) -> [String] {
        let head = text[..<index]
        return head.split(whereSeparator: { $0 == " " || $0 == "," }).suffix(count).map { $0.lowercased() }
    }

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
                guard scalesBlindly(unit, writtenRange: match.range, in: text) else { continue }
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
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var result: [RecipeIngredient] = []
        var covered = Set<UUID>()

        // What the register says this step takes, as chips — the amount at
        // the resolution's own serving count. An amount written in the
        // sentence is rendered there instead, and a back-reference names
        // what an earlier step already holds: neither gets a chip.
        for intake in resolution.intakes(for: step) {
            covered.formUnion(intake.ingredientLineIDs)
            guard !intake.inline, !intake.isBackReference,
                  let firstID = intake.ingredientLineIDs.first, var line = byID[firstID]
            else { continue }
            line.quantity = intake.quantity
            if let label = intake.label { line.name = label }
            result.append(line)
        }

        // Lines without a quantity never form a pot — "Salz", "Pfeffer" —
        // so they are matched by name here, the way every chip once was.
        let negated = StepAmountResolver.negatedRanges(in: step.text)
        let ownedKeys = Set(all.map { IngredientCatalog.normalize(catalog.canonicalName(for: $0.name)) })
        let words = step.text.matches(of: /[\p{L}][\p{L}\-]*/).compactMap { match -> String? in
            let word = step.text[match.range]
            guard word.first?.isUppercase == true,
                  !negated.contains(where: { $0.contains(match.range.lowerBound) })
            else { return nil }
            return IngredientCatalog.normalize(catalog.canonicalName(for: String(word)))
        }
        for line in all where line.quantity == nil && !covered.contains(line.id) {
            let name = line.name.trimmingCharacters(in: .whitespaces)
            guard name.count >= 2 else { continue }
            let canonical = catalog.canonicalName(for: name)
            var mentioned = StepAmountResolver.mentionedAsBareName(name, in: step.text, negated: negated)
                || words.contains(IngredientCatalog.normalize(canonical))
            if !mentioned, canonical.count >= 4, canonical.lowercased() != name.lowercased() {
                mentioned = StepAmountResolver.mentionedAsBareName(canonical, in: step.text, negated: negated)
            }
            if !mentioned, let head = StepAmountResolver.headWord(of: name),
               !ownedKeys.contains(IngredientCatalog.normalize(catalog.canonicalName(for: head))) {
                mentioned = StepAmountResolver.mentionedAsBareName(head, in: step.text, negated: negated)
            }
            if mentioned {
                covered.insert(line.id)
                result.append(line)
            }
        }
        return result
    }
}
