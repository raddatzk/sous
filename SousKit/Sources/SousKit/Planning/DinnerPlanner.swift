import Foundation

/// A recipe standing for election into a plan run.
public struct PlannerCandidate: Identifiable, Hashable, Sendable {
    /// Where the candidate came from, which decides how it is treated:
    /// pool entries are decided-on meals and seat as a constraint; the
    /// other two tiers compete on cost.
    public enum Source: Hashable, Sendable {
        /// An undated ``MealPlanEntry`` — its identity and servings travel
        /// with it, because seating it is moving it, not copying it.
        case pool(entryID: UUID, servings: Int?)
        case wantToCook
        case collection
    }

    public var recipeID: UUID
    /// Variants of one dish count as one dish: `variantGroupID ?? id`.
    public var dishKey: UUID
    public var source: Source
    /// Set for the wantToCook tier, and for a pool entry whose recipe
    /// carries the mark.
    public var isWantToCook: Bool
    /// One portion's nutrition. `nil` only for pool entries — the user
    /// already decided to eat those, so a missing figure cannot unseat
    /// them; it merely contributes nothing to the mix.
    public var perPortion: NutritionInfo?
    /// Whether `perPortion` is a floor rather than the dish — ingredients
    /// without figures left out, or resting on unconfirmed bases. Same
    /// standing the list's "≈ 847 kcal" chip has: shown, never naked.
    public var isProvisional: Bool
    public var title: String

    public var id: UUID { recipeID }

    public init(
        recipeID: UUID,
        dishKey: UUID,
        source: Source,
        isWantToCook: Bool = false,
        perPortion: NutritionInfo? = nil,
        isProvisional: Bool = false,
        title: String = ""
    ) {
        self.recipeID = recipeID
        self.dishKey = dishKey
        self.source = source
        self.isWantToCook = isWantToCook
        self.perPortion = perPortion
        self.isProvisional = isProvisional
        self.title = title
    }

    public var isPool: Bool {
        if case .pool = source { return true }
        return false
    }

    fileprivate var tier: Int {
        switch source {
        case .pool: 0
        case .wantToCook: 1
        case .collection: 2
        }
    }
}

/// One run's inputs, assembled by the coordinator.
public struct PlanRequest: Sendable {
    /// What is being filled: concrete dinner days, or a number of undated
    /// entries for the pool.
    public enum Seats: Sendable {
        case days([Date])
        case pool(count: Int)
    }

    public var seats: Seats
    /// What is already decided and eaten alongside — dated dinners in the
    /// span, or the existing pool. The proposal complements this, never
    /// replaces it.
    public var baseVector: NutritionInfo
    /// Dishes that may not be proposed because the span already holds them.
    public var excludedDishKeys: Set<UUID>
    public var candidates: [PlannerCandidate]
    /// Which of the near-equals this run favours. `0` means none of them —
    /// pure cost, fully repeatable, what every test wants. Any other value
    /// hands each candidate a small, seed-stable jitter (see
    /// ``PlanCost/varietyJitter``), so "Neu vorschlagen" can genuinely
    /// propose anew: the run is still deterministic *given its seed*, but a
    /// fresh seed reshuffles everything the cost function considers about
    /// equally good — without ever letting a clearly worse dinner win.
    public var seed: UInt64

    public init(
        seats: Seats,
        baseVector: NutritionInfo = .zero,
        excludedDishKeys: Set<UUID> = [],
        candidates: [PlannerCandidate],
        seed: UInt64 = 0
    ) {
        self.seats = seats
        self.baseVector = baseVector
        self.excludedDishKeys = excludedDishKeys
        self.candidates = candidates
        self.seed = seed
    }

    var seatCount: Int {
        switch seats {
        case .days(let days): days.count
        case .pool(let count): count
        }
    }
}

/// What a run proposes: one dinner per seat, nothing written anywhere.
public struct PlanProposal: Sendable {
    public struct Placement: Identifiable, Sendable {
        /// The day this dinner is proposed for; `nil` when the run fills
        /// the pool.
        public var day: Date?
        public var candidate: PlannerCandidate

        public var id: UUID { candidate.recipeID }
    }

    public var placements: [Placement]
    /// The mix verdict for the whole proposal, base included.
    public var summary: MixSummary
}

/// The planner itself: greedy construction, then local swap improvement —
/// deterministic from end to end, so the same collection proposes the same
/// dinners every time.
public enum DinnerPlanner {
    public static func plan(_ request: PlanRequest) -> PlanProposal {
        let selection = improvedSelection(request)
        return proposal(for: selection, request: request)
    }

