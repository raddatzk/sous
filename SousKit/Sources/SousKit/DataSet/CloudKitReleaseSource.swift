import CloudKit
import Foundation

/// Published releases in the app's own CloudKit container, public database
/// (INGREDIENTS-DATA §5; written by `Scripts/data/publish.py`).
///
/// - `current-v<schema>`, type `CurrentRelease`: the pointer, read by id —
///   never by query, whose indexes lag — and only its few small fields.
/// - `DataRelease` records: one per release, a `CKAsset` per file in a field
///   named after it (`kitchen_words.json` → `kitchen_words`).
///
/// Readable without an iCloud account. Only the role `Publisher` may write
/// either type, and it is held by the publisher's user record alone; the
/// records are still taken only if that user created them. Record names are
/// unique across every type in the zone, so a name somebody took first with
/// a type anyone may create would otherwise pass as the pointer.
public struct CloudKitReleaseSource: DataReleaseSource {
    /// The user records allowed to publish: the one the server-to-server
    /// keys act as. The same record name in development and production
    /// (checked 2026-10-03, one key per environment).
    static let publishers: Set<String> = [
        "_68d93d389c4a0b80d4adbb247564658a",
    ]

    static let pointerType = "CurrentRelease"
    static let releaseType = "DataRelease"

    private let containerIdentifier: String

    public init(containerIdentifier: String = SousPersistentContainer.cloudKitContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    private var database: CKDatabase {
        CKContainer(identifier: containerIdentifier).publicCloudDatabase
    }

    public func pointer(schema: Int) async throws(DataFetchError) -> ReleasePointer? {
        let id = CKRecord.ID(recordName: "current-v\(schema)")
        let record: CKRecord
        do {
            let results = try await database.records(
                for: [id], desiredKeys: ["schema", "dataVersion", "manifest", "release", "minApp"]
            )
            guard let result = results[id] else { return nil }
            record = try result.get()
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw Self.fetchError(error)
        }
        try Self.checkTrusted(record, type: Self.pointerType)
        guard let version = record["dataVersion"] as? Int,
              let manifest = record["manifest"] as? String,
              let release = record["release"] as? CKRecord.Reference
        else { throw .failed("The pointer lacks a field") }
        return ReleasePointer(
            schema: record["schema"] as? Int ?? schema,
            dataVersion: version,
            manifest: Data(manifest.utf8),
            release: release.recordID.recordName,
            minApp: record["minApp"] as? Int
        )
    }

    public func download(release: String, files: [String], into folder: URL) async throws(DataFetchError) {
        let fields = Dictionary(uniqueKeysWithValues: files.map { (Self.field(for: $0), $0) })
        let id = CKRecord.ID(recordName: release)
        let operation = CKFetchRecordsOperation(recordIDs: [id])
        operation.desiredKeys = Array(fields.keys)
        operation.qualityOfService = .utility

        let result: Result<Void, DataFetchError> = await withCheckedContinuation { continuation in
            var copied: Result<Void, DataFetchError> = .failure(.failed("The release did not arrive"))
            // CloudKit deletes an asset's file once the operation completes,
            // so it is copied here, while the record is handed over.
            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record):
                    copied = Result { () throws(DataFetchError) in
                        try Self.checkTrusted(record, type: Self.releaseType)
                        for (field, name) in fields {
                            guard let url = (record[field] as? CKAsset)?.fileURL else {
                                throw .failed("The release has no \(name)")
                            }
                            do {
                                try FileManager.default.copyItem(at: url, to: folder.appending(path: name))
                            } catch {
                                throw .failed("Could not copy \(name): \(error.localizedDescription)")
                            }
                        }
                    }
                case .failure(let error):
                    copied = .failure(Self.fetchError(error))
                }
            }
            operation.fetchRecordsResultBlock = { result in
                if case .failure(let error) = result, case .success = copied {
                    copied = .failure(Self.fetchError(error))
                }
                continuation.resume(returning: copied)
            }
            database.add(operation)
        }
        try result.get()
    }

    /// `kitchen_words.json` → `kitchen_words`: the field a file travels in.
    static func field(for fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    private static func checkTrusted(_ record: CKRecord, type: String) throws(DataFetchError) {
        guard record.recordType == type else { throw .untrusted }
        let creator = record.creatorUserRecordID?.recordName
        // On the publisher's own device, CloudKit names the creator by the
        // placeholder for "you" instead of the record name.
        guard let creator, publishers.contains(creator) || creator == CKCurrentUserDefaultName else {
            throw .untrusted
        }
    }

    static func fetchError(_ error: Error) -> DataFetchError {
        guard let error = error as? CKError else { return .failed(error.localizedDescription) }
        switch error.code {
        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            return .throttled(retryAfter: error.retryAfterSeconds)
        case .networkUnavailable, .networkFailure:
            return .offline
        case .partialFailure:
            if let first = error.partialErrorsByItemID?.values.first {
                return fetchError(first)
            }
            return .failed(error.localizedDescription)
        default:
            return .failed(error.localizedDescription)
        }
    }
}
