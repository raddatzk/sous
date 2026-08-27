import Foundation

/// The pass that runs when the shipped data has changed under the cook's
/// vocabulary — the concept's §7 reconciliation, and the last thing phase 6
/// was missing.
///
/// Almost all of what §7 asks for the app already does by construction, and
/// this pass deliberately does not repeat any of it:
///
/// - **Changed values flow in silently** (decision D). A basis stores a
///   *code*, never numbers, and reads its values through `BLSCatalog` on
///   every read. A release that moves a figure moves it for every recipe the
///   next time one is computed, with nothing written and nothing announced.
///   There is no code here for that, and there must not be: writing values
///   down is exactly what would break it.
/// - **A vanished code already reads as orphaned.**
///   ``BasisAssignment/basis(bls:source:)`` answers with `.orphaned` when its
///   row is gone, so the drill-down, the "N Zutaten ohne bestätigte
///   Nährwerte" banner and the basis picker have shown the state since
///   phase 4 — before any pass ran.
/// - **A code that comes back heals itself.** Both branches of that read map
///   a stored `.orphaned` to `.confirmed` the moment the row resolves again.
///
/// So what is left for a pass to do is the one thing a read cannot: put the
/// affected words on a list, so that the cook is *told* rather than having to
/// stumble into the recipe that happens to use one.
///
/// **What the pass writes (decision E1).** It does **not** store `.orphaned`
/// into the assignment. Storing it would buy nothing — the read computes the
/// same answer from the same data, and a stored `.orphaned` is discarded by
/// the very read that would use it — while costing the one thing that
/// actually matters: a stored status can go stale against the shipped data,
/// and then two sources disagree about the same word. The read-time
/// computation stays the single truth. What the pass writes instead is
/// `needsBasisReview`, a field that already exists, already means "this word
/// has an open question about its basis", and is already read by the
/// ingredient form. The report carries the names, for whoever wants to say
/// how many there are.
///
/// **Nothing but orphans is reported**, per decision D: the pass never counts
/// a changed value, because it never looks at one.
public enum OrphanReconciliation {
    /// What one run found, so a caller (and a test) can see it happened.
    public struct Report: Hashable, Sendable {
        /// Every vocabulary word whose basis points at a row the shipped data
        /// no longer has — whether or not this run was the one to notice.
        public var orphanedNames: [String] = []
        /// How many entries this run newly put on the review list. Zero on a
        /// second run over the same data, which is what makes the pass a
        /// no-op the second time.
        public var flagged = 0

        public var didChangeAnything: Bool { flagged > 0 }
    }
}

/// Runs the reconciliation against any vocabulary store.
///
/// Written against the protocol rather than one framework, because the
/// vocabulary now has two stores and this pass has to keep working after it
/// moves. It reads and writes through `VocabularyStore` — deliberately not
/// through `IngredientCatalogLibrary`: every `setBasis` there drops the whole
/// nutrition cache twice and rebuilds the vocabulary once, so a hundred
/// orphaned words would mean two hundred table deletes and a hundred reloads
/// to set a hundred booleans.
///
/// It merges by key like the passes before it rather than assuming it is the
/// first writer: the share extension runs no migration at all and can
/// perfectly well have written a vocabulary row after the update and before
/// the app was next opened.
public struct VocabularyOrphanReconciliation: Sendable {
    private let store: any VocabularyStore

    public init(store: any VocabularyStore) {
        self.store = store
    }

    /// Idempotent: an entry already carrying the review flag is counted as
    /// orphaned but not written again, so a second run changes nothing.
    @discardableResult
    public func run(bls: BLSCatalog = .bundled) async throws -> OrphanReconciliation.Report {
        var report = OrphanReconciliation.Report()

        for entry in try await store.entries() {
            guard entry.bases.values.contains(where: { $0.isOrphaned(in: bls) }) else { continue }
            report.orphanedNames.append(entry.name)
            // Already on the list — from an earlier run, or from the phase-3
            // stamp for a name that never mapped anywhere. Either way the
            // question is open and asking it twice writes nothing new.
            guard !entry.needsBasisReview else { continue }
            var flagged = entry
            flagged.needsBasisReview = true
            _ = try await store.save(flagged)
            report.flagged += 1
        }

        report.orphanedNames.sort()
        return report
    }
}
