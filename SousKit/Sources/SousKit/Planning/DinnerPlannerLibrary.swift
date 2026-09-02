import Foundation

/// Runs a planning pass and holds its proposal for the sheet: gathers the
/// window, the pool and the candidates, warms their nutrition, lets the
/// pure ``DinnerPlanner`` decide, and — only on "Übernehmen" — writes the
/// accepted placements through ``MealPlanLibrary`` in one batch. Nothing
/// here persists; closing the sheet discards the run.
@MainActor
@Observable
public final class DinnerPlannerLibrary {
    /// Where the accepted dinners go.
    public enum Mode: Hashable, Sendable {
        /// Onto the next empty dinner days.
        case days
        /// Into the undated pool.
        case pool
    }

    public enum EmptyReason: Hashable, Sendable {
        case noEmptySlots
        case noCandidates
    }

    public enum Phase {
        case idle
        case loading(progress: Double)
        case ready(PlanProposal)
        case empty(EmptyReason)
    }

    public private(set) var phase: Phase = .idle
    public var errorMessage: String?

    private let recipeStore: any RecipeStore
    private let mealPlan: MealPlanLibrary
    private let nutrition: NutritionLibrary
    private let enrichment: any RecipeEnrichmentStore

    /// The run's inputs, kept for swaps and the summary line.
    private var request: PlanRequest?
    /// The recipes behind the candidates, for applying and for the rows.
    private var recipesByID: [UUID: Recipe] = [:]
    /// What earlier swaps already turned down, so "austauschen" cycles
    /// onward instead of bouncing between two dishes.
    private var swappedAway: Set<UUID> = []
    /// What the user deselected before asking for a fresh proposal.
    private var rejected: Set<UUID> = []
    /// This run's variety seed — drawn fresh per `propose`, so asking again
    /// genuinely proposes anew among the near-equals, and carried in the
    /// request so a swap prices candidates the same way the run did.
    private var seed: UInt64 = 0
    /// How many contenders the last run had to leave out because not a
    /// single ingredient produced a figure — the sheet says this number,
    /// because "only four proposals" is otherwise indistinguishable from a
    /// planner that is broken.
    public private(set) var leftOutWithoutFigures = 0

    public init(
        recipeStore: any RecipeStore,
        mealPlan: MealPlanLibrary,
        nutrition: NutritionLibrary,
        enrichment: any RecipeEnrichmentStore
    ) {
        self.recipeStore = recipeStore
        self.mealPlan = mealPlan
        self.nutrition = nutrition
        self.enrichment = enrichment
    }

    public func recipe(for placement: PlanProposal.Placement) -> Recipe? {
        recipesByID[placement.candidate.recipeID]
    }

    /// The mix verdict for the rows currently ticked — recomputed on every
    /// toggle, cheap because everything is already warmed.
    public func summary(selecting ids: Set<UUID>) -> MixSummary? {
        guard let request, case .ready(let proposal) = phase else { return nil }
        let mix = proposal.placements
            .filter { ids.contains($0.id) }
            .reduce(request.baseVector) { $0 + ($1.candidate.perPortion ?? .zero) }
        return PlanCost.summary(of: mix)
    }

    public func reset() {
        phase = .idle
        request = nil
        recipesByID = [:]
        swappedAway = []
        rejected = []
        // A message nobody read must not greet the next opening of the sheet.
        errorMessage = nil
    }

    // MARK: - Proposing

    /// Builds and runs one request. `excluding` carries the recipes the
    /// user deselected before asking again; they stay excluded for the
    /// rest of the run.
    public func propose(mode: Mode, count: Int, excluding: Set<UUID> = []) async {
        rejected.formUnion(excluding)
        swappedAway = []
        seed = UInt64.random(in: 1 ... .max)
        phase = .loading(progress: 0)

        await mealPlan.reload()
        await nutrition.ensureLoaded()

        let pool = mealPlan.pooledMeals.compactMap { entry, recipe -> (MealPlanEntry, Recipe)? in
            guard let recipe, !rejected.contains(recipe.id) else { return nil }
            return (entry, recipe)
        }

        switch mode {
        case .days:
            await proposeOntoDays(count: count, pool: pool)
        case .pool:
            await proposeIntoPool(count: count, pool: pool)
        }
    }