    /// The best still-unused candidate for one seat, everything else held
    /// fixed — the sheet's "austauschen". `excluding` carries what earlier
    /// swaps already turned down, so repeated taps cycle onward instead of
    /// bouncing between two dishes.
    public static func replacement(
        for placement: PlanProposal.Placement,
        in proposal: PlanProposal,
        request: PlanRequest,
        excluding: Set<UUID> = []
    ) -> PlannerCandidate? {
        let kept = proposal.placements.filter { $0.id != placement.id }
        var usedKeys = request.excludedDishKeys
        var usedRecipes = excluding
        var mix = request.baseVector
        var wantToCookCount = 0
        for held in kept {
            usedKeys.insert(held.candidate.dishKey)
            usedRecipes.insert(held.candidate.recipeID)
            mix = mix + (held.candidate.perPortion ?? .zero)
            if held.candidate.isWantToCook { wantToCookCount += 1 }
        }
        usedRecipes.insert(placement.candidate.recipeID)

        let (_, contenders) = normalized(request)
        return best(
            of: contenders.filter {
                !usedRecipes.contains($0.recipeID) && !usedKeys.contains($0.dishKey)
            },
            mix: mix,
            wantToCookCount: wantToCookCount,
            seed: request.seed
        )
    }

    // MARK: - Variety

