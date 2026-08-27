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
            log.error("\(kind, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public)")
        } else {
            log.info("\(kind, privacy: .public) succeeded")
        }
    }
}