    private func proposeOntoDays(count: Int, pool: [(MealPlanEntry, Recipe)]) async {
        // The next N dinner-less days, scanned forward from today. The
        // loaded run is 28 days deep, which is as far as a dinner plan
        // needs to look.
        let seatDays = mealPlan.days.filter { day in
            !mealPlan.plan(for: day).contains { $0.entry.slot == .dinner }
        }.prefix(count).map(\.self)
        guard !seatDays.isEmpty, let lastDay = seatDays.last else {
            phase = .empty(.noEmptySlots)
            return
        }

        // Everything dated up to the last seat blocks its dish; the dated
        // dinners among it are also what the proposal has to complement.
        let span = mealPlan.days.filter { $0 <= lastDay }
        var excludedDishKeys = Set<UUID>()
        var baseVector = NutritionInfo.zero
        for day in span {
            for (entry, recipe) in mealPlan.plan(for: day) {
                guard let recipe else { continue }
                excludedDishKeys.insert(dishKey(of: recipe))
                if entry.slot == .dinner,
                   let figures = await nutrition.nutrition(for: recipe) {
                    baseVector = baseVector + figures.perPortion
                }
            }
        }

        // A collection dish that already sits in the pool is spoken for —
        // the pool version is the one that may take a seat.
        let pooledKeys = Set(pool.map { dishKey(of: $0.1) })
        let contenders = await gatherContenders(excludingDishKeys: excludedDishKeys.union(pooledKeys))

        var candidates: [PlannerCandidate] = pool.map { entry, recipe in
            PlannerCandidate(
                recipeID: recipe.id,
                dishKey: dishKey(of: recipe),
                source: .pool(entryID: entry.id, servings: entry.servings),
                isWantToCook: recipe.wantToCook,
                perPortion: nil,
                title: recipe.title
            )
        }
        candidates.append(contentsOf: contenders)
        await warm(&candidates)

        finish(with: PlanRequest(
            seats: .days(seatDays),
            baseVector: baseVector,
            excludedDishKeys: excludedDishKeys,
            candidates: candidates,
            seed: seed
        ))
    }

    private func proposeIntoPool(count: Int, pool: [(MealPlanEntry, Recipe)]) async {
        // The pool is not a candidate source here — seating the pool into
        // the pool would be a no-op. It is what the run complements: its
        // meals feed the base vector, its dishes are off the table.
        var excludedDishKeys = Set<UUID>()
        var baseVector = NutritionInfo.zero
        for (_, recipe) in pool {
            excludedDishKeys.insert(dishKey(of: recipe))
            if let figures = await nutrition.nutrition(for: recipe) {
                baseVector = baseVector + figures.perPortion
            }
        }
        // What is already on a day is decided just as firmly as the pool —
        // proposing Thursday's dinner into the Sammlung would say the same
        // thing twice.
        for day in mealPlan.days {
            for (_, recipe) in mealPlan.plan(for: day) {
                guard let recipe else { continue }
                excludedDishKeys.insert(dishKey(of: recipe))
            }
        }

        var candidates = await gatherContenders(excludingDishKeys: excludedDishKeys)
        await warm(&candidates)

        finish(with: PlanRequest(
            seats: .pool(count: count),
            baseVector: baseVector,
            excludedDishKeys: excludedDishKeys,
            candidates: candidates,
            seed: seed
        ))
    }

    private func finish(with request: PlanRequest) {
        self.request = request
        guard !request.candidates.isEmpty else {
            phase = .empty(.noCandidates)
            return
        }
        let proposal = DinnerPlanner.plan(request)
        phase = proposal.placements.isEmpty ? .empty(.noCandidates) : .ready(proposal)
    }

    // MARK: - Candidates

    private func dishKey(of recipe: Recipe) -> UUID {
        recipe.variantGroupID ?? recipe.id
    }

