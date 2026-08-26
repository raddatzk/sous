import Foundation
import SwiftData

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
///   row is gone, so the drill-down, the "N Zutaten zu klären" banner and the
///   basis picker have shown the state since phase 4 — before any pass ran.
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

/// Runs the reconciliation against a SwiftData store.
///
/// Deliberately built like the two passes before it — a `@ModelActor` with a
/// `run` returning a report — and deliberately working on the store rather
/// than through `IngredientCatalogLibrary`: every `setBasis` there drops the
/// whole nutrition cache twice and rebuilds the vocabulary once, so a hundred
/// orphaned words would mean two hundred table deletes and a hundred reloads
/// to set a hundred booleans.
///
/// It merges by key like the others rather than assuming it is the first
/// writer: the share extension runs no migration at all and can perfectly
/// well have written a vocabulary row after the update and before the app was
/// next opened.
@ModelActor
public actor SwiftDataOrphanReconciliation {
    /// Idempotent: an entry already carrying the review flag is counted as
    /// orphaned but not written again, so a second run changes nothing.
    public func run(bls: BLSCatalog = .bundled) throws -> OrphanReconciliation.Report {
        var report = OrphanReconciliation.Report()

        for row in try modelContext.fetch(FetchDescriptor<StoredIngredientVocabulary>()) {
            // Read the blob once: the accessor decodes on every get.
            let bases = row.bases
            guard bases.values.contains(where: { $0.isOrphaned(in: bls) }) else { continue }
            report.orphanedNames.append(row.name)
            // Already on the list — from an earlier run, or from the phase-3
            // stamp for a name that never mapped anywhere. Either way the
            // question is open and asking it twice writes nothing new.
            guard !row.needsBasisReview else { continue }
            row.needsBasisReview = true
            row.updatedAt = .nowInSyncPrecision
            report.flagged += 1
        }

        report.orphanedNames.sort()
        if report.didChangeAnything { try modelContext.save() }
        return report
    }
}
