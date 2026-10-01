import Foundation

/// Where a household keeps its local answers.
public protocol LocalAnswerStore: Sendable {
    /// Every answer of the active household, twins included — folding them
    /// is ``LocalAnswerSet``'s job, which knows which one is newer.
    func answers() async throws -> [LocalAnswer]
    /// Upserts by key and folds away any twin of it. An empty answer is
    /// deleted instead, and `nil` returned.
    @discardableResult
    func save(_ answer: LocalAnswer) async throws -> LocalAnswer?
    /// Removes every row under the answer's key.
    func delete(_ answer: LocalAnswer) async throws
}

/// A store that keeps nothing beyond the process — for tests, and for a
/// library built where no household store exists.
public actor InMemoryLocalAnswerStore: LocalAnswerStore {
    private var rows: [LocalAnswer]

    public init(_ answers: [LocalAnswer] = []) {
        rows = answers
    }

    public func answers() -> [LocalAnswer] { rows }

    @discardableResult
    public func save(_ answer: LocalAnswer) -> LocalAnswer? {
        rows.removeAll { $0.key == answer.key || $0.id == answer.id }
        guard !answer.isEmpty else { return nil }
        var saved = answer
        saved.updatedAt = .nowInSyncPrecision
        rows.append(saved)
        return saved
    }

    public func delete(_ answer: LocalAnswer) {
        rows.removeAll { $0.key == answer.key || $0.id == answer.id }
    }
}