    /// The two competing tiers: marked recipes, then the whole collection.
    /// Deduplication by recipe happens in the planner; dishes already
    /// spoken for are dropped here so they never cost a model call.
    private func gatherContenders(excludingDishKeys: Set<UUID>) async -> [PlannerCandidate] {
        let marked = (try? await recipeStore.recipes(matching: RecipeQuery(onlyWantToCook: true))) ?? []
        let all = (try? await recipeStore.recipes(matching: RecipeQuery())) ?? []

        var seen = Set<UUID>()
        var contenders: [PlannerCandidate] = []
        for (recipes, source) in [(marked, PlannerCandidate.Source.wantToCook), (all, .collection)] {
            for recipe in recipes {
                guard !rejected.contains(recipe.id),
                      seen.insert(recipe.id).inserted,
                      !excludingDishKeys.contains(dishKey(of: recipe))
                else { continue }
                contenders.append(PlannerCandidate(
                    recipeID: recipe.id,
                    dishKey: dishKey(of: recipe),
                    source: source,
                    isWantToCook: recipe.wantToCook,
                    perPortion: nil,
                    title: recipe.title
                ))
            }
        }
        return contenders
    }

    /// Fills in nutrition for every candidate and drops the contenders the
    /// gate turns away. Pool candidates pass regardless — the user already
    /// decided to eat those — they merely contribute nothing to the mix
    /// where no figures exist. The slow path is the first run over a large
    /// collection; afterwards every figure comes out of the content-hash
    /// cache.
    ///
    /// The gate takes what the list's rows take: a figure at least one
    /// ingredient contributed to. Demanding a *complete* figure sounded
    /// rigorous and starved the planner in practice — a grown, imported
    /// collection resolves a handful of recipes fully, and a planner that
    /// only knows four dishes proposes the same four forever, whatever the
    /// seed does. An incomplete figure is a floor; the candidate carries
    /// that flag and the sheet shows it as the list does, with an "≈".
    private func warm(_ candidates: inout [PlannerCandidate]) async {
        var warmed: [PlannerCandidate] = []
        let total = candidates.count
        leftOutWithoutFigures = 0
        for (index, candidate) in candidates.enumerated() {
            phase = .loading(progress: Double(index) / Double(max(total, 1)))
            guard let recipe = await resolveRecipe(candidate.recipeID) else { continue }
            recipesByID[recipe.id] = recipe

            var enriched = candidate
            let figures = await nutrition.nutrition(for: recipe)
            enriched.perPortion = figures?.perPortion
            enriched.isProvisional = figures.map { !$0.coverage.isComplete } ?? true

            if candidate.isPool {
                warmed.append(enriched)
                continue
            }
            guard let figures,
                  figures.coverage.includedCount > 0,
                  figures.perPortion.kcal > 0
            else {
                leftOutWithoutFigures += 1
                continue
            }
            guard await suitsDinner(recipe) else { continue }
            warmed.append(enriched)
        }
        candidates = warmed
    }

    private func resolveRecipe(_ id: UUID) async -> Recipe? {
        if let held = recipesByID[id] { return held }
        return try? await recipeStore.recipe(id: id)
    }

    /// Explicit choice first, then the cached guess, then — with nobody
    /// having said anything — dinner-eligible: main dishes are the
    /// majority, and the sheet catches the strays.
    private func suitsDinner(_ recipe: Recipe) async -> Bool {
        if let slots = recipe.suitableSlots {
            return slots.contains(.dinner)
        }
        let hash = MealSuitabilityClassifier.inputHash(for: recipe)
        if let guess = try? await enrichment.suitabilityGuess(for: recipe.id, inputHash: hash) {
            return guess.contains(.dinner)
        }
        guard MealSuitabilityClassifier.isAvailable,
              let guess = try? await MealSuitabilityClassifier.classify(recipe)
        else { return true }
        try? await enrichment.saveSuitabilityGuess(guess, for: recipe.id, inputHash: hash)
        return guess.contains(.dinner)
    }

    // MARK: - Re-addressing