    /// The candidate's jitter under this run's seed: a hash of the two,
    /// mapped into [0, ``PlanCost/varietyJitter``). Stable within a run —
    /// greedy, swap pass and "austauschen" must all price a candidate the
    /// same — and independent of any iteration order. Seed 0 is exempt,
    /// so an unseeded request behaves exactly as it always did.
    static func jitter(for recipeID: UUID, seed: UInt64) -> Double {
        guard seed != 0 else { return 0 }
        // FNV-1a over the uuid's bytes, folded with the seed — no Hasher,
        // whose per-launch randomization would make runs unrepeatable.
        var hash: UInt64 = 0xcbf29ce484222325 ^ seed
        let bytes = recipeID.uuid
        for byte in [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
                     bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15] {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Double(hash % 10_000) / 10_000 * PlanCost.varietyJitter
    }

    // MARK: - Selection

    /// The greedy pass alone — the test hook proving the swap pass earns
    /// its keep.
    static func greedySelection(_ request: PlanRequest) -> [PlannerCandidate] {
        let (pool, contenders) = normalized(request)
        var state = SelectionState(request: request)
        state.seatPool(pool)
        state.fillGreedily(from: contenders)
        return state.selection
    }

    static func improvedSelection(_ request: PlanRequest) -> [PlannerCandidate] {
        let (pool, contenders) = normalized(request)
        var state = SelectionState(request: request)
        state.seatPool(pool)
        state.fillGreedily(from: contenders)
        state.improveBySwapping(with: contenders)
        return state.selection
    }

    /// Candidates in their deciding order, split into the pool (kept in
    /// the caller's order — oldest first — because that order is a promise)
    /// and the contenders (sorted by tier, then title, then id: the tie
    /// break that makes every run repeatable).
    private static func normalized(
        _ request: PlanRequest
    ) -> (pool: [PlannerCandidate], contenders: [PlannerCandidate]) {
        var seen = Set<UUID>()
        var pool: [PlannerCandidate] = []
        var contenders: [PlannerCandidate] = []
        // Pool first, so a recipe standing in two tiers keeps its best one.
        for candidate in request.candidates.filter(\.isPool)
        where !request.excludedDishKeys.contains(candidate.dishKey) {
            guard seen.insert(candidate.recipeID).inserted else { continue }
            pool.append(candidate)
        }
        for candidate in request.candidates.filter({ !$0.isPool })
        where !request.excludedDishKeys.contains(candidate.dishKey) {
            guard seen.insert(candidate.recipeID).inserted else { continue }
            contenders.append(candidate)
        }
        contenders.sort {
            ($0.tier, $0.title.lowercased(), $0.recipeID.uuidString)
                < ($1.tier, $1.title.lowercased(), $1.recipeID.uuidString)
        }
        return (pool, contenders)
    }

    private static func best(
        of candidates: [PlannerCandidate],
        mix: NutritionInfo,
        wantToCookCount: Int,
        seed: UInt64
    ) -> PlannerCandidate? {
        var winner: PlannerCandidate?
        var winningCost = Double.infinity
        for candidate in candidates {
            let cost = PlanCost.totalCost(
                of: mix + (candidate.perPortion ?? .zero),
                wantToCookCount: wantToCookCount + (candidate.isWantToCook ? 1 : 0)
            ) + jitter(for: candidate.recipeID, seed: seed)
            // Strictly less: with equal cost the first in sort order keeps
            // the seat, which is what encodes the tier priority into ties.
            if cost < winningCost {
                winner = candidate
                winningCost = cost
            }
        }
        return winner
    }

    /// The mutable middle of a run: who sits, what the mix is, which dish
    /// keys are spent.
    private struct SelectionState {
        var selection: [PlannerCandidate] = []
        var mix: NutritionInfo
        var usedKeys: Set<UUID>
        var wantToCookCount = 0
        let seatCount: Int
        let seed: UInt64

        init(request: PlanRequest) {
            mix = request.baseVector
            usedKeys = request.excludedDishKeys
            seatCount = request.seatCount
            seed = request.seed
        }

        var seatsLeft: Int { seatCount - selection.count }

        mutating func seat(_ candidate: PlannerCandidate) {
            selection.append(candidate)
            usedKeys.insert(candidate.dishKey)
            mix = mix + (candidate.perPortion ?? .zero)
            if candidate.isWantToCook { wantToCookCount += 1 }
        }

        /// Pool entries are decided-on meals: they seat in their order, as
        /// a constraint rather than a preference, and never lose their
        /// seat to the swap pass. A second pool entry of the same dish
        /// stays behind — one seat per dish holds for the pool too.
        mutating func seatPool(_ pool: [PlannerCandidate]) {
            for candidate in pool where seatsLeft > 0 {
                guard !usedKeys.contains(candidate.dishKey) else { continue }
                seat(candidate)
            }
        }

        mutating func fillGreedily(from contenders: [PlannerCandidate]) {
            while seatsLeft > 0 {
                let open = contenders.filter {
                    !selection.contains($0) && !usedKeys.contains($0.dishKey)
                }
                guard let pick = best(of: open, mix: mix, wantToCookCount: wantToCookCount, seed: seed)
                else { break }
                seat(pick)
            }
        }

        /// Local improvement: replace one seated contender with one left
        /// standing whenever that strictly lowers the cost. The cost is
        /// day-invariant in V1 — a swap exchanges membership in the dish
        /// multiset, never days — so seats need no identity here. Bounded
        /// twice over: the cost strictly decreases with every accepted
        /// swap over a finite set of selections, and the round counter
        /// backstops that argument against floating-point mischief.
        mutating func improveBySwapping(with contenders: [PlannerCandidate], rounds: Int = 5) {
            for _ in 0..<rounds {
                guard swapOnce(with: contenders) else { return }
            }
        }

        private mutating func swapOnce(with contenders: [PlannerCandidate]) -> Bool {
            let currentCost = PlanCost.totalCost(of: mix, wantToCookCount: wantToCookCount)
            for (index, seated) in selection.enumerated() where !seated.isPool {
                let mixWithout = mix + (seated.perPortion ?? .zero).scaled(by: -1)
                let marksWithout = wantToCookCount - (seated.isWantToCook ? 1 : 0)
                for challenger in contenders {
                    guard !selection.contains(challenger) else { continue }
                    let keysWithout = usedKeys.subtracting([seated.dishKey])
                    guard !keysWithout.contains(challenger.dishKey) else { continue }
                    // The jitter rides in both sides of the comparison —
                    // the kept seats' shares cancel out, so only the two
                    // dishes actually trading places bring theirs. Without
                    // this, the swap pass would quietly undo whatever
                    // variety the seed just bought.
                    let cost = PlanCost.totalCost(
                        of: mixWithout + (challenger.perPortion ?? .zero),
                        wantToCookCount: marksWithout + (challenger.isWantToCook ? 1 : 0)
                    ) + jitter(for: challenger.recipeID, seed: seed)
                    let seatedCost = currentCost + jitter(for: seated.recipeID, seed: seed)
                    guard cost < seatedCost - PlanCost.improvementEpsilon else { continue }
                    selection[index] = challenger
                    usedKeys = keysWithout.union([challenger.dishKey])
                    mix = mixWithout + (challenger.perPortion ?? .zero)
                    wantToCookCount = marksWithout + (challenger.isWantToCook ? 1 : 0)
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Days

    /// Cost is day-invariant, so the days are dealt deterministically:
    /// pool seats oldest-first onto the earliest days, the rest in their
    /// deciding order behind them.
    private static func proposal(
        for selection: [PlannerCandidate],
        request: PlanRequest
    ) -> PlanProposal {
        let ordered = selection.filter(\.isPool) + selection.filter { !$0.isPool }
        let placements: [PlanProposal.Placement]
        switch request.seats {
        case .days(let days):
            placements = zip(days.sorted(), ordered).map { day, candidate in
                PlanProposal.Placement(day: day, candidate: candidate)
            }
        case .pool:
            placements = ordered.map { PlanProposal.Placement(day: nil, candidate: $0) }
        }
        let mix = placements.reduce(request.baseVector) { partial, placement in
            partial + (placement.candidate.perPortion ?? .zero)
        }
        return PlanProposal(placements: placements, summary: PlanCost.summary(of: mix))
    }
}
