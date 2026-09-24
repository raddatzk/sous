import CloudKit
import CoreData
import Foundation
import os

/// Says out loud what CloudKit is doing.
///
/// `NSPersistentCloudKitContainer` fails quietly by design: it opens, it
/// saves, it shows the whole library, and whether any of it ever left the
/// device is not visible anywhere. Chasing that difference through the
/// framework's own log output means reading hundreds of lines of mirroring
/// chatter for the two that matter.
///
/// So this listens to the events the container already publishes — setup,
/// import, export — and writes one line each, with the error where there is
/// one. Filter the console by `cloudkit` and the answer to "is it syncing"
/// is on screen.
public final class CloudKitEventLog: @unchecked Sendable {
    private static let log = Logger(subsystem: "me.raddatz.sous", category: "cloudkit")

    private var task: Task<Void, Never>?

    public init() {}

    /// Starts listening. Safe to call more than once; the previous listener
    /// is replaced rather than doubled.
    public func start() {
        task?.cancel()
        task = Task {
            let events = NotificationCenter.default.notifications(
                named: NSPersistentCloudKitContainer.eventChangedNotification
            )
            for await note in events {
                guard let event = note.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event else { continue }
                Self.report(event)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private static func report(_ event: NSPersistentCloudKitContainer.Event) {
        let kind = switch event.type {
        case .setup: "setup"
        case .import: "import"
        case .export: "export"
        @unknown default: "unknown"
        }

        // Events arrive twice: once when the work starts, once when it ends.
        // Only the end says anything.
        guard event.endDate != nil else {
            log.debug("\(kind, privacy: .public) started")
            return
        }

        if let error = event.error {
            logFailure(kind, error)
        } else {
            log.info("\(kind, privacy: .public) succeeded")
        }
    }

    /// Writes a failure out in full: the summary line, then one line per
    /// thing CloudKit actually objected to.
    ///
    /// Public, because the system's own logs redact exactly the part that
    /// matters — which record was refused, and the server's reason — and
    /// "CKErrorDomain-Fehler 2" names only the envelope. A partial failure
    /// is a list: every record the server rejected, plus every record that
    /// merely went down with it in an atomic zone. Those are counted, the
    /// others written out, record by record.
    ///
    /// Nothing personal goes into it: record names are ids, and the server's
    /// reasons name record types and fields, not their contents.
    public static func logFailure(_ context: String, _ error: any Error) {
        log.error("\(context, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public)")
        for line in details(of: error) {
            log.error("\(context, privacy: .public) · \(line, privacy: .public)")
        }
    }

    /// The lines `logFailure` writes below the summary, walking into
    /// underlying errors and partial failures.
    static func details(of error: any Error) -> [String] {
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain,
           nsError.code == CKError.Code.partialFailure.rawValue,
           let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error] {
            var lines: [String] = []
            var followers = 0
            for (item, itemError) in partial {
                let itemNSError = itemError as NSError
                if itemNSError.domain == CKErrorDomain,
                   itemNSError.code == CKError.Code.batchRequestFailed.rawValue {
                    followers += 1
                    continue
                }
                lines.append("\(describe(item)): \(describe(itemNSError))")
            }
            if followers > 0 {
                lines.append("\(followers) more rejected only because the batch failed")
            }
            return lines
        }
        var lines = [describe(nsError)]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
            lines += details(of: underlying)
        }
        return lines
    }

    private static func describe(_ error: NSError) -> String {
        var text = "\(error.domain) \(error.code)"
        if let server = error.userInfo["ServerErrorDescription"] as? String {
            text += " — server: \(server)"
        }
        text += " — \(error.localizedDescription)"
        return text
    }

    private static func describe(_ item: AnyHashable) -> String {
        switch item.base {
        case let record as CKRecord.ID:
            "record \(record.recordName) in \(record.zoneID.zoneName)"
        case let zone as CKRecordZone.ID:
            "zone \(zone.zoneName)"
        default:
            "\(item)"
        }
    }
}