    /// Moves the standing proposal between the two destinations without
    /// re-choosing anything: the dishes were picked for the mix, and the
    /// mix does not care whether it is eaten on dated evenings or out of
    /// the Sammlung. Switching to days deals the next free dinner days in
    /// row order; switching to the pool clears them.
    public func reassign(mode: Mode) {
        guard case .ready(var proposal) = phase else { return }
        switch mode {
        case .pool:
            for index in proposal.placements.indices {
                proposal.placements[index].day = nil
            }
        case .days:
            let seatDays = mealPlan.days.filter { day in
                !mealPlan.plan(for: day).contains { $0.entry.slot == .dinner }
            }.prefix(proposal.placements.count)
            for index in proposal.placements.indices {
                // Fewer free evenings than rows leaves the overhang undated
                // — those land in the Sammlung on apply, which the row says.
                proposal.placements[index].day =
                    index < seatDays.count ? seatDays[seatDays.startIndex + index] : nil
            }
        }
        phase = .ready(proposal)
    }

    /// The evenings a proposed dinner may sit on: every dinner-less day in
    /// the loaded run — those this proposal already targets included, since
    /// the plan itself does not know the proposal yet. An evening is not
    /// obliged to hold a dish, so the list runs past the proposal's size.
    public func availableDinnerDays() -> [Date] {
        Array(
            mealPlan.days.filter { day in
                !mealPlan.plan(for: day).contains { $0.entry.slot == .dinner }
            }.prefix(14)
        )
    }

    /// Puts one proposed dinner onto a chosen evening. A dish already
    /// sitting there takes this one's old place; an empty evening simply
    /// takes the dish, and the evening it left stays empty — an evening is
    /// under no obligation to hold a recipe.
    public func move(_ placement: PlanProposal.Placement, to day: Date?) {
        guard case .ready(var proposal) = phase,
              let from = proposal.placements.firstIndex(where: { $0.id == placement.id })
        else { return }
        if let day, let occupant = proposal.placements.firstIndex(where: { $0.day == day }) {
            proposal.placements[occupant].day = proposal.placements[from].day
        }
        proposal.placements[from].day = day
        // The rows keep reading top-to-bottom in day order, wherever the
        // move put things; the undated sink to the bottom, where the
        // Sammlung's rows belong.
        proposal.placements.sort {
            ($0.day ?? .distantFuture) < ($1.day ?? .distantFuture)
        }
        phase = .ready(proposal)
    }

    // MARK: - Swapping

    /// Replaces one proposed dinner with the best alternative still
    /// standing. Returns whether anything changed — when nothing does, the
    /// alternatives are exhausted and the sheet may say so.
    @discardableResult
    public func swap(_ placement: PlanProposal.Placement) -> Bool {
        guard let request, case .ready(var proposal) = phase,
              let replacement = DinnerPlanner.replacement(
                  for: placement, in: proposal, request: request, excluding: swappedAway
              ),
              let index = proposal.placements.firstIndex(where: { $0.id == placement.id })
        else { return false }
        swappedAway.insert(placement.candidate.recipeID)
        proposal.placements[index].candidate = replacement
        let mix = proposal.placements.reduce(request.baseVector) {
            $0 + ($1.candidate.perPortion ?? .zero)
        }
        proposal.summary = PlanCost.summary(of: mix)
        phase = .ready(proposal)
        return true
    }

    // MARK: - Applying

    /// Writes the accepted placements — the one moment a run touches the
    /// plan.
    /// Says whether every placement landed. On `false` the sheet that asked
    /// should stay open and show `errorMessage` rather than dismiss over a
    /// plan that did not change.
    @discardableResult
    public func apply(_ accepted: [PlanProposal.Placement]) async -> Bool {
        var placements: [(day: Date?, kind: MealPlanLibrary.PlanPlacementKind)] = []
        for placement in accepted {
            switch placement.candidate.source {
            case .pool(let entryID, _):
                // Looked up fresh: the entry may have moved or died while
                // the sheet stood open, and a stale copy would resurrect it.
                guard let entry = mealPlan.pool.first(where: { $0.id == entryID }) else { continue }
                placements.append((placement.day, .seatPoolEntry(entry)))
            case .wantToCook, .collection:
                guard let recipe = recipesByID[placement.candidate.recipeID] else { continue }
                placements.append((placement.day, .addRecipe(recipe)))
            }
        }
        await mealPlan.apply(placements)
        // Taken over, not copied: the planner drove this write and its sheet
        // is the screen up right now, so the message is shown there and not
        // a second time by the plan behind it.
        if let message = mealPlan.errorMessage {
            errorMessage = message
            mealPlan.errorMessage = nil
            return false
        }
        return true
    }
}
