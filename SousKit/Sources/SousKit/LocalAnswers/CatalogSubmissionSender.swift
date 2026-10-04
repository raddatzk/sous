import CloudKit
import Foundation

/// Where a ``CatalogSubmission`` goes.
public protocol CatalogSubmissionSender: Sendable {
    /// Whether this device can send now. Without an account, the sheet
    /// offers the issue form and copying instead.
    func account() async -> CatalogSubmissionAccount
    func send(_ submission: CatalogSubmission) async throws(CatalogSubmissionError)
}

/// What the device's iCloud account allows.
public enum CatalogSubmissionAccount: Hashable, Sendable {
    case available
    /// No account, or one that may not use iCloud (a restricted or managed
    /// Apple ID): sharing goes through the issue form or as text.
    case none
    /// Signed in, but iCloud is not ready — it wants the password or terms
    /// confirmed in Settings, or could not be asked. Sending waits.
    case unavailable
}

public enum CatalogSubmissionError: Error, Hashable, Sendable {
    case noAccount
    case offline
    case throttled
    case failed(String)

    /// What the sheet says.
    public var message: String {
        switch self {
        case .noAccount: "Ohne iCloud-Konto kann Sous nicht direkt teilen."
        case .offline: "Keine Verbindung. Versuch es später noch einmal."
        case .throttled: "iCloud ist gerade ausgelastet. Versuch es später noch einmal."
        case .failed(let reason): "Teilen hat nicht geklappt: \(reason)"
        }
    }
}

/// Sends a submission as a `CatalogSubmission` record to the public database
/// of the app's own container (INGREDIENTS-DATA §3 D).
///
/// Signed-in users may create such records and read none, their own
/// included; only the role `Publisher` reads and deletes them — the nightly
/// job in the private inbox repository (`Scripts/data/inbox.py`).
public struct CloudKitSubmissionSender: CatalogSubmissionSender {
    static let recordType = "CatalogSubmission"

    private let containerIdentifier: String

    public init(containerIdentifier: String = SousPersistentContainer.cloudKitContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    private var container: CKContainer { CKContainer(identifier: containerIdentifier) }

    public func account() async -> CatalogSubmissionAccount {
        switch try? await container.accountStatus() {
        case .available: .available
        case .noAccount, .restricted: .none
        default: .unavailable
        }
    }

    public func send(_ submission: CatalogSubmission) async throws(CatalogSubmissionError) {
        let record = Self.record(for: submission)
        do {
            // Not `save(_:)`: that fetches the record back after writing it,
            // which a creator without read rights is refused.
            let (saved, _) = try await container.publicCloudDatabase.modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys, atomically: false
            )
            if case .failure(let error) = saved[record.recordID] { throw error }
        } catch {
            throw Self.submissionError(error)
        }
    }

    static func record(for submission: CatalogSubmission) -> CKRecord {
        let record = CKRecord(recordType: recordType)
        record["schema"] = CatalogSubmission.schema as NSNumber
        record["items"] = submission.itemsJSON as NSString
        record["itemCount"] = submission.items.count as NSNumber
        record["app"] = submission.app as NSString
        record["dataVersion"] = submission.dataVersion as NSNumber
        return record
    }

    static func submissionError(_ error: Error) -> CatalogSubmissionError {
        guard let error = error as? CKError else { return .failed(error.localizedDescription) }
        switch error.code {
        case .notAuthenticated: return .noAccount
        case .networkUnavailable, .networkFailure: return .offline
        case .requestRateLimited, .zoneBusy, .serviceUnavailable, .quotaExceeded: return .throttled
        case .partialFailure:
            if let first = error.partialErrorsByItemID?.values.first { return submissionError(first) }
            return .failed(error.localizedDescription)
        default: return .failed(error.localizedDescription)
        }
    }
}
